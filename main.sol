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

        pos.supplied = supplied - amount;
        pos.borrowIndexSnapshot = assetStates[asset].indexCumulative;
        assetStates[asset].totalSupply -= amount;

        if (!IERC20Minimal(asset).transfer(msg.sender, amount)) revert BladeForge_TransferFailed();
        emit Withdraw(msg.sender, asset, amount);
    }

    function setCollateralEnabled(address asset, bool enabled) external nonReentrant whenNotPaused assetListed(asset) {
        _accrueInterest(asset);
        Position storage pos = positions[msg.sender][asset];
        uint256 borrows = _borrowBalanceInternal(msg.sender, asset);
        if (enabled && borrows > 0) {
            uint256 health = _healthFactorWad(msg.sender, asset, pos.supplied, borrows);
            if (health < MIN_HEALTH_FACTOR_LIQUIDATABLE) revert BladeForge_HealthFactorTooLow();
        }
        pos.collateralEnabled = enabled;
        pos.borrowIndexSnapshot = assetStates[asset].indexCumulative;
        emit CollateralToggled(msg.sender, asset, enabled);
    }

    function borrow(address asset, uint256 amount) external nonReentrant whenNotPaused assetListed(asset) {
        if (amount == 0) revert BladeForge_InvalidAmount();
        if (!assetConfigs[asset].borrowEnabled) revert BladeForge_BorrowDisabled();
        uint256 cap = borrowCap[asset];
        if (cap != 0 && assetStates[asset].totalBorrows + amount > cap) revert BladeForge_BorrowCapExceeded();

        _accrueInterest(asset);

        uint256 borrowsBefore = _borrowBalanceInternal(msg.sender, asset);
        uint256 newBorrows = borrowsBefore + amount;
        uint256 collateralValueWad = _totalCollateralValueWad(msg.sender);
        uint256 borrowValueWad = _totalBorrowValueWad(msg.sender, asset, newBorrows);
        uint256 capacity = (collateralValueWad * assetConfigs[asset].collateralFactorBps) / BPS_DENOM;
        if (borrowValueWad > capacity) revert BladeForge_ExceedsCollateralCapacity();

        uint256 health = _healthFactorWad(msg.sender, asset, positions[msg.sender][asset].supplied, newBorrows);
        if (health < MIN_HEALTH_FACTOR_LIQUIDATABLE) revert BladeForge_HealthFactorTooLow();

        Position storage pos = positions[msg.sender][asset];
        pos.borrowed += amount;
        pos.borrowIndexSnapshot = assetStates[asset].indexCumulative;
        assetStates[asset].totalBorrows += amount;
        lastActivityBlock[asset] = block.number;

        if (!IERC20Minimal(asset).transfer(msg.sender, amount)) revert BladeForge_TransferFailed();
        emit Borrow(msg.sender, asset, amount, health);
    }

    function repay(address asset, uint256 amount) external nonReentrant whenNotPaused assetListed(asset) {
        if (amount == 0) revert BladeForge_InvalidAmount();

        _accrueInterest(asset);

        uint256 owed = _borrowBalanceInternal(msg.sender, asset);
        uint256 payAmount = amount > owed ? owed : amount;

        Position storage pos = positions[msg.sender][asset];
        AssetState storage state = assetStates[asset];
        uint256 index = state.indexCumulative;
        uint256 principalRepay = (payAmount * pos.borrowIndexSnapshot) / index;
        if (principalRepay > pos.borrowed) principalRepay = pos.borrowed;

        pos.borrowed -= principalRepay;
        pos.borrowIndexSnapshot = index;
        state.totalBorrows -= principalRepay;

        uint256 balBefore = IERC20Minimal(asset).balanceOf(address(this));
        if (!IERC20Minimal(asset).transferFrom(msg.sender, address(this), payAmount)) revert BladeForge_TransferFailed();
        uint256 received = IERC20Minimal(asset).balanceOf(address(this)) - balBefore;
        if (received != payAmount) revert BladeForge_TransferFailed();

        emit Repay(msg.sender, asset, payAmount);
    }

    function liquidate(
        address user,
        address collateralAsset,
        address debtAsset,
        uint256 debtToCover
    ) external nonReentrant whenNotPaused assetListed(collateralAsset) assetListed(debtAsset) {
        if (user == msg.sender) revert BladeForge_SelfLiquidation();
        if (debtToCover == 0) revert BladeForge_InvalidAmount();

        _accrueInterest(collateralAsset);
        _accrueInterest(debtAsset);

        uint256 debtBalance = _borrowBalanceInternal(user, debtAsset);
        if (debtToCover > debtBalance) debtToCover = debtBalance;

        uint256 health = _healthFactorWad(user, debtAsset, positions[user][collateralAsset].supplied, debtBalance);
        if (health >= MIN_HEALTH_FACTOR_LIQUIDATABLE) revert BladeForge_NotLiquidatable();

        AssetConfig memory collateralConfig = assetConfigs[collateralAsset];
        uint256 bonusBps = collateralConfig.liquidationBonusBps;
        uint256 debtPrice = oraclePriceWad[debtAsset];
        uint256 collateralPrice = oraclePriceWad[collateralAsset];
        if (debtPrice == 0 || collateralPrice == 0) revert BladeForge_InvalidConfig();
        uint256 collateralValueOfDebt = (debtToCover * debtPrice) / collateralPrice;
        uint256 collateralToSeize = (collateralValueOfDebt * (BPS_DENOM + bonusBps)) / BPS_DENOM;

        Position storage pos = positions[user][collateralAsset];
        uint256 userCollateral = pos.supplied;
        if (collateralToSeize > userCollateral) collateralToSeize = userCollateral;

        Position storage debtPos = positions[user][debtAsset];
        AssetState storage debtState = assetStates[debtAsset];
        uint256 principalCover = (debtToCover * debtPos.borrowIndexSnapshot) / debtState.indexCumulative;
        if (principalCover > debtPos.borrowed) principalCover = debtPos.borrowed;

        debtPos.borrowed -= principalCover;
        debtPos.borrowIndexSnapshot = debtState.indexCumulative;
        debtState.totalBorrows -= (debtToCover * debtState.totalBorrows) / (debtBalance);
        pos.supplied -= collateralToSeize;
        assetStates[collateralAsset].totalSupply -= collateralToSeize;

        totalLiquidationsWei += collateralToSeize;

        if (!IERC20Minimal(debtAsset).transferFrom(msg.sender, address(this), debtToCover)) revert BladeForge_TransferFailed();
        if (!IERC20Minimal(collateralAsset).transfer(msg.sender, collateralToSeize)) revert BladeForge_TransferFailed();

        emit Liquidate(msg.sender, user, collateralAsset, debtAsset, debtToCover, collateralToSeize);
    }

    function _borrowBalanceInternal(address user, address asset) internal view returns (uint256) {
        Position storage pos = positions[user][asset];
        if (pos.borrowed == 0) return 0;
        AssetState storage state = assetStates[asset];
        return (pos.borrowed * state.indexCumulative) / pos.borrowIndexSnapshot;
    }

    function _totalCollateralValueWad(address user) internal view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _assetList.length; i++) {
            address a = _assetList[i];
            Position storage pos = positions[user][a];
            if (!pos.collateralEnabled || pos.supplied == 0) continue;
            uint256 price = oraclePriceWad[a];
            if (price == 0) continue;
            total += pos.supplied * price;
        }
        return total;
    }

    function _totalBorrowValueWad(address user, address excludeAsset, uint256 excludeBorrowAdd) internal view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < _assetList.length; i++) {
            address a = _assetList[i];
            uint256 borrows = _borrowBalanceInternal(user, a);
            if (a == excludeAsset) borrows = excludeBorrowAdd;
            if (borrows == 0) continue;
            uint256 price = oraclePriceWad[a];
            if (price == 0) continue;
            total += borrows * price;
        }
        return total;
    }

    function _healthFactorWad(address user, address borrowAsset, uint256 suppliedCollateral, uint256 borrows) internal view returns (uint256) {
        uint256 collateralVal = _totalCollateralValueWad(user);
        Position storage pos = positions[user][borrowAsset];
        uint256 otherBorrows = _totalBorrowValueWad(user, borrowAsset, 0);
        uint256 totalDebtVal = otherBorrows + (borrows * oraclePriceWad[borrowAsset]);
        uint256 thresholdVal = 0;
        if (pos.collateralEnabled && suppliedCollateral > 0 && oraclePriceWad[borrowAsset] > 0) {
            thresholdVal = (suppliedCollateral * oraclePriceWad[borrowAsset] * assetConfigs[borrowAsset].liquidationThresholdBps) / BPS_DENOM;
        }
        uint256 totalThreshold = (collateralVal * assetConfigs[borrowAsset].liquidationThresholdBps) / BPS_DENOM;
        if (totalDebtVal == 0) return type(uint256).max;
        return (totalThreshold * SCALE) / totalDebtVal;
    }

    function sweepFees(address token, uint256 amount) external onlyGovernor nonReentrant {
        address recipient = FEE_RECIPIENT != address(0) ? FEE_RECIPIENT : TREASURY_BACKUP;
        if (token == address(0)) {
            uint256 bal = address(this).balance;
            uint256 send = amount == 0 ? bal : (amount > bal ? bal : amount);
            if (send == 0) return;
            (bool ok,) = payable(recipient).call{ value: send }("");
            if (!ok) revert BladeForge_TransferFailed();
            emit FeeSwept(recipient, send);
        } else {
            if (!isListedAsset[token]) revert BladeForge_AssetNotListed();
            uint256 bal = IERC20Minimal(token).balanceOf(address(this));
            uint256 supply = assetStates[token].totalSupply;
            uint256 available = bal > supply ? bal - supply : 0;
            uint256 send = amount == 0 ? available : (amount > available ? available : amount);
            if (send == 0) return;
            if (!IERC20Minimal(token).transfer(recipient, send)) revert BladeForge_TransferFailed();
            emit FeeSwept(recipient, send);
        }
    }

    function getAssetList() external view returns (address[] memory) {
        return _assetList;
    }

    function getBorrowBalance(address user, address asset) external view returns (uint256) {
        return _borrowBalanceInternal(user, asset);
    }

    function getHealthFactorWad(address user) external view returns (uint256) {
        uint256 debtVal;
        uint256 thresholdVal;
        for (uint256 i = 0; i < _assetList.length; i++) {
            address a = _assetList[i];
            uint256 borrows = _borrowBalanceInternal(user, a);
            if (borrows > 0 && oraclePriceWad[a] > 0) debtVal += borrows * oraclePriceWad[a];
            Position storage pos = positions[user][a];
            if (pos.collateralEnabled && pos.supplied > 0 && oraclePriceWad[a] > 0) {
                thresholdVal += (pos.supplied * oraclePriceWad[a] * assetConfigs[a].liquidationThresholdBps) / BPS_DENOM;
            }
        }
        if (debtVal == 0) return type(uint256).max;
        return (thresholdVal * SCALE) / debtVal;
    }

    function getUtilization(address asset) external view returns (uint256) {
        AssetState storage state = assetStates[asset];
        if (state.totalSupply == 0) return 0;
        return (state.totalBorrows * SCALE) / state.totalSupply;
    }

    function getCurrentRatePerBlock(address asset) external view returns (uint256) {
        AssetState storage state = assetStates[asset];
        if (state.totalSupply == 0) return assetConfigs[asset].baseRatePerBlock;
        uint256 utilization = (state.totalBorrows * SCALE) / state.totalSupply;
        return _computeRatePerBlock(assetConfigs[asset], utilization);
    }

    struct PositionSummary {
        address asset;
        uint256 supplied;
        uint256 borrowed;
        uint256 borrowBalanceCurrent;
        bool collateralEnabled;
        uint256 priceWad;
    }

    function getPositionSummary(address user) external view returns (PositionSummary[] memory) {
        uint256 n = _assetList.length;
        PositionSummary[] memory out = new PositionSummary[](n);
        for (uint256 i = 0; i < n; i++) {
            address a = _assetList[i];
            Position storage pos = positions[user][a];
            out[i] = PositionSummary({
                asset: a,
                supplied: pos.supplied,
                borrowed: pos.borrowed,
                borrowBalanceCurrent: _borrowBalanceInternal(user, a),
                collateralEnabled: pos.collateralEnabled,
                priceWad: oraclePriceWad[a]
            });
        }
        return out;
    }

    struct AssetStateFull {
        address asset;
        uint256 totalSupply;
        uint256 totalBorrows;
        uint256 indexCumulative;
        uint256 utilizationWad;
        uint256 currentRatePerBlock;
        uint256 borrowCapLimit;
        uint256 supplyCapLimit;
        uint256 oraclePriceWad;
    }

    function getAssetStateFull(address asset) external view returns (AssetStateFull memory) {
        if (!isListedAsset[asset]) revert BladeForge_AssetNotListed();
        AssetState storage state = assetStates[asset];
        uint256 util = state.totalSupply == 0 ? 0 : (state.totalBorrows * SCALE) / state.totalSupply;
        uint256 rate = state.totalSupply == 0 ? assetConfigs[asset].baseRatePerBlock : _computeRatePerBlock(assetConfigs[asset], util);
        return AssetStateFull({
            asset: asset,
            totalSupply: state.totalSupply,
            totalBorrows: state.totalBorrows,
            indexCumulative: state.indexCumulative,
            utilizationWad: util,
            currentRatePerBlock: rate,
            borrowCapLimit: borrowCap[asset],
            supplyCapLimit: supplyCap[asset],
            oraclePriceWad: oraclePriceWad[asset]
        });
    }

    function getTotalValueLockedWad() external view returns (uint256 totalSupplyValueWad) {
        for (uint256 i = 0; i < _assetList.length; i++) {
            address a = _assetList[i];
            uint256 supply = assetStates[a].totalSupply;
            if (supply > 0 && oraclePriceWad[a] > 0) totalSupplyValueWad += supply * oraclePriceWad[a];
        }
    }

    function getMaxBorrowCapacityWad(address user, address borrowAsset) external view returns (uint256) {
        uint256 collateralVal = _totalCollateralValueWad(user);
        uint256 currentBorrowVal = _totalBorrowValueWad(user, borrowAsset, 0);
        uint256 capacityVal = (collateralVal * assetConfigs[borrowAsset].collateralFactorBps) / BPS_DENOM;
        if (currentBorrowVal >= capacityVal) return 0;
        uint256 price = oraclePriceWad[borrowAsset];
        if (price == 0) return 0;
        return (capacityVal - currentBorrowVal) / price;
    }

    function getLiquidationPriceWad(address user, address collateralAsset, address debtAsset) external view returns (uint256 priceWad) {
        uint256 debtVal = 0;
        for (uint256 i = 0; i < _assetList.length; i++) {
            address a = _assetList[i];
            uint256 b = _borrowBalanceInternal(user, a);
            if (b > 0 && oraclePriceWad[a] > 0) debtVal += b * oraclePriceWad[a];
        }
        Position storage pos = positions[user][collateralAsset];
        if (pos.supplied == 0 || debtVal == 0) return 0;
        uint256 thresholdBps = assetConfigs[collateralAsset].liquidationThresholdBps;
        return (debtVal * BPS_DENOM) / (pos.supplied * thresholdBps);
    }

    function getMarketStats() external view returns (
        uint256 totalAssets,
        uint256 totalTvlWad,
        uint256 totalFeesAccrued,
        uint256 totalLiquidationsWei,
        uint256 deployTs,
        bool paused
    ) {
        totalAssets = _assetList.length;
        totalTvlWad = 0;
        for (uint256 i = 0; i < _assetList.length; i++) {
            address a = _assetList[i];
            uint256 s = assetStates[a].totalSupply;
            if (s > 0 && oraclePriceWad[a] > 0) totalTvlWad += s * oraclePriceWad[a];
        }
        return (
            totalAssets,
            totalTvlWad,
