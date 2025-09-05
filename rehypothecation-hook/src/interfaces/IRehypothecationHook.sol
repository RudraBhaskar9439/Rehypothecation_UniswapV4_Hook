// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRehypothecationHook {
    /**
     * @dev Emitted when a position state changes
     */
    event PositionStateChanged(
        address indexed owner,
        uint256 indexed tokenId,
        PositionState oldState,
        PositionState newState,
        uint256 timestamp
    );

    /**
     * @dev Emitted when liquidity is deposited to Aave
     */
    event LiquidityDepositedToAave(
        address indexed owner, uint256 indexed tokenId, address asset, uint256 amount, uint256 timestamp
    );

    /**
     * @dev Emitted when liquidity is withdrawn from Aave
     */
    event LiquidityWithdrawnFromAave(
        address indexed owner, uint256 indexed tokenId, address asset, uint256 amount, uint256 timestamp
    );

    /**
     * @dev Emitted when emergency withdrawl is triggered
     */
    event EmergencyWithdrawalTriggered(
        address indexed owner, uint256 indexed tokenId, address asset, uint256 amount, uint256 timestamp
    );

    /**
     * @dev Enum representing the state of an LP position
     */
    enum PositionState {
        IN_RANGE, // Position id currently active in Uniswap
        OUT_OF_RANGE, // Position is idle and deposited in Aave
        AAVE_STUCK // Position is stuck in Aave due to liquidity issues

    }

    /**
     * @dev Struct representing LP position data
     */
    struct PositionData {
        PositionState state;
        uint256 reservePercentage; // Percentage kept as reserve (e.g., 20%)
        uint256 aaveAllocation; // Amount currently in Aave
        uint256 uniswapAllocation; // Amount currently in Uniswap
        uint256 lastStateChange; // Timestamp of last state change
        bool isActive; // Whether position is currently active
    }

    /**
     * @dev Returns the position data for a given token ID
     */
    function getPositionData(uint256 tokenId) external view returns (PositionData memory);

    /**
     * @dev Returns the current state of a position
     */
    function getPositionState(uint256 tokenId) external view returns (PositionState);

    /**
     * @dev Manually triggers a position state update (for testing/admin)
     */
    function updatePositionState(uint256 tokenId) external;

    /**
     * @dev Sets the reserve percentage for a position
     */
    function setReservePercentage(uint256 tokenId, uint256 percentage) external;

    /**
     * @dev Emergency function to force withdraw from Aave
     */
    function emergencyWithdrawFromAave(uint256 tokenId) external;

    /**
     * @dev Returns the total value locked in the lock
     */
    function getTotalValueLocked() external view returns (uint256);
}
