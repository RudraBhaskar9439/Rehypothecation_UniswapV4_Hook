// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Constant} from "./utils/Constant.sol";
import {ILiquidityOrchestrator} from "./interfaces/ILiquidityOrchestrator.sol";
import {IAave} from "./interfaces/IAave.sol";

abstract contract LiquidityOrchestrator is ILiquidityOrchestrator {
    IAave public Aave;
    error PositionNotFound();
    error NotOwner();
    error PreSwapLiquidityPreparationFailed(bytes32 positionKey);

    using Constant for uint256;

    address public owner;
    bytes32[] public stuckPositions;

    mapping(bytes32 => PositionData) public positions; // positionKey => PositionData
    mapping(bytes32 => int24) public lastActiveTick; // positionKey => lastActiveTick

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    constructor(address _aave) {
        owner = msg.sender;
        Aave = IAave(_aave);
    }

    event HandlingRebalanceFailure(bytes32 positionKey, bool success);
    event PositionUpserted(bytes32 positionKey, address owner);
    event PositionPaused(bytes32 positionKey);
    event PositionResumed(bytes32 positionKey);
    event StuckPositionRecovered(bytes32 positionKey);
    event PreSwapLiquidityPrepared(
        bytes32 positionKey,
        bool wasInAave,
        uint256 amount0,
        uint256 amount1
    );
    event PostSwapLiquidityDeposited(
        bytes32 positionKey,
        bool wasInAave,
        uint256 amount0,
        uint256 amount1
    );
    event DepositFailed(bytes32 positionKey, string reason);

    /**
     * @notice Check if position needs liquidity withdrawal BEFORE swap (current range has liquidity in Aave)
     * @param positionKey The position identifier
     * @param currentTick Current tick before swap
     * @return needsWithdrawal True if position is currently active but liquidity is in Aave
     */
    function checkPreSwapLiquidityNeeds(
        bytes32 positionKey,
        int24 currentTick
    ) public view returns (bool needsWithdrawl) {
        PositionData storage p = positions[positionKey];
        if (!p.exists || p.totalLiquidity < Constant.MIN_POSITION_SIZE) {
            return false;
        }

        // Check if position is currently in range (swap will use this liquidity)
        bool currentlyInRange = (currentTick >= p.tickLower &&
            currentTick <= p.tickUpper);

        // Need withdrawal if: position is currently active BUT liquidity is stuck in Aave
        return currentlyInRange && p.state == PositionState.IN_AAVE;
    }

    /**
     * @notice Check if position needs liquidity deposit AFTER swap (tick leaving range)
     * @param positionKey The position identifier
     * @param oldTick Tick before swap
     * @param newTick Tick after swap
     * @return needsDeposit True if position became inactive and should go to Aave
     */
    function checkPostSwapLiquidityNeeds(
        bytes32 positionKey,
        int24 oldTick,
        int24 newTick
    ) public view returns (bool needsDeposit) {
        PositionData storage p = positions[positionKey];
        if (!p.exists || p.totalLiquidity < Constant.MIN_POSITION_SIZE) {
            return false;
        }

        // Check if position is currently in range (swap will use this liquidity)
        bool currentlyInRange = (newTick >= p.tickLower &&
            newTick <= p.tickUpper);
        bool wasInRange = (oldTick >= p.tickLower && oldTick <= p.tickUpper);

        // Need deposit if: position became inactive AND liquidity is currently in Uniswap
        return
            wasInRange &&
            !currentlyInRange &&
            p.state == PositionState.IN_RANGE;
    }

    /**
     * @notice Execute pre-swap liquidity preparation (withdraw from Aave if needed)
     * @param positionKey The position identifier
     * @param currentTick Current tick
     * @return success True if preparation successful
     * @return availableAmount0 Amount of token0 available for swap
     * @return availableAmount1 Amount of token1 available for swap
     */
    function preparePreSwapLiquidity(
        bytes32 positionKey,
        int24 currentTick,
        address asset0,
        address asset1
    )
        external
        returns (
            bool success,
            uint256 availableAmount0,
            uint256 avaavailableAmount1
        )
    {
        if (!checkPreSwapLiquidityNeeds(positionKey, currentTick)) {
            PositionData memory p = positions[positionKey];
            return (true, p.reserveAmount0, p.reserveAmount1);
        }

        PositionData storage p = positions[positionKey];

        try Aave.withdraw(asset0, p.aaveAmount0, msg.sender) returns (
            uint256 withdrawnAmount0
        ) {
            try Aave.withdraw(asset1, p.aaveAmount1, msg.sender) returns (
                uint256 withdrawnAmount1
            ) {
                p.state = PositionState.IN_RANGE;
                p.reserveAmount0 += withdrawnAmount0;
                p.reserveAmount1 += withdrawnAmount1;
                p.aaveAmount0 = 0;
                p.aaveAmount1 = 0;

                emit PreSwapLiquidityPrepared(
                    positionKey,
                    true,
                    withdrawnAmount0,
                    withdrawnAmount1
                );
                return (true, p.reserveAmount0, p.reserveAmount1);
            } catch {
                return _handleWithdrawalFailure(positionKey);
            }
        } catch {
            return _handleWithdrawalFailure(positionKey);
        }
    }

    /**
     * @notice Execute post-swap liquidity management (deposit to Aave if position went out of range)
     * @param positionKey The position identifier
     * @param oldTick Tick before swap
     * @param newTick Tick after swap
     * @return success True if post-swap management successful
     */
    function executePostSwapManagement(
        bytes32 positionKey,
        int24 oldTick,
        int24 newTick,
        address asset0,
        address asset1
    ) external returns (bool success) {
        if (!checkPostSwapLiquidityNeeds(positionKey, oldTick, newTick)) {
            return true;
        }

        PositionData storage p = positions[positionKey];
        lastActiveTick[positionKey] = oldTick; // Remember last active tick

        // Calculate amounts to deposit (keep reserve buffer)
        uint8 reservePCT = p.reservePct == 0
            ? Constant.DEFAULT_RESERVE_PCT
            : p.reservePct;

        uint256 depositAmount0 = (p.reserveAmount0 * (100 - reservePCT)) / 100;
        uint256 depositAmount1 = (p.reserveAmount1 * (100 - reservePCT)) / 100;

        if (depositAmount0 == 0 && depositAmount1 == 0) {
            return true; // Nothing to deposit
        }

        try Aave.deposit(asset0, depositAmount0, msg.sender, 0) {
            try Aave.deposit(asset1, depositAmount1, msg.sender, 0) {
                // Update position state
                p.state = PositionState.IN_AAVE;
                p.reserveAmount0 -= depositAmount0;
                p.reserveAmount1 -= depositAmount1;
                p.aaveAmount0 += depositAmount0;
                p.aaveAmount1 += depositAmount1;

                emit PostSwapLiquidityDeposited(
                    positionKey,
                    depositAmount0,
                    depositAmount1
                );
                return true;
            } catch Error(string memory reason) {
                // Deposit failed - keep liquidity in Uniswap for now
                emit DepositFailed(positionKey, reason);
                return false;
            }
        } catch Error(string memory reason) {
            // Deposit failed - keep liquidity in Uniswap for now
            emit DepositFailed(positionKey, reason);
            return false;
        }
    }

    /**
     * @notice Handle withdrawal failure with fallback strategies
     */
    function _handleWithdrawalFailure(
        bytes32 positionKey
    )
        internal
        returns (
            bool success,
            uint256 availableAmount0,
            uint256 availableAmount1
        )
    {
        PositionData storage p = positions[positionKey];

        p.state = PositionState.AAVE_STUCK;
        stuckPositions.push(positionKey);

        // Check if there are any available funds to withdraw in the Uniswap reserve
        if (p.reserveAmount0 > 0 || p.reserveAmount1 > 0) {
            return (true, p.reserveAmount0, p.reserveAmount1);
        }

        return (false, 0, 0);
    }

    /**
     * @notice Try to recover a stuck position
     */
    function _tryRecoverStuckPosition(
        bytes32 positionKey,
        address asset0,
        address asset1
    ) internal returns (bool success) {
        PositionData storage p = positions[positionKey];

        try Aave.withdraw(asset0, p.aaveAmount0, msg.sender) returns (
            uint256 withdrawn0
        ) {
            try Aave.withdraw(asset1, p.aaveAmount1, msg.sender) returns (
                uint256 withdrawn1
            ) {
                // Update position
                p.reserveAmount0 += withdrawn0;
                p.reserveAmount1 += withdrawn1;
                p.aaveAmount0 = 0;
                p.aaveAmount1 = 0;

                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    /**
     * @notice Retry stuck positions - attempt to withdraw from Aave again
     */
    function retryStuckPositions() external {
        uint256 len = stuckPositions.length;
        if (len == 0) return;

        bytes32[] memory stillStuck = new bytes32[](len);
        uint256 stillStuckCount = 0;

        for (uint256 i = 0; i < len; ) {
            bytes32 positionKey = stuckPositions[i];

            if (_tryRecoverStuckPosition(positionKey)) {
                // Recovery successful
                positions[positionKey].state = PositionState.IN_RANGE;
            } else {
                // Still stuck
                stillStuck[stillStuckCount] = positionKey;
                stillStuckCount++;
            }

            unchecked {
                ++i;
            }
        }

        // Update stuck positions array
        delete stuckPositions;
        for (uint256 i = 0; i < stillStuckCount; ) {
            stuckPositions.push(stillStuck[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Try to recover a stuck position
     */
    function _tryRecoverStuckPosition(
        bytes32 positionKey,
        address asset0,
        address asset1
    ) internal returns (bool success) {
        PositionData storage p = positions[positionKey];

        try Aave.withdraw(asset0, p.aaveAmount0, msg.sender) returns (
            uint256 withdrawn0
        ) {
            try Aave.withdraw(asset1, p.aaveAmount1, msg.sender) returns (
                uint256 withdrawn1
            ) {
                // Update position
                p.reserveAmount0 += withdrawn0;
                p.reserveAmount1 += withdrawn1;
                p.aaveAmount0 = 0;
                p.aaveAmount1 = 0;

                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    /**
     * @notice Get available liquidity for a position (Uniswap + Aave)
     */
    function getAvailableLiquidity(
        bytes32 positionKey
    )
        external
        view
        returns (uint256 amount0, uint256 amount1, PositionState state)
    {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }

        return (
            p.reserveAmount0 + p.aaveAmount0,
            p.reserveAmount1 + p.aaveAmount1,
            p.state
        );
    }

    // Position management functions
    function upsertPosition(
        bytes32 positionKey,
        PositionData calldata data
    ) external override {
        positions[positionKey] = data;
        positions[positionKey].exists = true;
        positions[positionKey].state = PositionState.IN_RANGE; // Initially in Uniswap
        emit PositionUpserted(positionKey, data.owner);
    }

    function getPosition(
        bytes32 positionKey
    ) external view returns (PositionData memory) {
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
    }

    function resumePosition(bytes32 positionKey) external override onlyOwner {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }
        p.state = PositionState.IN_RANGE;
    }
}
