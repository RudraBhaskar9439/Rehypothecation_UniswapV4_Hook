// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {euint256, FHE, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

interface ILiquidityOrchestrator {
    // Enums
    enum PositionState {
        IN_RANGE,
        IN_AAVE,
        AAVE_STUCK
    }

    // Structs
    struct PositionData {
        bool exists;
        int24 tickLower;
        int24 tickUpper;
        euint256 reserveAmount0; //encrypted
        euint256 reserveAmount1; //encrypted
        euint256 aaveAmount0; //encrypted
        euint256 aaveAmount1; //encrypted
        euint256 totalLiquidity;
        uint8 reservePct;
        PositionState state;
    }

    // Events
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

    // Errors
    error PositionNotFound();
    error NotOwner();

    // View Functions
    function owner() external view returns (address);
    function stuckPositions(uint256 index) external view returns (bytes32);

    /**
     * @notice Check if position needs liquidity withdrawal BEFORE swap (current range has liquidity in Aave)
     * @param positionKey The position identifier
     * @param currentTick Current tick before swap
     * @return needsWithdrawal True if position is currently active but liquidity is in Aave
     */
    function checkPreSwapLiquidityNeeds(bytes32 positionKey, int24 currentTick)
        external
        returns (bool needsWithdrawal);

    /**
     * @notice Check if position needs liquidity deposit AFTER swap (tick leaving range)
     * @param positionKey The position identifier
     * @param oldTick Tick before swap
     * @param newTick Tick after swap
     * @return needsDeposit True if position became inactive and should go to Aave
     */
    function checkPostSwapLiquidityNeeds(bytes32 positionKey, int24 oldTick, int24 newTick)
        external
        returns (bool needsDeposit);

    /**
     * @notice Get available liquidity for a position (Uniswap + Aave)
     * @param positionKey The position identifier
     * @return amount0 Total amount of token0 available
     * @return amount1 Total amount of token1 available
     * @return state Current position state
     */
    function getAvailableLiquidity(bytes32 positionKey)
        external
        view
        returns (uint256 amount0, uint256 amount1, PositionState state);

    /**
     * @notice Get position data
     * @param positionKey The position identifier
     * @return PositionData struct containing all position information
     */
    function getPosition(bytes32 positionKey) external view returns (PositionData memory);

    /**
     * @notice Check if position exists
     * @param positionKey The position identifier
     * @return exists True if position exists
     */
    function isPositionExists(bytes32 positionKey) external view returns (bool exists);

    // State-Changing Functions

    /**
     * @notice Execute pre-swap liquidity preparation (withdraw from Aave if needed)
     * @dev To be called by beforeSwap hook
     * @param positionKey The position identifier
     * @param currentTick Current tick
     * @param asset0 Address of token0
     * @param asset1 Address of token1
     * @return success True if preparation successful
     */
    function preparePreSwapLiquidity(bytes32 positionKey, int24 currentTick, address asset0, address asset1)
        external
        returns (bool success);

    /**
     * @notice Execute post-swap liquidity management (deposit to Aave if position went out of range)
     * @dev To be called by afterSwap hook
     * @param positionKey The position identifier
     * @param oldTick Tick before swap
     * @param newTick Tick after swap
     * @param asset0 Address of token0
     * @param asset1 Address of token1
     * @return success True if post-swap management successful
     */
    function executePostSwapManagement(
        bytes32 positionKey,
        int24 oldTick,
        int24 newTick,
        address asset0,
        address asset1
    ) external returns (bool success);

    /**
     * @notice Prepare position for withdrawal in case LP wants to withdraw
     * @dev To be called by beforeRemoveLiquidity hook
     * @param positionKey The position identifier
     * @param asset0 Address of token0
     * @param asset1 Address of token1
     * @return success True if preparation was successful
     */
    function preparePositionForWithdrawal(bytes32 positionKey, address asset0, address asset1)
        external
        returns (bool success);

    /**
     * @notice Handle post-withdrawal rebalance (called after user withdraws liquidity)
     * @dev To be called by afterRemoveLiquidity hook
     * @param positionKey The position identifier
     * @param currentTick Current tick after withdrawal
     * @param liqAmount0 Amount of token0 available after user withdrawal
     * @param liqAmount1 Amount of token1 available after user withdrawal
     * @param asset0 Address of token0
     * @param asset1 Address of token1
     * @return success True if rebalance successful
     */
    function handlePostWithdrawalRebalance(
        bytes32 positionKey,
        int24 currentTick,
        uint256 liqAmount0,
        uint256 liqAmount1,
        address asset0,
        address asset1
    ) external returns (bool success);

    /**
     * @notice Process liquidity addition (called whenever user adds liquidity to position)
     * @dev To be called by afterAddLiquidity hook
     * @param positionKey The position identifier
     * @param currentTick The current tick of the position
     * @param liqAmount0 The amount of token0 being added
     * @param liqAmount1 The amount of token1 being added
     * @param asset0 Address of token0
     * @param asset1 Address of token1
     * @return success True if the liquidity addition was processed successfully
     */
    function processLiquidityAdditionDeposit(
        bytes32 positionKey,
        int24 currentTick,
        uint256 liqAmount0,
        uint256 liqAmount1,
        address asset0,
        address asset1
    ) external returns (bool success);

    /**
     * @notice Create or update a position
     * @param positionKey The position identifier
     * @param data Position data to store
     */
    function upsertPosition(bytes32 positionKey, PositionData calldata data) external;

    /**
     * @notice Pause a position (owner only)
     * @param positionKey The position identifier
     */
    function pausePosition(bytes32 positionKey) external;

    /**
     * @notice Resume a position (owner only)
     * @param positionKey The position identifier
     */
    function resumePosition(bytes32 positionKey) external;
}
