// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title BladeForgeVault
 * @notice Collateralized lending vault with variable-rate accrual and liquidation. Deployed with fixed governance and oracle endpoints.
 * @dev All rate math uses 1e18 scale; positions are tracked per-asset per-user with health factor enforcement.
 *
 * Rate model: piecewise linear (base + slope1 up to optimal utilization, then slope2 beyond). Interest accrues every block.
 * Health factor = (collateral * liquidationThreshold) / debt; positions below 1e18 are liquidatable.
 * Governor can list assets, set caps, freeze deposits, toggle borrow, and pause the vault. Price feed (or governor) sets oracle prices.
 * Emergency recover is only callable when vault is paused and allows governor to withdraw stuck ETH or tokens.
 */

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

contract BladeForgeVault {

    uint256 private constant SCALE = 1e18;
    uint256 private constant BPS_DENOM = 10000;
    uint256 private constant MIN_COLLATERAL_FACTOR_BPS = 5000;
    uint256 private constant MAX_COLLATERAL_FACTOR_BPS = 9500;
    uint256 private constant MIN_LIQUIDATION_THRESHOLD_BPS = 5500;
    uint256 private constant MAX_LIQUIDATION_THRESHOLD_BPS = 9800;
    uint256 private constant LIQUIDATION_BONUS_BPS_MIN = 100;
    uint256 private constant LIQUIDATION_BONUS_BPS_MAX = 1500;
    uint256 private constant PROTOCOL_FEE_BPS_CAP = 500;
    uint256 private constant MAX_ASSETS = 32;
    uint256 private constant LOCK_SLOT = 1;
    uint256 private constant SEED_NONCE = 0xa7f2c4e9b1d3f6a8c0e5b7d9f2a4c6e8b0d2f4a6;
    uint256 private constant MAX_HEALTH_FACTOR = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR_LIQUIDATABLE = 1e18;

    address public immutable GOVERNOR;
    address public immutable FEE_RECIPIENT;
    address public immutable PRICE_FEED;
    address public immutable TREASURY_BACKUP;
    uint256 public immutable DEPLOY_TIMESTAMP;
    bytes32 public immutable DOMAIN_SEPARATOR;

    uint256 private _lock;
    bool public vaultPaused;
    uint256 public assetCount;
    uint256 public totalProtocolFeesAccrued;
    uint256 public totalLiquidationsWei;

    struct AssetConfig {
        bool allowed;
        bool borrowEnabled;
        bool depositsFrozen;
        uint256 collateralFactorBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        uint256 reserveFactorBps;
        uint256 baseRatePerBlock;
        uint256 slope1PerBlock;
        uint256 slope2PerBlock;
        uint256 optimalUtilizationBps;
    }

    struct AssetState {
        uint256 totalSupply;
        uint256 totalBorrows;
        uint256 indexCumulative;
        uint256 lastUpdateBlock;
        uint256 accrualBlockNumber;
    }

    struct Position {
        uint256 supplied;
        uint256 borrowed;
        uint256 collateralScaled;
        uint256 borrowIndexSnapshot;
        bool collateralEnabled;
    }

    address[] private _assetList;
    mapping(address => AssetConfig) public assetConfigs;
    mapping(address => AssetState) public assetStates;
    mapping(address => mapping(address => Position)) public positions;
    mapping(address => uint256) public assetIndexMap;
    mapping(address => uint256) public oraclePriceWad;
    mapping(address => bool) public isListedAsset;
    mapping(address => uint256) public borrowCap;
    mapping(address => uint256) public supplyCap;
    mapping(address => uint256) public lastActivityBlock;

    event AssetListed(address indexed asset, uint256 collateralFactorBps, uint256 liquidationThresholdBps);
    event AssetConfigUpdated(address indexed asset, bool borrowEnabled, uint256 reserveFactorBps);
    event Supply(address indexed user, address indexed asset, uint256 amount);
    event Withdraw(address indexed user, address indexed asset, uint256 amount);
    event Borrow(address indexed user, address indexed asset, uint256 amount, uint256 newHealthWad);
    event Repay(address indexed user, address indexed asset, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed user, address indexed collateralAsset, address debtAsset, uint256 debtCovered, uint256 collateralSeized);
    event CollateralToggled(address indexed user, address indexed asset, bool enabled);
    event PriceUpdated(address indexed asset, uint256 priceWad);
    event FeeSwept(address indexed recipient, uint256 amountWei);
    event VaultPauseToggled(bool paused);

    error BladeForge_Unauthorized();
    error BladeForge_VaultPaused();
    error BladeForge_AssetNotListed();
    error BladeForge_BorrowDisabled();
    error BladeForge_DepositsFrozen();
    error BladeForge_InvalidAmount();
    error BladeForge_InvalidConfig();
    error BladeForge_HealthFactorTooLow();
    error BladeForge_ExceedsCollateralCapacity();
    error BladeForge_Reentrancy();
    error BladeForge_TransferFailed();
    error BladeForge_MaxAssetsReached();
    error BladeForge_AssetAlreadyListed();
    error BladeForge_ZeroAddress();
    error BladeForge_NotLiquidatable();
    error BladeForge_SelfLiquidation();
    error BladeForge_BorrowCapExceeded();
    error BladeForge_SupplyCapExceeded();
    error BladeForge_EmergencyOnlyWhenPaused();

    modifier nonReentrant() {
        if (_lock != 0) revert BladeForge_Reentrancy();
        _lock = LOCK_SLOT;
        _;
        _lock = 0;
    }

    modifier whenNotPaused() {
        if (vaultPaused) revert BladeForge_VaultPaused();
        _;
    }

    modifier onlyGovernor() {
        if (msg.sender != GOVERNOR) revert BladeForge_Unauthorized();
        _;
    }

    modifier assetListed(address asset) {
        if (!isListedAsset[asset]) revert BladeForge_AssetNotListed();
        _;
    }

    constructor() {
        GOVERNOR = msg.sender;
        FEE_RECIPIENT = 0x1a2B3c4D5e6F7A8b9C0d1E2f3A4b5C6d7E8f9A0b;
        PRICE_FEED = 0x7f6E5D4c3B2a1098F7e6d5c4B3a2019f8E7d6C5b;
        TREASURY_BACKUP = 0x3C4d5E6f7A8B9c0D1e2F3a4B5c6D7e8F9a0B1c2D;
        DEPLOY_TIMESTAMP = block.timestamp;
        DOMAIN_SEPARATOR = keccak256(abi.encode(keccak256("BladeForgeVault(uint256 chainId,address vault)"), block.chainid, address(this)));
    }

    function listAsset(
        address asset,
        uint256 collateralFactorBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        uint256 reserveFactorBps,
        uint256 baseRatePerBlock,
        uint256 slope1PerBlock,
        uint256 slope2PerBlock,
        uint256 optimalUtilizationBps
    ) external onlyGovernor nonReentrant {
        if (asset == address(0)) revert BladeForge_ZeroAddress();
        if (isListedAsset[asset]) revert BladeForge_AssetAlreadyListed();
        if (assetCount >= MAX_ASSETS) revert BladeForge_MaxAssetsReached();
        if (collateralFactorBps < MIN_COLLATERAL_FACTOR_BPS || collateralFactorBps > MAX_COLLATERAL_FACTOR_BPS) revert BladeForge_InvalidConfig();
        if (liquidationThresholdBps < MIN_LIQUIDATION_THRESHOLD_BPS || liquidationThresholdBps > MAX_LIQUIDATION_THRESHOLD_BPS) revert BladeForge_InvalidConfig();
        if (liquidationBonusBps < LIQUIDATION_BONUS_BPS_MIN || liquidationBonusBps > LIQUIDATION_BONUS_BPS_MAX) revert BladeForge_InvalidConfig();
        if (reserveFactorBps > PROTOCOL_FEE_BPS_CAP) revert BladeForge_InvalidConfig();
        if (optimalUtilizationBps == 0 || optimalUtilizationBps > BPS_DENOM) revert BladeForge_InvalidConfig();

        _assetList.push(asset);
        assetIndexMap[asset] = _assetList.length;
        isListedAsset[asset] = true;
        assetCount++;

        assetConfigs[asset] = AssetConfig({
            allowed: true,
            borrowEnabled: true,
            depositsFrozen: false,
            collateralFactorBps: collateralFactorBps,
            liquidationThresholdBps: liquidationThresholdBps,
            liquidationBonusBps: liquidationBonusBps,
            reserveFactorBps: reserveFactorBps,
            baseRatePerBlock: baseRatePerBlock,
            slope1PerBlock: slope1PerBlock,
            slope2PerBlock: slope2PerBlock,
            optimalUtilizationBps: optimalUtilizationBps
        });

        assetStates[asset] = AssetState({
            totalSupply: 0,
            totalBorrows: 0,
            indexCumulative: SCALE,
            lastUpdateBlock: block.number,
            accrualBlockNumber: block.number
        });

        emit AssetListed(asset, collateralFactorBps, liquidationThresholdBps);
    }

    function setOraclePrice(address asset, uint256 priceWad) external {
        if (msg.sender != PRICE_FEED && msg.sender != GOVERNOR) revert BladeForge_Unauthorized();
        if (asset == address(0) || !isListedAsset[asset]) revert BladeForge_AssetNotListed();
        oraclePriceWad[asset] = priceWad;
        emit PriceUpdated(asset, priceWad);
    }

    function setBorrowEnabled(address asset, bool enabled) external onlyGovernor {
        if (!isListedAsset[asset]) revert BladeForge_AssetNotListed();
        assetConfigs[asset].borrowEnabled = enabled;
        emit AssetConfigUpdated(asset, enabled, assetConfigs[asset].reserveFactorBps);
    }

    function setDepositsFrozen(address asset, bool frozen) external onlyGovernor {
        if (!isListedAsset[asset]) revert BladeForge_AssetNotListed();
        assetConfigs[asset].depositsFrozen = frozen;
        emit AssetConfigUpdated(asset, assetConfigs[asset].borrowEnabled, assetConfigs[asset].reserveFactorBps);
    }

    function setReserveFactorBps(address asset, uint256 reserveFactorBps) external onlyGovernor {
        if (!isListedAsset[asset]) revert BladeForge_AssetNotListed();
        if (reserveFactorBps > PROTOCOL_FEE_BPS_CAP) revert BladeForge_InvalidConfig();
        assetConfigs[asset].reserveFactorBps = reserveFactorBps;
        emit AssetConfigUpdated(asset, assetConfigs[asset].borrowEnabled, reserveFactorBps);
    }

    function setBorrowCap(address asset, uint256 cap) external onlyGovernor {
        if (!isListedAsset[asset]) revert BladeForge_AssetNotListed();
        if (cap != 0 && assetStates[asset].totalBorrows > cap) revert BladeForge_InvalidConfig();
        borrowCap[asset] = cap;
    }

    function setSupplyCap(address asset, uint256 cap) external onlyGovernor {
        if (!isListedAsset[asset]) revert BladeForge_AssetNotListed();
        if (cap != 0 && assetStates[asset].totalSupply > cap) revert BladeForge_InvalidConfig();
        supplyCap[asset] = cap;
    }

    function setOraclePrices(address[] calldata assets, uint256[] calldata pricesWad) external {
        if (msg.sender != PRICE_FEED && msg.sender != GOVERNOR) revert BladeForge_Unauthorized();
        if (assets.length != pricesWad.length) revert BladeForge_InvalidConfig();
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] != address(0) && isListedAsset[assets[i]]) {
                oraclePriceWad[assets[i]] = pricesWad[i];
                emit PriceUpdated(assets[i], pricesWad[i]);
            }
        }
    }

    function toggleVaultPause() external onlyGovernor {
        vaultPaused = !vaultPaused;
        emit VaultPauseToggled(vaultPaused);
    }

    function _accrueInterest(address asset) internal {
        AssetState storage state = assetStates[asset];
        AssetConfig memory config = assetConfigs[asset];
        if (block.number <= state.accrualBlockNumber) return;

        uint256 totalSupply = state.totalSupply;
        uint256 totalBorrows = state.totalBorrows;
        uint256 index = state.indexCumulative;

        if (totalBorrows > 0 && totalSupply > 0) {
            uint256 blocksElapsed = block.number - state.accrualBlockNumber;
            uint256 utilization = (totalBorrows * SCALE) / totalSupply;
            uint256 ratePerBlock = _computeRatePerBlock(config, utilization);
            uint256 interestScaled = (totalBorrows * ratePerBlock * blocksElapsed) / SCALE;
            uint256 protocolShare = (interestScaled * config.reserveFactorBps) / BPS_DENOM;
            totalProtocolFeesAccrued += protocolShare;
            state.totalBorrows += interestScaled;
            state.totalSupply += interestScaled;
            index = (index * (SCALE + (ratePerBlock * blocksElapsed))) / SCALE;
        }

        state.indexCumulative = index;
        state.accrualBlockNumber = block.number;
        state.lastUpdateBlock = block.number;
    }

    function _computeRatePerBlock(AssetConfig memory config, uint256 utilizationWad) internal pure returns (uint256) {
        uint256 opt = (config.optimalUtilizationBps * SCALE) / BPS_DENOM;
        if (utilizationWad <= opt) {
            return config.baseRatePerBlock + (config.slope1PerBlock * utilizationWad) / opt;
        }
        uint256 excess = utilizationWad - opt;
        uint256 slope2Part = (config.slope2PerBlock * excess) / (SCALE - opt);
        return config.baseRatePerBlock + config.slope1PerBlock + slope2Part;
    }

    function supply(address asset, uint256 amount) external nonReentrant whenNotPaused assetListed(asset) {
        if (amount == 0) revert BladeForge_InvalidAmount();
        if (assetConfigs[asset].depositsFrozen) revert BladeForge_DepositsFrozen();
        uint256 cap = supplyCap[asset];
        if (cap != 0 && assetStates[asset].totalSupply + amount > cap) revert BladeForge_SupplyCapExceeded();

        _accrueInterest(asset);

        IERC20Minimal token = IERC20Minimal(asset);
        uint256 balBefore = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), amount)) revert BladeForge_TransferFailed();
        uint256 received = token.balanceOf(address(this)) - balBefore;
        if (received != amount) revert BladeForge_InvalidAmount();

        AssetState storage state = assetStates[asset];
        Position storage pos = positions[msg.sender][asset];
        state.totalSupply += received;
        pos.supplied += received;
        pos.borrowIndexSnapshot = state.indexCumulative;
        lastActivityBlock[asset] = block.number;

        emit Supply(msg.sender, asset, received);
    }

    function withdraw(address asset, uint256 amount) external nonReentrant whenNotPaused assetListed(asset) {
        if (amount == 0) revert BladeForge_InvalidAmount();

        _accrueInterest(asset);

        Position storage pos = positions[msg.sender][asset];
        uint256 supplied = pos.supplied;
        if (amount > supplied) revert BladeForge_InvalidAmount();

        uint256 borrows = _borrowBalanceInternal(msg.sender, asset);
        if (pos.collateralEnabled && borrows > 0) {
            uint256 newSupplied = supplied - amount;
            uint256 health = _healthFactorWad(msg.sender, asset, newSupplied, borrows);
            if (health < MIN_HEALTH_FACTOR_LIQUIDATABLE) revert BladeForge_HealthFactorTooLow();
        }

