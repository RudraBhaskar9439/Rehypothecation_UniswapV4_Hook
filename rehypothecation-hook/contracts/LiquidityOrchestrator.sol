// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Constant} from "./utils/Constants.sol";
import {ILiquidityOrchestrator} from "./interfaces/ILiquidityOrchestrator.sol";

contract LiquidityOrchestrator is ILiquidityOrchestrator {
    error PositionNotFound();
    error NotOwner();

    using Constant for uint256;

    address public owner;

    mapping(bytes32 => PositionData) public positions;// positionKey => PositionData

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    event HandlingRebalanceFailure(bytes32 positionKey, bool success);
    event PositionUpserted(bytes32 positionKey, address owner);
    event PositionPaused(bytes32 positionKey);
    event PositionResumed(bytes32 positionKey);

    function shouldRebalancePosition(bytes32 positionKey, int24 currentTick) external view returns (bool) {
        PositionData storage p = positions[positionKey];
        if (!p.exists || p.totalLiquidity < Constant.MIN_POSITION_SIZE) {
            return false;
        }
        if (p.state == PositionState.AAVE_STUCK) {
            return false;
        }

        bool currentlyInRange = (currentTick >= p.tickLower && currentTick <= p.tickUpper);
        bool storedAsRange = (p.state == PositionState.IN_RANGE);


        return currentlyInRange != storedAsRange;
    }

    function shouldRebalancePositions(bytes32[] calldata positionKeys, int24 currentTick) external view returns (bool[] memory) {
        uint256 len = positionKeys.length;
        bool[] memory results = new bool[](len);

        // Check each position
        for (uint256 i = 0; i < len;) {
            results[i] = this.shouldRebalancePosition(positionKeys[i], currentTick);

            unchecked {
                ++i;
            }
        }

        return results;
    }

    function calculateOptimalSplit(bytes32 positionKey, uint256 withdrawAmount0, uint256 withdrawAmount1)
        external
        view
        returns (RebalancePlan memory plan)
    {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }

        // Determine reserve percentage
        uint8 reservePCT = p.reservePct == 0 ? Constant.DEFAULT_RESERVE_PCT : p.reservePct;

        plan.withdrawAmount0 = withdrawAmount0;
        plan.withdrawAmount1 = withdrawAmount1;
        plan.keepAsReserve0 = (withdrawAmount0 * reservePCT) / 100;
        plan.keepAsReserve1 = (withdrawAmount1 * reservePCT) / 100;
        plan.depositToAave0 = withdrawAmount0 - plan.keepAsReserve0;
        plan.depositToAave1 = withdrawAmount1 - plan.keepAsReserve1;

        return plan;
    }

    function handleRebalanceFail(bytes32 positionKey, uint256 expectedAmount0, uint256 expectedAmount1)
        external
        returns (bool shouldRetry, bool allowPartialSwap, uint256 maxWaitTime)
    {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }

        // change the state to AAVE_STUCK
        p.state = PositionState.AAVE_STUCK;
        emit HandlingRebalanceFailure(positionKey, false);

        return (shouldRetry, allowPartialSwap, maxWaitTime);
    }

    function validateAccountingBalance(bytes32 positionKey) external view returns (bool valid, uint256 discrepancy) {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }
        return (true, 0);
    }

    function upsertPosition(bytes32 positionKey, PositionData calldata data) external override {
        positions[positionKey] = data;
        positions[positionKey].exists = true;
        emit PositionUpserted(positionKey, data.owner);
    }

    function getPosition(bytes32 positionKey) external view returns (PositionData memory) {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }
        return p;
    }

    function pausePosition(bytes32 positionKey) external override onlyOwner {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }
        p.state = PositionState.AAVE_STUCK;
        emit PositionPaused(positionKey);
    }

    function resumePosition(bytes32 positionKey) external override onlyOwner {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }
        p.state = PositionState.OUT_OF_RANGE;
        emit PositionResumed(positionKey);
    }
}