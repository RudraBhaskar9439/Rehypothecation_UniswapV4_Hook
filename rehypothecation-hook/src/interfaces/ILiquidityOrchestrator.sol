// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ILiquidityOrchestrator
 * @notice Interface for managing LP position states and coordinating liquidity between Uniswap and yield protocols
 */
interface ILiquidityOrchestrator {
    // Enums
    enum PositionState {
        IN_RANGE, // Liquidity active in Uniswap pool
        IN_AAVE, // Liquidity deposited in Aave for yield
        AAVE_STUCK // Liquidity stuck in Aave (withdrawal failed)

    }

    // Structs
    struct PositionData {
        address owner; // Owner of the LP position
        int24 tickLower; // Lower tick of the position range
        int24 tickUpper; // Upper tick of the position range
        uint256 totalLiquidity; // Total liquidity amount
        uint8 reservePct; // Percentage to keep as reserve (0-100)
        uint256 reserveAmount0; // Token0 amount kept in Uniswap as reserve
        uint256 reserveAmount1; // Token1 amount kept in Uniswap as reserve
        uint256 aaveAmount0; // Token0 amount deposited in Aave
        uint256 aaveAmount1; // Token1 amount deposited in Aave
        bool exists; // Whether position exists in mapping
        PositionState state; // Current state of position
    }

    // Events
    event PositionUpserted(bytes32 indexed positionKey, address indexed owner);
    event PositionPaused(bytes32 indexed positionKey);
    event PositionResumed(bytes32 indexed positionKey);
    event StuckPositionRecovered(bytes32 indexed positionKey);
    event PreSwapLiquidityPrepared(bytes32 indexed positionKey, bool wasInAave, uint256 amount0, uint256 amount1);
    event PostSwapLiquidityDeposited(bytes32 indexed positionKey, uint256 amount0, uint256 amount1);
    event DepositFailed(bytes32 indexed positionKey, string reason);
    event WithdrawalFailed(bytes32 indexed positionKey, string reason);

    function checkPreSwapLiquidityNeeds(bytes32 positionKey, int24 currentTick)
        external
        view
        returns (bool needsWithdrawal);

    function checkPostSwapLiquidityNeeds(bytes32 positionKey, int24 oldTick, int24 newTick)
        external
        view
        returns (bool needsDeposit);

    function preparePreSwapLiquidity(bytes32 positionKey, int24 currentTick)
        external
        returns (bool success, uint256 availableAmount0, uint256 availableAmount1);

    function executePostSwapManagement(bytes32 positionKey, int24 oldTick, int24 newTick)
        external
        returns (bool success);

    function upsertPosition(bytes32 positionKey, PositionData calldata data) external;

    function getPosition(bytes32 positionKey) external view returns (PositionData memory);

    /**
     * @notice Get available liquidity for a position (Uniswap + Aave)
     * @param positionKey The position identifier
     * @return amount0 Total token0 amount available
     * @return amount1 Total token1 amount available
     * @return state Current position state
     */
    function getAvailableLiquidity(bytes32 positionKey)
        external
        view
        returns (uint256 amount0, uint256 amount1, PositionState state);

    /**
     * @notice Manually pause a position (emergency stop)
     * @param positionKey The position identifier
     */
    function pausePosition(bytes32 positionKey) external;

    /**
     * @notice Resume a paused position
     * @param positionKey The position identifier
     */
    function resumePosition(bytes32 positionKey) external;

    /**
     * @notice Retry all stuck positions to recover from Aave
     */
    function retryStuckPositions() external;
}
