// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

interface IAave {
    /**
     * @dev Deposits an asset into the aave lending pool
     * @param asset The address of the asset to deposit
     * @param amount The amount of asset to deposit
     * @param onBehalfOf The address that will recieve the aTokens
     * @param referralCode The referral code for rewards
     *
     */

    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external returns (uint256); // can only be called from outside of the contract

    /**
     * @dev Withdraws an asset from the aave lending pool
     * @param asset The address of the asset to withdraw
     * @param amount The amount to withdraw
     * @param to The address to send the withdrawn asset to
     */

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}
