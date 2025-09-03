//SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

library Constant {
    uint8 public constant DEFAULT_RESERVE_PCT = 20;
    uint256 public constant MIN_POSITION_SIZE = 1e15;
    uint256 public constant MAX_DISCREPANCY = 1e12;

    // Reserve Percentages
    uint256 public constant RESERVE_PERCENTAGE_DEFAULT = 20;   // 20% RESERVE
    uint256 public constant MIN_RESERVE_PERCENTAGE = 10;  // 10% minimum
    uint256 public constant MAX_RESERVE_PERCENTAGE = 50;  // 50% MAXIMUM

    // Emergency withdrawal
    uint256 public constant EMERGENCY_WITHDRAWAL_DELAY = 1 hours;
}

