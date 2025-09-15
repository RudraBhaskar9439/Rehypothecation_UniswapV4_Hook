// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constant} from "./utils/Constant.sol";
import {ILiquidityOrchestrator} from "./interfaces/ILiquidityOrchestrator.sol";
import {IAave} from "./interfaces/IAave.sol";
import {euint256, FHE, ebool, euint32} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReserveData} from "./interfaces/IAave.sol";
import {console} from "forge-std/console.sol";

contract LiquidityOrchestrator is ILiquidityOrchestrator {
    IAave public Aave;

    using Constant for uint256;

    address public owner;
    bytes32[] public stuckPositions;

    mapping(bytes32 => PositionData) public positions; // positionKey => PositionData
    mapping(bytes32 => euint32) private encryptedReservePercentages;
    mapping(address => uint256) public totalDeposited; // token address => total deposited amount

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

    /**
     * @notice Get aToken balance for a specific asset
     * @param asset The underlying asset address
     * @return aTokenBalance The balance of aTokens held by this contract
     */
    function getATokenBalance(
        address asset
    ) internal view returns (uint256 aTokenBalance) {
        ReserveData memory reserveData = Aave.getReserveData(asset);
        address aTokenAddress = reserveData.aTokenAddress;
        return IERC20(aTokenAddress).balanceOf(address(this));
    }

    /**
     * @notice Check if position needs liquidity withdrawal BEFORE swap (current range has liquidity in Aave)
     * @param positionKey The position identifier
     * @param currentTick Current tick before swap
     * @return needsWithdrawal True if position is currently active but liquidity is in Aave
     */
    function checkPreSwapLiquidityNeeds(
        bytes32 positionKey,
        int24 currentTick
    ) public returns (bool needsWithdrawal) {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }

        // Encrypt tick comparison logic
        euint32 encryptedCurrentTick = FHE.asEuint32(
            uint32(int32(currentTick))
        );
        euint32 encryptedTickLower = FHE.asEuint32(uint32(int32(p.tickLower)));
        euint32 encryptedTickUpper = FHE.asEuint32(uint32(int32(p.tickUpper)));

        // Use FHE boolean operations instead of | and &
        ebool inRangeLower = FHE.or(
            FHE.gt(encryptedCurrentTick, encryptedTickLower),
            FHE.eq(encryptedCurrentTick, encryptedTickLower)
        );

        ebool inRangeUpper = FHE.or(
            FHE.lt(encryptedCurrentTick, encryptedTickUpper),
            FHE.eq(encryptedCurrentTick, encryptedTickUpper)
        );

        ebool currentlyInRange = FHE.and(inRangeLower, inRangeUpper);

        // Encrypt state check
        ebool isInAave = FHE.eq(
            FHE.asEuint32(uint32(uint8(p.state))),
            FHE.asEuint32(uint32(uint8(PositionState.IN_AAVE)))
        );

        ebool isAaveStuck = FHE.eq(
            FHE.asEuint32(uint32(uint8(p.state))),
            FHE.asEuint32(uint32(uint8(PositionState.AAVE_STUCK)))
        );

        ebool needsWithdrawalEncrypted = FHE.and(
            currentlyInRange,
            FHE.or(isInAave, isAaveStuck)
        );

        // Decrypt the result
        (needsWithdrawal, ) = FHE.getDecryptResultSafe(
            needsWithdrawalEncrypted
        );
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
    ) public returns (bool needsDeposit) {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            return false;
        }

        // Encrypt tick comparisons
        euint32 encryptedNewTick = FHE.asEuint32(uint32(int32(newTick)));
        euint32 encryptedOldTick = FHE.asEuint32(uint32(int32(oldTick)));
        euint32 encryptedTickLower = FHE.asEuint32(uint32(int32(p.tickLower)));
        euint32 encryptedTickUpper = FHE.asEuint32(uint32(int32(p.tickUpper)));

        // Encrypted range checks using FHE boolean operations
        ebool currentlyInRange = FHE.and(
            FHE.or(
                FHE.gt(encryptedNewTick, encryptedTickLower),
                FHE.eq(encryptedNewTick, encryptedTickLower)
            ),
            FHE.or(
                FHE.lt(encryptedNewTick, encryptedTickUpper),
                FHE.eq(encryptedNewTick, encryptedTickUpper)
            )
        );

        ebool wasInRange = FHE.and(
            FHE.or(
                FHE.gt(encryptedOldTick, encryptedTickLower),
                FHE.eq(encryptedOldTick, encryptedTickLower)
            ),
            FHE.or(
                FHE.lt(encryptedOldTick, encryptedTickUpper),
                FHE.eq(encryptedOldTick, encryptedTickUpper)
            )
        );

        // Encrypt state check
        ebool isInRange = FHE.eq(
            FHE.asEuint32(uint32(uint8(p.state))),
            FHE.asEuint32(uint32(uint8(PositionState.IN_RANGE)))
        );

        // Encrypted logic: wasInRange && !currentlyInRange && p.state == PositionState.IN_RANGE
        ebool needsDepositEncrypted = FHE.and(
            FHE.and(wasInRange, FHE.not(currentlyInRange)),
            isInRange
        );

        // Decrypt the result
        (needsDeposit, ) = FHE.getDecryptResultSafe(needsDepositEncrypted);
    }

    /**
     * @notice Calculate position's proportional share including yield
     * @param positionPrincipal The principal amount this position deposited
     * @param totalPrincipal Total principal deposited for this asset
     * @param currentTotalValue Current total value (principal + yield) for this asset
     * @return withdrawAmount The amount this position can withdraw (principal + proportional yield)
     */
    function calculatePositionWithdrawal(
        uint256 positionPrincipal,
        uint256 totalPrincipal,
        uint256 currentTotalValue
    ) internal pure returns (uint256 withdrawAmount) {
        if (totalPrincipal == 0) return 0;
        return (positionPrincipal * currentTotalValue) / totalPrincipal;
    }

    /**
     * @notice Execute pre-swap liquidity preparation (withdraw from Aave if needed). To be called by beforeSwap hook
     * @param positionKey The position identifier
     * @param currentTick Current tick
     * @return success True if preparation successful
     */
    function preparePreSwapLiquidity(
        bytes32 positionKey,
        int24 currentTick,
        address asset0,
        address asset1
    ) external returns (bool success) {
        if (!checkPreSwapLiquidityNeeds(positionKey, currentTick)) {
            return true; // Already in uniswap
        }

        PositionData storage p = positions[positionKey];

        bool success0 = true;
        bool success1 = true;

        // Token0 withdrawal - decrypt first
        (uint256 aaveAmount0, ) = FHE.getDecryptResultSafe(p.aaveAmount0);
        if (aaveAmount0 > 0) {
            uint256 currentATokenBalance0 = getATokenBalance(asset0);
            uint256 withdrawAmount0 = calculatePositionWithdrawal(
                aaveAmount0,
                totalDeposited[asset0],
                currentATokenBalance0
            );

            try Aave.withdraw(asset0, withdrawAmount0, address(this)) returns (
                uint256 withdrawnAmount0
            ) {
                totalDeposited[asset0] -= aaveAmount0; // Reduce by principal only
                (uint256 reserveAmount0, ) = FHE.getDecryptResultSafe(
                    p.reserveAmount0
                );
                reserveAmount0 += withdrawnAmount0; // Add actual withdrawn amount (principal + yield)
                aaveAmount0 = 0;

                p.aaveAmount0 = FHE.asEuint256(aaveAmount0);
                p.reserveAmount0 = FHE.asEuint256(reserveAmount0);
                emit PreSwapLiquidityPrepared(positionKey, withdrawnAmount0);
            } catch {
                p.state = PositionState.AAVE_STUCK;
                emit WithdrawalFailed(positionKey, "Token0 withdrawal failed");
                success0 = false;
            }
        }

        // Token1 withdrawal - decrypt first
        (uint256 aaveAmount1, ) = FHE.getDecryptResultSafe(p.aaveAmount1);
        if (aaveAmount1 > 0) {
            uint256 currentATokenBalance1 = getATokenBalance(asset1);
            uint256 withdrawAmount1 = calculatePositionWithdrawal(
                aaveAmount1,
                totalDeposited[asset1],
                currentATokenBalance1
            );

            try Aave.withdraw(asset1, withdrawAmount1, address(this)) returns (
                uint256 withdrawnAmount1
            ) {
                totalDeposited[asset1] -= aaveAmount1; // Reduce by principal only
                (uint256 reserveAmount1, ) = FHE.getDecryptResultSafe(
                    p.reserveAmount1
                );
                reserveAmount1 += withdrawnAmount1; // Add actual withdrawn amount (principal + yield)
                aaveAmount1 = 0;

                p.aaveAmount1 = FHE.asEuint256(aaveAmount1);
                p.reserveAmount1 = FHE.asEuint256(reserveAmount1);
                emit PreSwapLiquidityPrepared(positionKey, withdrawnAmount1);
            } catch {
                p.state = PositionState.AAVE_STUCK;
                emit WithdrawalFailed(positionKey, "Token1 withdrawal failed");
                success1 = false;
            }
        }

        if (success0 && success1) {
            p.state = PositionState.IN_RANGE;
        }

        return success0 && success1;
    }

    /**
     * @notice Execute post-swap liquidity management (deposit to Aave if position went out of range).
     * To be called by afterSwap hook
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

        // Calculate amounts to deposit based on reservePct
        uint8 reservePCT = p.reservePct == 0
            ? Constant.DEFAULT_RESERVE_PCT
            : p.reservePct;

        // Decryption initiated
        (uint256 reserveAmount0, ) = FHE.getDecryptResultSafe(p.reserveAmount0);
        (uint256 reserveAmount1, ) = FHE.getDecryptResultSafe(p.reserveAmount1);

        // Get decrypted values
        uint256 amount0ToDeposit = (reserveAmount0 * (100 - reservePCT)) / 100;
        uint256 amount1ToDeposit = (reserveAmount1 * (100 - reservePCT)) / 100;

        if (amount0ToDeposit == 0 && amount1ToDeposit == 0) {
            return true; // Nothing to deposit
        }

        bool depositSuccess = false;

        if (amount0ToDeposit > 0) {
            try Aave.deposit(asset0, amount0ToDeposit, address(this), 0) {
                if (reserveAmount0 >= amount0ToDeposit) {
                    reserveAmount0 -= amount0ToDeposit;
                } else {
                    reserveAmount0 = 0;
                }
                p.reserveAmount0 = FHE.asEuint256(reserveAmount0);

                (uint256 aaveAmount0, ) = FHE.getDecryptResultSafe(
                    p.aaveAmount0
                );
                aaveAmount0 += amount0ToDeposit;
                p.aaveAmount0 = FHE.asEuint256(aaveAmount0);
                totalDeposited[asset0] += amount0ToDeposit;
                depositSuccess = true;
                emit PostAddLiquidityDeposited(positionKey, amount0ToDeposit);
            } catch {
                emit DepositFailed(positionKey, "Token0 deposit failed");
                depositSuccess = false;
            }
        }

        if (amount1ToDeposit > 0) {
            try Aave.deposit(asset1, amount1ToDeposit, address(this), 0) {
                if (reserveAmount1 >= amount1ToDeposit) {
                    reserveAmount1 -= amount1ToDeposit;
                } else {
                    reserveAmount1 = 0;
                }
                p.reserveAmount1 = FHE.asEuint256(reserveAmount1);

                (uint256 aaveAmount1, ) = FHE.getDecryptResultSafe(
                    p.aaveAmount1
                );
                aaveAmount1 += amount1ToDeposit;
                p.aaveAmount1 = FHE.asEuint256(aaveAmount1);
                totalDeposited[asset1] += amount1ToDeposit;
                depositSuccess = true;
                emit PostWithdrawalLiquidityDeposited(
                    positionKey,
                    amount1ToDeposit
                );
            } catch {
                emit DepositFailed(positionKey, "Token1 deposit failed");
                depositSuccess = false;
            }
        }

        if (depositSuccess && (amount0ToDeposit > 0 || amount1ToDeposit > 0)) {
            p.state = PositionState.IN_AAVE;
        }

        return depositSuccess;
    }

    /**
     * @notice  This is a helper function to prepare position for withdrawal in case if the LP wants to withdraw.
     *         To be called by beforeRemoveLiquidity hook
     * @param   positionKey  The position identifier
     * @return  success  True if preparation was successful
     */
    function preparePositionForWithdrawal(
        bytes32 positionKey,
        address asset0,
        address asset1
    ) external returns (bool success) {
        PositionData storage p = positions[positionKey];
        if (!p.exists) {
            revert PositionNotFound();
        }

        if (p.state == PositionState.IN_RANGE) {
            // Nothing to do - liquidity already in Uniswap
            return true;
        }

        // Check if amounts are zero by decrypting and comparing
        (uint256 aaveAmount0, ) = FHE.getDecryptResultSafe(p.aaveAmount0);
        (uint256 aaveAmount1, ) = FHE.getDecryptResultSafe(p.aaveAmount1);

        if (aaveAmount0 == 0 && aaveAmount1 == 0) {
            // Nothing to pull back from Aave
            return true;
        }

        bool success0 = true;
        bool success1 = true;

        // Withdraw token0 if present
        if (aaveAmount0 > 0) {
            uint256 currentATokenBalance0 = getATokenBalance(asset0);
            uint256 withdrawAmount0 = calculatePositionWithdrawal(
                aaveAmount0,
                totalDeposited[asset0],
                currentATokenBalance0
            );

            try Aave.withdraw(asset0, withdrawAmount0, address(this)) returns (
                uint256 withdrawnAmount0
            ) {
                totalDeposited[asset0] -= aaveAmount0; // Reduce by principal only
                (uint256 reserveAmount0, ) = FHE.getDecryptResultSafe(
                    p.reserveAmount0
                );
                reserveAmount0 += withdrawnAmount0; // Add actual withdrawn amount (principal + yield)

                p.reserveAmount0 = FHE.asEuint256(reserveAmount0);
                p.aaveAmount0 = FHE.asEuint256(0);
                emit PreparePositionForWithdrawed(
                    positionKey,
                    withdrawnAmount0
                );
            } catch {
                p.state = PositionState.AAVE_STUCK;
                emit PreparePositionForWithdrawalFailed(
                    positionKey,
                    "Token0 withdrawal failed"
                );
                success0 = false;
            }
        }

        // Withdraw token1 if present
        if (aaveAmount1 > 0) {
            uint256 currentATokenBalance1 = getATokenBalance(asset1);
            uint256 withdrawAmount1 = calculatePositionWithdrawal(
                aaveAmount1,
                totalDeposited[asset1],
                currentATokenBalance1
            );

            try Aave.withdraw(asset1, withdrawAmount1, address(this)) returns (
                uint256 withdrawnAmount1
            ) {
                totalDeposited[asset1] -= aaveAmount1; // Reduce by principal only
                (uint256 reserveAmount1, ) = FHE.getDecryptResultSafe(
                    p.reserveAmount1
                );
                reserveAmount1 += withdrawnAmount1; // Add actual withdrawn amount (principal + yield)

                p.reserveAmount1 = FHE.asEuint256(reserveAmount1);
                p.aaveAmount1 = FHE.asEuint256(0);
                emit PreparePositionForWithdrawed(
                    positionKey,
                    withdrawnAmount1
                );
            } catch {
                p.state = PositionState.AAVE_STUCK;
                emit PreparePositionForWithdrawalFailed(
                    positionKey,
                    "Token1 withdrawal failed"
                );
                success1 = false;
            }
        }

        if (success0 && success1) {
            p.state = PositionState.IN_RANGE;
        }

        return success0 && success1;
    }

    /**
     * @notice Handle post-withdrawal rebalance (called after user withdraws liquidity).
     * To be called by afterRemoveLiquidity hook
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

        // If all liquidity is removed, delete the position
        if (liqAmount0 == 0 && liqAmount1 == 0) {
            delete positions[positionKey];
            return true;
        }

        p.reserveAmount0 = FHE.asEuint256(liqAmount0);
        p.reserveAmount1 = FHE.asEuint256(liqAmount1);
        p.aaveAmount0 = FHE.asEuint256(0);
        p.aaveAmount1 = FHE.asEuint256(0);
        p.totalLiquidity = FHE.asEuint256(liqAmount0 + liqAmount1);

        bool outOfRange = (currentTick < p.tickLower ||
            currentTick > p.tickUpper);
        if (outOfRange && p.state == PositionState.IN_RANGE) {
            // Decryption initiated
            (uint256 reserveAmount0, ) = FHE.getDecryptResultSafe(
                p.reserveAmount0
            );
            (uint256 reserveAmount1, ) = FHE.getDecryptResultSafe(
                p.reserveAmount1
            );

            // Position is out of range and liquidity is in Uniswap - deposit to Aave
            uint256 amount0ToDeposit = (reserveAmount0 * 80) / 100;
            uint256 amount1ToDeposit = (reserveAmount1 * 80) / 100;

            if (amount0ToDeposit == 0 && amount1ToDeposit == 0) {
                return true; // Nothing to deposit is there
            }

            bool depositSuccess = false;

            if (amount0ToDeposit > 0) {
                try Aave.deposit(asset0, amount0ToDeposit, address(this), 0) {
                    if (reserveAmount0 >= amount0ToDeposit) {
                        reserveAmount0 -= amount0ToDeposit;
                    } else {
                        reserveAmount0 = 0;
                    }
                    p.reserveAmount0 = FHE.asEuint256(reserveAmount0);

                    (uint256 aaveAmount0, ) = FHE.getDecryptResultSafe(
                        p.aaveAmount0
                    );
                    aaveAmount0 += amount0ToDeposit;
                    p.aaveAmount0 = FHE.asEuint256(aaveAmount0);
                    totalDeposited[asset0] += amount0ToDeposit;
                    depositSuccess = true;
                    emit PostAddLiquidityDeposited(
                        positionKey,
                        amount0ToDeposit
                    );
                } catch {
                    emit DepositFailed(positionKey, "Token0 deposit failed");
                    depositSuccess = false;
                }
            }

            if (amount1ToDeposit > 0) {
                try Aave.deposit(asset1, amount1ToDeposit, address(this), 0) {
                    reserveAmount1 -= amount1ToDeposit;
                    p.reserveAmount1 = FHE.asEuint256(reserveAmount1);

                    (uint256 aaveAmount1, ) = FHE.getDecryptResultSafe(
                        p.aaveAmount1
                    );
                    aaveAmount1 += amount1ToDeposit;
                    p.aaveAmount1 = FHE.asEuint256(aaveAmount1);
                    totalDeposited[asset1] += amount1ToDeposit;

                    depositSuccess = true;
                    emit PostWithdrawalLiquidityDeposited(
                        positionKey,
                        amount1ToDeposit
                    );
                } catch {
                    emit DepositFailed(positionKey, "Token1 deposit failed");
                    depositSuccess = false;
                }
            }

            if (
                depositSuccess && (amount0ToDeposit > 0 || amount1ToDeposit > 0)
            ) {
                p.state = PositionState.IN_AAVE;
            }

            return depositSuccess;
        }
        // In-range case or not eligible for Aave deposit: nothing to do
        return true;
    }

    /**
     * @notice Process liquidity addition (called whenever user adds liquidity to position).
     * To be called by afterAddLiquidity hook
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

        bool outOfRange = (currentTick < p.tickLower ||
            currentTick > p.tickUpper);

        if (outOfRange) {
            // Position is out of range and liquidity is in Uniswap - deposit to Aave
            p.state = PositionState.IN_RANGE;
            uint256 amount0ToDeposit = (liqAmount0 *
                (100 - Constant.DEFAULT_RESERVE_PCT)) / 100;
            uint256 amount1ToDeposit = (liqAmount1 *
                (100 - Constant.DEFAULT_RESERVE_PCT)) / 100;

            if (amount0ToDeposit == 0 && amount1ToDeposit == 0) {
                return true; // Nothing to deposit is there
            }

            bool depositSuccess = false;

            if (amount0ToDeposit > 0) {
                try Aave.deposit(asset0, amount0ToDeposit, address(this), 0) {
                    (uint256 reserveAmount0, ) = FHE.getDecryptResultSafe(
                        p.reserveAmount0
                    );
                    if (reserveAmount0 >= amount0ToDeposit) {
                        reserveAmount0 -= amount0ToDeposit;
                    } else {
                        reserveAmount0 = 0;
                    }
                    p.reserveAmount0 = FHE.asEuint256(reserveAmount0);

                    (uint256 aaveAmount0, ) = FHE.getDecryptResultSafe(
                        p.aaveAmount0
                    );
                    aaveAmount0 += amount0ToDeposit;
                    p.aaveAmount0 = FHE.asEuint256(aaveAmount0);
                    totalDeposited[asset0] += amount0ToDeposit;
                    depositSuccess = true;
                    emit PostAddLiquidityDeposited(
                        positionKey,
                        amount0ToDeposit
                    );
                } catch {
                    emit DepositFailed(positionKey, "Token0 deposit failed");
                    depositSuccess = false;
                }
            }

            if (amount1ToDeposit > 0) {
                try Aave.deposit(asset1, amount1ToDeposit, address(this), 0) {
                    (uint256 reserveAmount1, ) = FHE.getDecryptResultSafe(
                        p.reserveAmount1
                    );
                    reserveAmount1 -= amount1ToDeposit;
                    p.reserveAmount1 = FHE.asEuint256(reserveAmount1);

                    (uint256 aaveAmount1, ) = FHE.getDecryptResultSafe(
                        p.aaveAmount1
                    );
                    aaveAmount1 += amount1ToDeposit;
                    p.aaveAmount1 = FHE.asEuint256(aaveAmount1);
                    totalDeposited[asset1] += amount1ToDeposit;
                    depositSuccess = true;
                    emit PostWithdrawalLiquidityDeposited(
                        positionKey,
                        amount1ToDeposit
                    );
                } catch {
                    emit DepositFailed(positionKey, "Token1 deposit failed");
                    depositSuccess = false;
                }
            }

            if (
                depositSuccess && (amount0ToDeposit > 0 || amount1ToDeposit > 0)
            ) {
                p.state = PositionState.IN_AAVE;
            }

            return depositSuccess;
        } else {
            p.state = PositionState.IN_RANGE;
            return true;
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

        // Decrypt amounts separately to avoid arithmetic on encrypted values
        (uint256 reserveAmount0, ) = FHE.getDecryptResultSafe(p.reserveAmount0);
        (uint256 aaveAmount0, ) = FHE.getDecryptResultSafe(p.aaveAmount0);
        (uint256 reserveAmount1, ) = FHE.getDecryptResultSafe(p.reserveAmount1);
        (uint256 aaveAmount1, ) = FHE.getDecryptResultSafe(p.aaveAmount1);

        uint256 Amount0 = reserveAmount0 + aaveAmount0;
        uint256 Amount1 = reserveAmount1 + aaveAmount1;

        return (Amount0, Amount1, p.state);
    }

    // Position management functions
    function upsertPosition(
        bytes32 positionKey,
        PositionData calldata data
    ) external override {
        positions[positionKey] = data;
        emit PositionUpserted(positionKey);
    }

    function getPosition(
        bytes32 positionKey
    ) external view returns (PositionData memory) {
        return positions[positionKey];
    }

    function isPositionExists(
        bytes32 positionKey
    ) external view returns (bool) {
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
}
