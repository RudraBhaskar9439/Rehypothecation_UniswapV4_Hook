// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

struct ReserveData {
    uint128 liquidityIndex;
    uint128 currentLiquidityRate;
    uint128 variableBorrowIndex;
    uint128 currentVariableBorrowRate;
    uint128 currentStableBorrowRate;
    uint40 lastUpdateTimestamp;
    uint16 id;
    address aTokenAddress;
    address stableDebtTokenAddress;
    address variableDebtTokenAddress;
    address interestRateStrategyAddress;
    uint128 accruedToTreasury;
    uint128 unbacked;
    uint128 isolationModeTotalDebt;
}

interface IAave {
    /**
     * @dev Deposits an asset into the aave lending pool
     * @param asset The address of the asset to deposit
     * @param amount The amount of asset to deposit
     * @param onBehalfOf The address that will recieve the aTokens
     * @param referralCode The referral code for rewards
     *
     */
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external; // can only be called from outside of the contract

    /**
     * @dev Withdraws an asset from the aave lending pool
     * @param asset The address of the asset to withdraw
     * @param amount The amount to withdraw
     * @param to The address to send the withdrawn asset to
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /**
     * @dev Gets the reserve data for an asset
     * @param asset The address of the underlying asset
     * @return The reserve data including aToken address
     */
    function getReserveData(address asset) external view returns (ReserveData memory);
}
