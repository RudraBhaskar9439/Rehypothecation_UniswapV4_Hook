// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAave, ReserveData} from "../src/interfaces/IAave.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAave is IAave {
    mapping(address => uint256) public totalDeposits;
    mapping(address => address) public aTokenAddresses;
    mapping(address => bool) public supportedAssets;

    // Mock aToken that just tracks balances
    mapping(address => mapping(address => uint256)) public aTokenBalances; // asset => user => balance

    event DepositMock(address indexed asset, uint256 amount, address indexed user);
    event WithdrawMock(address indexed asset, uint256 amount, address indexed user);

    constructor() {
        // Initialize some mock supported assets - use your actual token addresses
    }

    function addSupportedAsset(address asset, address aToken) external {
        supportedAssets[asset] = true;
        aTokenAddresses[asset] = aToken;
    }

    function deposit(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        require(supportedAssets[asset], "Asset not supported");
        require(amount > 0, "Amount must be > 0");

        // Transfer tokens from sender to this contract
        IERC20(asset).transferFrom(msg.sender, address(this), amount);

        // Update aToken balance
        aTokenBalances[asset][onBehalfOf] += amount;
        totalDeposits[asset] += amount;

        emit DepositMock(asset, amount, onBehalfOf);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        require(supportedAssets[asset], "Asset not supported");
        require(aTokenBalances[asset][msg.sender] >= amount, "Insufficient aToken balance");

        // Update aToken balance
        aTokenBalances[asset][msg.sender] -= amount;
        totalDeposits[asset] -= amount;

        // Transfer underlying asset
        IERC20(asset).transfer(to, amount);

        emit WithdrawMock(asset, amount, to);
        return amount;
    }

    function getReserveData(address asset) external view override returns (ReserveData memory) {
        if (!supportedAssets[asset]) {
            // Return empty data for unsupported assets
            return ReserveData({
                liquidityIndex: 0,
                currentLiquidityRate: 0,
                variableBorrowIndex: 0,
                currentVariableBorrowRate: 0,
                currentStableBorrowRate: 0,
                lastUpdateTimestamp: 0,
                id: 0,
                aTokenAddress: address(0),
                stableDebtTokenAddress: address(0),
                variableDebtTokenAddress: address(0),
                interestRateStrategyAddress: address(0),
                accruedToTreasury: 0,
                unbacked: 0,
                isolationModeTotalDebt: 0
            });
        }

        return ReserveData({
            liquidityIndex: 1e18, // 1.0 in ray format
            currentLiquidityRate: 0,
            variableBorrowIndex: 1e18,
            currentVariableBorrowRate: 0,
            currentStableBorrowRate: 0,
            lastUpdateTimestamp: uint40(block.timestamp),
            id: 1,
            aTokenAddress: aTokenAddresses[asset],
            stableDebtTokenAddress: address(this), // Mock address
            variableDebtTokenAddress: address(this), // Mock address
            interestRateStrategyAddress: address(this), // Mock address
            accruedToTreasury: 0,
            unbacked: 0,
            isolationModeTotalDebt: 0
        });
    }

    // Helper function to get aToken balance (simulates aToken.balanceOf)
    function getATokenBalance(address asset, address user) external view returns (uint256) {
        return aTokenBalances[asset][user];
    }
}
