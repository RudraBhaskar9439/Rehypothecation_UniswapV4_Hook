// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Constant} from "./utils/Constant.sol";
import {ILiquidityOrchestrator} from "./interfaces/ILiquidityOrchestrator.sol";
import {IAave} from "./interfaces/IAave.sol";

abstract contract LiquidityOrchestrator is ILiquidityOrchestrator {
    IAave public Aave;

    error PositionNotFound();
    error NotOwner();

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
    event PositionUpserted(bytes32 positionKey);
    event PositionResumed(bytes32 positionKey);
    event StuckPositionRecovered(bytes32 positionKey);
    event PreSwapLiquidityPrepared(bytes32 positionKey, uint256 amount);
    event PostSwapLiquidityDeposited(bytes32 positionKey, uint256 amount);
    event DepositFailed(bytes32 positionKey, string reason);
    event WithdrawalFailed(bytes32 positionKey, string reason);
    event PreparePositionForWithdrawed(bytes32 positionKey, uint256 amount);
    event PreparePositionForWithdrawalFailed(bytes32 positionKey, string reason);
    event PostWithdrawalLiquidityDeposited(bytes32 positionKey, uint256 amount);
    event PostAddLiquidityDeposited(bytes32 positionKey, uint256 amount);

    /**
     * @notice Check if position needs liquidity withdrawal BEFORE swap (current range has liquidity in Aave)
     * @param positionKey The position identifier
     * @param currentTick Current tick before swap
     * @return needsWithdrawal True if position is currently active but liquidity is in Aave
     */
    function checkPreSwapLiquidityNeeds(bytes32 positionKey, int24 currentTick)
        public
        view
        returns (bool needsWithdrawal)
    {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }

        // Check if position is currently in range (swap will use this liquidity)

        bool currentlyInRange = (currentTick >= p.tickLower && currentTick <= p.tickUpper);

        // Need withdrawal if: position is currently active BUT liquidity is stuck in Aave
        return currentlyInRange && (p.state == PositionState.IN_AAVE || p.state == PositionState.AAVE_STUCK);
    }

    /**
     * @notice Check if position needs liquidity deposit AFTER swap (tick leaving range)
     * @param positionKey The position identifier
     * @param oldTick Tick before swap
     * @param newTick Tick after swap
     * @return needsDeposit True if position became inactive and should go to Aave
     */
    function checkPostSwapLiquidityNeeds(bytes32 positionKey, int24 oldTick, int24 newTick)
        public
        view
        returns (bool needsDeposit)
    {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            return false;
        }

        // Check if position is currently in range (swap will use this liquidity)
        bool currentlyInRange = (newTick >= p.tickLower && newTick <= p.tickUpper);
        bool wasInRange = (oldTick >= p.tickLower && oldTick <= p.tickUpper);

        // Need deposit if: position became inactive AND liquidity is currently in Uniswap
        return wasInRange && !currentlyInRange && p.state == PositionState.IN_RANGE;
    }

    /**
     * @notice Execute pre-swap liquidity preparation (withdraw from Aave if needed). To be called by beforeSwap hook
     * @param positionKey The position identifier
     * @param currentTick Current tick
     * @return success True if preparation successful
     */
    function preparePreSwapLiquidity(bytes32 positionKey, int24 currentTick, address asset0, address asset1)
        external
        returns (bool success)
    {
        if (!checkPreSwapLiquidityNeeds(positionKey, currentTick)) {
            return true;  // Already in uniswap
        }

        PositionData storage p = positions[positionKey];

        try Aave.withdraw(asset0, p.aaveAmount0, msg.sender) returns (uint256 withdrawnAmount0) {
            try Aave.withdraw(asset1, p.aaveAmount1, msg.sender) returns (uint256 withdrawnAmount1) {
                p.reserveAmount1 += withdrawnAmount1;
                p.aaveAmount1 = 0;
                emit PreSwapLiquidityPrepared(positionKey, withdrawnAmount1);
            } catch {
                p.state = PositionState.AAVE_STUCK;
                emit WithdrawalFailed(positionKey, "Token1 withdrawal failed");
                return false;
            }
            p.state = PositionState.IN_RANGE;
            p.reserveAmount0 += withdrawnAmount0;
            p.aaveAmount0 = 0;
            emit PreSwapLiquidityPrepared(positionKey, withdrawnAmount0);
            return true;
        } catch {
            emit WithdrawalFailed(positionKey, "Token0 withdrawal failed");
            return false;
        }
    }

    /**
     * @notice Execute post-swap liquidity management (deposit to Aave if position went out of range). To be called by afterSwap hook
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
        // Even if no liquidity management is required, still the record of last Active tick
        // If the position exists and was in range
        PositionData storage p = positions[positionKey];
        // if (p.exists) {
        //     lastActiveTick[positionKey] = newTick;
        // } 

            }
            return true;
        }

        
        

        // Calculate amounts to deposit (keep reserve buffer)

        uint8 reservePCT = p.reservePct == 0 ? Constant.DEFAULT_RESERVE_PCT : p.reservePct;

        uint256 depositAmount0 = (p.reserveAmount0 * (100 - reservePCT)) / 100;
        uint256 depositAmount1 = (p.reserveAmount1 * (100 - reservePCT)) / 100;

        if (depositAmount0 == 0 && depositAmount1 == 0) {
            // lastActiveTick[positionKey] = newTick;  // Update the last active tick even if there is nothing ot deposit
            return true; // Nothing to deposit
        }

        try Aave.deposit(asset0, depositAmount0, msg.sender, 0) {
            try Aave.deposit(asset1, depositAmount1, msg.sender, 0) {
                p.reserveAmount1 -= depositAmount1;
                p.aaveAmount1 += depositAmount1;

                emit PostSwapLiquidityDeposited(positionKey, depositAmount1);
            } catch {
                emit DepositFailed(positionKey, "Token1 deposit failed");
                return false;
            }
            p.reserveAmount0 -= depositAmount0;
            p.aaveAmount0 += depositAmount0;
            p.state = PositionState.IN_AAVE;

            emit PostSwapLiquidityDeposited(positionKey, depositAmount0);
            return true;
        } catch {
            // Deposit failed - keep liquidity in Uniswap for now
            // emit DepositFailed(positionKey, "Token0 or Token1 deposit failed");
            // Even if the deposit failed, the liquidity is still conceptually in rage for now, so lastActiveTick should reflect the newTick where it got stuck.
            lastActiveTick[positionKey] = newTick;
            return false;
        }
    }

    /**
     * @notice  This is a helper function to prepare position for withdrawal in case if the LP wants to withdraw. To be called by beforeRemoveLiquidity hook
     * @param   positionKey  The position identifier
     * @return  success  True if preparation was successful
     */
    function preparePositionForWithdrawal(bytes32 positionKey, address asset0, address asset1)
        external
        returns (bool success)
    {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }

        if (p.state == PositionState.IN_RANGE) {
            // Nothing to do - liquidity already in Uniswap
            return true;
        }

        if (p.aaveAmount0 >= 0 && p.aaveAmount1 >= 0) {
            try Aave.withdraw(asset0, p.aaveAmount0, msg.sender) returns (uint256 withdrawnAmount0) {
                try Aave.withdraw(asset1, p.aaveAmount1, msg.sender) returns (uint256 withdrawnAmount1) {
                    p.reserveAmount1 += withdrawnAmount1;
                    p.aaveAmount1 = 0;

                    emit PreparePositionForWithdrawed(positionKey, withdrawnAmount1);
                } catch {
                    emit PreparePositionForWithdrawalFailed(positionKey, "Token1 withdrawal failed");
                    return false;
                }
                p.state = PositionState.IN_RANGE;
                p.reserveAmount0 += withdrawnAmount0;
                p.aaveAmount0 = 0;
                emit PreparePositionForWithdrawed(positionKey, withdrawnAmount0);
                return true;
            } catch {
                p.state = PositionState.AAVE_STUCK;
                emit PreparePositionForWithdrawalFailed(positionKey, "Token0 withdrawal failed");
                return false;
            }
        }
    }

    /**
     * @notice Handle post-withdrawal rebalance (called after user withdraws liquidity). To be called by afterRemoveLiquidity hook
     * @param positionKey The position identifier
     * @param currentTick Current tick after withdrawal
     * @param liqAmount0 Amount of token0 available after user withdrawal
     * @param liqAmount1 Amount of token1 available after user withdrawal
     * @return success True if rebalance successful
     */
    function handlePostWithdrawalRebalance(
        bytes32 positionKey,
        int24 currentTick,
        uint256 liqAmount0,
        uint256 liqAmount1,
        address asset0,
        address asset1
    ) external returns (bool success) {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }
        p.reserveAmount0 = liqAmount0;
        p.reserveAmount1 = liqAmount1;
        p.aaveAmount0 = 0;
        p.aaveAmount1 = 0;
        p.totalLiquidity = liqAmount0 + liqAmount1;

        bool outOfRange = (currentTick < p.tickLower || currentTick > p.tickUpper);
        if (outOfRange && p.state == PositionState.IN_RANGE) {
            // Position is out of range and liquidity is in Uniswap - deposit to Aave
            uint256 amount0ToDeposit = (p.reserveAmount0 * 80) / 100;
            uint256 amount1ToDeposit = (p.reserveAmount1 * 80) / 100;

            if (amount0ToDeposit == 0 && amount1ToDeposit == 0) {
                return true; // Nothing to deposit is there
            }

            try Aave.deposit(asset0, amount0ToDeposit, msg.sender, 0) {
                try Aave.deposit(asset1, amount1ToDeposit, msg.sender, 0) {
                    emit PostWithdrawalLiquidityDeposited(positionKey, amount1ToDeposit);
                } catch {
                    emit DepositFailed(positionKey, "Token1 deposit failed");
                    return false;
                }
                p.reserveAmount0 -= amount0ToDeposit;
                p.reserveAmount1 -= amount1ToDeposit;
                p.aaveAmount0 += amount0ToDeposit;
                p.aaveAmount1 += amount1ToDeposit;
                p.state = PositionState.IN_AAVE;

                emit PostWithdrawalLiquidityDeposited(positionKey, amount0ToDeposit);
                return true;
            } catch {
                emit DepositFailed(positionKey, "Token0 or Token1 deposit failed");
                return false;
            }
        }
    }

    /**
     * @notice Process liquidity addition (called whenever user adds liquidity to position). To be called by afterAddLiquidity hook
     * @param   positionKey  The position identifier
     * @param   currentTick  The current tick of the position
     * @param   liqAmount0  The amount of token0 being added
     * @param   liqAmount1  The amount of token1 being added
     * @return  success  True if the liquidity addition was processed successfully
     */
    function processLiquidityAdditionDeposit(
        bytes32 positionKey,
        int24 currentTick,
        uint256 liqAmount0,
        uint256 liqAmount1,
        address asset0,
        address asset1
    ) external returns (bool success) {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }

        bool outOfRange = (currentTick < p.tickLower || currentTick > p.tickUpper);

        if (outOfRange) {
            // Position is out of range and liquidity is in Uniswap - deposit to Aave
            p.state = PositionState.IN_RANGE;
            uint256 amount0ToDeposit = (liqAmount0 * (100 - Constant.DEFAULT_RESERVE_PCT)) / 100;
            uint256 amount1ToDeposit = (liqAmount1 * (100 - Constant.DEFAULT_RESERVE_PCT)) / 100;

            if (amount0ToDeposit == 0 && amount1ToDeposit == 0) {
                return true; // Nothing to deposit is there
            }

            try Aave.deposit(asset0, amount0ToDeposit, msg.sender, 0) {
                try Aave.deposit(asset1, amount1ToDeposit, msg.sender, 0) {
                    emit PostWithdrawalLiquidityDeposited(positionKey, amount1ToDeposit);
                } catch {
                    emit DepositFailed(positionKey, "Token1 deposit failed");
                    return false;
                }
                p.reserveAmount0 -= amount0ToDeposit;
                p.reserveAmount1 -= amount1ToDeposit;
                p.aaveAmount0 += amount0ToDeposit;
                p.aaveAmount1 += amount1ToDeposit;
                p.state = PositionState.IN_AAVE;

                emit PostAddLiquidityDeposited(positionKey, amount0ToDeposit);
                return true;
            } catch {
                emit DepositFailed(positionKey, "Token0 or Token1 deposit failed");
                return false;
            }
        } else {
            p.state = PositionState.IN_RANGE;
            return true;
        }
    }

    // /**
    //  * @notice Handle withdrawal failure with fallback strategies
    //  */
    // function _handleWithdrawalFailure(bytes32 positionKey) internal {
    //     PositionData storage p = positions[positionKey];

    //     p.state = PositionState.AAVE_STUCK;
    //     stuckPositions.push(positionKey);
    // }

    // /**
    //  * @notice Try to recover a stuck position
    //  */
    // function _tryRecoverStuckPosition(bytes32 positionKey, address asset0, address asset1)
    //     internal
    //     returns (bool success)
    // {
    //     PositionData storage p = positions[positionKey];

    //     try Aave.withdraw(asset0, p.aaveAmount0, msg.sender) returns (uint256 withdrawn0) {
    //         try Aave.withdraw(asset1, p.aaveAmount1, msg.sender) returns (uint256 withdrawn1) {
    //             // Update position
    //             p.reserveAmount0 += withdrawn0;
    //             p.reserveAmount1 += withdrawn1;
    //             p.aaveAmount0 = 0;
    //             p.aaveAmount1 = 0;

    //             return true;
    //         } catch {
    //             return false;
    //         }
    //     } catch {
    //         return false;
    //     }
    // }

    // /**
    //  * @notice Retry stuck positions - attempt to withdraw from Aave again
    //  */
    // function retryStuckPositions(address asset0, address asset1) external {
    //     uint256 len = stuckPositions.length;
    //     if (len == 0) return;

    //     bytes32[] memory stillStuck = new bytes32[](len);
    //     uint256 stillStuckCount = 0;

    //     for (uint256 i = 0; i < len;) {
    //         bytes32 positionKey = stuckPositions[i];

    //         if (_tryRecoverStuckPosition(positionKey, asset0, asset1)) {
    //             // Recovery successful
    //             positions[positionKey].state = PositionState.IN_RANGE;
    //         } else {
    //             // Still stuck
    //             stillStuck[stillStuckCount] = positionKey;
    //             stillStuckCount++;
    //         }

    //         unchecked {
    //             ++i;
    //         }
    //     }

    //     // Update stuck positions array
    //     delete stuckPositions;
    //     for (uint256 i = 0; i < stillStuckCount;) {
    //         stuckPositions.push(stillStuck[i]);
    //         unchecked {
    //             ++i;
    //         }
    //     }
    // }

    /**
     * @notice Get available liquidity for a position (Uniswap + Aave)
     */
    function getAvailableLiquidity(bytes32 positionKey)
        external
        view
        returns (uint256 amount0, uint256 amount1, PositionState state)
    {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }
        return (p.reserveAmount0 + p.aaveAmount0, p.reserveAmount1 + p.aaveAmount1, p.state);
    }

    // Position management functions
    function upsertPosition(bytes32 positionKey, PositionData calldata data) external override {
        positions[positionKey] = data;
        emit PositionUpserted(positionKey);
    }

    function getPosition(bytes32 positionKey) external view returns (PositionData memory) {
        return positions[positionKey];
    }

    function isPositionExists(bytes32 positionKey) external view returns (bool) {
        return positions[positionKey].exists;
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

    function setLastActiveTick(bytes32 positionKey, int24 tick) external onlyOwner {
        if (!positions[positionKey].exists) {
            revert PositionNotFound();
        }
        lastActiveTick[positionKey] = tick;
    }
}
