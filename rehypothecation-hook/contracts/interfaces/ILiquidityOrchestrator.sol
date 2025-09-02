// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

interface ILiquidityOrchestrator {
    enum PositionState {
        IN_RANGE,
        OUT_OF_RANGE,
        AAVE_STUCK
    }

    struct PositionData {
        address owner;
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint256 totalLiquidity;
        uint256 reserveAmount0;
        uint256 reserveAmount1;
        uint256 aaveAmount0;
        uint256 aaveAmount1;
        uint8 reservePct; 
        PositionState state;
        bool exists;
    }

    struct RebalancePlan {
        uint256 withdrawAmount0;
        uint256 withdrawAmount1;
        uint256 depositToAave0;
        uint256 depositToAave1;
        uint256 keepAsReserve0;
        uint256 keepAsReserve1;
    }

    /**
     * @notice  Should the hook trigger rebalancing for a given positionKey?
     * @param   positionKey  The key of the position to check. calculated using the position's parameters in the main contract: keccak256(owner,poolId,tickLower,tickUpper)
     * @param   currentTick  The current tick of the position.
     * @return  bool  .
     */
    function shouldRebalancePosition(bytes32 positionKey, int24 currentTick) external view returns (bool);

    
    /**
     * @notice  Gas optimized function to update multiple positions.
     * @param   positionKeys  The keys of the positions to check.
     * @param   currentTick  The current tick of the positions.
     * @return  bool[]  An array indicating whether each position should be rebalanced.
     */
    function shouldRebalancePositions(bytes32[] calldata positionKeys, int24 currentTick) external view returns (bool[] memory);

    /**
     * @notice  Calculates the optimal split of withdrawn assets between Aave and reserve for a given position.
     * @param   positionKey  The key of the position to check.
     * @param   withdrawAmount0  The amount of token0 to withdraw.
     * @param   withdrawAmount1  The amount of token1 to withdraw.
     * @return  plan  The rebalance plan.
     */
    function calculateOptimalSplit(bytes32 positionKey, uint256 withdrawAmount0, uint256 withdrawAmount1)
        external
        view
        returns (RebalancePlan memory plan);

    /**
     * @notice  Handle a rebalance failure.
     * @param   positionKey  The key of the position to check.
     * @param   expectedAmount0  The expected amount of token0.
     * @param   expectedAmount1  The expected amount of token1.
     * @return  shouldRetry  Whether the rebalance should be retried.
     * @return  allowPartialSwap  Whether partial swaps are allowed.
     * @return  maxWaitTime  The maximum wait time before retrying.
     */
    function handleRebalanceFail(bytes32 positionKey, uint256 expectedAmount0, uint256 expectedAmount1)
        external
        returns (bool shouldRetry, bool allowPartialSwap, uint256 maxWaitTime);

    /**
     * @notice  Validate the accounting balance for a given position by comparing on-chain reserves with expected values.
     * @param   positionKey  The key of the position to validate.
     * @return  valid  Whether the accounting is valid.
     * @return  discrepancy  The amount of discrepancy found.
     */
    function validateAccountingBalance(bytes32 positionKey) external view returns (bool valid, uint256 discrepancy);

    /**
     * @notice  Register or update a position (called by hook on initialize / liquidity changes)
     * @param   positionKey  The key of the position to update.
     * @param   data  The data to update the position with.
     */
    function upsertPosition(bytes32 positionKey, PositionData calldata data) external;

    /**
     * @notice  Get the current position data.
     * @param   positionKey  The key of the position to retrieve.
     * @return  PositionData  The current position data.
     */
    function getPosition(bytes32 positionKey) external view returns (PositionData memory);

    /**
     * @notice  Pause a position.
     * @param   positionKey  The key of the position to pause.
     */
    function pausePosition(bytes32 positionKey) external;

    /**
     * @notice  Resume a paused position.
     * @param   positionKey  The key of the position to resume.
     */
    function resumePosition(bytes32 positionKey) external;
}
