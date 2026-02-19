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
