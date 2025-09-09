//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAave} from "./interfaces/IAave.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ILendingPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract Aave is IAave {
    ILendingPool public aave;

    error InvalidInput();

    constructor(address _aave) {
        aave = ILendingPool(_aave);
    }

    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        if (asset == address(0) || amount <= 0 || onBehalfOf == address(0)) {
            revert InvalidInput();
        }

        IERC20(asset).approve(address(aave), amount);
        aave.supply(asset, amount, onBehalfOf, referralCode);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        if (asset == address(0) || amount <= 0 || to == address(0)) {
            revert InvalidInput();
        }
        uint256 withdrawn = aave.withdraw(asset, amount, to);
        return withdrawn;
    }
}
