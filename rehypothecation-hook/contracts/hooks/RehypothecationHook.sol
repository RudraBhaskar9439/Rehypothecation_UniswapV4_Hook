// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {IRehypothecationHook} from "../interfaces/IRehypothecationHook.sol";
import {IAave} from "../interfaces/IAave.sol";
import {Constant} from "../utils/Constant.sol";
import {LiquidityOrchestrator} from "../LiquidityOrchestrator.sol";

abstract contract RehypothecationHook is IRehypothecationHook {
    // State Vairable
    IAave public immutable aavePool;
    LiquidityOrchestrator public immutable liquidityOrchestrator;
    mapping(uint256 => PositionData) public positions;
    mapping(uint256 => uint256) public emergencyWithdrawlTimestamps;

    // Owner
    address public owner;

    // Events
    event HookInitialized(address indexed aavePool);
    event ReservePercentageUpdated(uint256 indexed tokenId, uint256 oldPercentage, uint256 newPercentage);
    event EmergencyWithdrawalTriggered(
        address indexed caller, uint256 indexed tokenId, address asset, uint256 amount, uint256 timestamp
    );

    /**
     * @dev This constructor:Takes the Aave Pool contract as input.
     * Stores it in the contract state (aavePool).
     * Records the deployer as the owner.
     * Emits an event to signal that the hook/contract was initialized with a specific Aave pool.
     */
    constructor(IAave _aavePool, LiquidityOrchestrator _liquidityOrchestrator) {
        aavePool = _aavePool;
        liquidityOrchestrator = _liquidityOrchestrator;
        owner = msg.sender;

        emit HookInitialized(address(_aavePool));
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only Owner");
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    /**
     * @dev Hook called before a swap to ensure sufficient liquidity
     * @dev check if there is liquidity(range deposited in aave
     *      if yes => withdraw from aave
     *      if no => proceed further
     * @dev if aave withdraw failed => swap conducts from the rest 20% available liquidity
     * @dev also a array is maintained to keep track of struck positions and a counter to keep a count of struck positions and if it exceeds a certain threshold => emergency withdrawl from aave
     */

    function beforeSwap(bytes32 positionKey, int24 currentTick)
        external
        returns (bool success, uint256 availableAmount0, uint256 availableAmount1)
    {
        // Check if liquidity needs to be withdrawn before swap
        bool needsWithdrawal = checkPreSwapLiquidityNeeds(positionKey, currentTick);

        if (!needsWithdrawal) {
            // Position do not need withdrawl => just we can use reserves
            PositionData storage p = positions[positionKey];
            return (true, p.reserveAmount0, p.reserveAmount1);
        }

        // Try to withdraw funds from aave
        try yieldManager.withdrawFromAave(positionKey, p.aaveAmount0, p.aaveAmount1) returns (
            uint256 withdrawn0, uint256 withdrawn1
        ) {
            // Update the state of positionData  => check in ILiquidityOrchestrator
            p.state = PositionState.IN_RANGE; // Liquidity active in Uniswap pool
            p.reserveAmount0 += withdrawn0; // Token0 amount deposited in Aave
            p.reserveAmount1 += withdrawn1; // Token1 amount deposited in Aave
            p.amount0 = 0; // Token0 amount deposited in Aave
            p.amount1 = 0; // Token1 amount deposited in Aave

            emit PreSwapLiquidityPrepared(positionKey, true, withdrawn0, withdrawn1);

            return (true, p.reserveAmount0, p.reserveAmount1);
        } catch {
            // Withdrawal failed => swap conducts from the rest 20% available liquidity
            //  => It is handled by fallback strategy
            (bool ok, uint256 reserve0, uint256 reserve1) = _handleWithdrawalFailure(positionKey);

            // atleast 20% liquidity should always be available in reserve.
            return (ok, reserve0, reserve1);
        }
    }

    /**
     * @notice Handles logic after a swap
     * @param positionKey => The position identifier
     * @param oldTick => Tick before Swap
     * @param newTick => Tick after Swap
     */
    function afterSwap(bytes32 positionKey, int24 oldTick, int24 newTick) external returns (bool success) {
        PositionData storage p = positions[positionKey];
        if (!p.exists || p.totalLiquidity < Constant.MIN_POSITION_SIZE) {
            return false;
        }

        bool oldInRange = (oldTick >= p.tickLower && oldTick <= p.tickUpper); // Initializing the old range
        bool newInRange = (newTick >= p.tickLower && newTick <= p.tickUpper); // Initializing the new range

        // If the tick remains same => exit
        if (oldInRange == newInRange) {
            return true;
        }

        // Else send 80% liquidity from oldTick to Aave
        uint256 amount0ToDeposit = (p.reserveAmount0 * 80) / 100;
        uint256 amount1ToDeposit = (p.reserveAmount1 * 80) / 100;

        if (amount0ToDeposit == 0 && amount1ToDeposit == 0) {
            return true; // Nothing to deposit is there
        }

        try yieldManager.depositToAave(positionKey, amount0ToDeposit, amount1ToDeposit) {
            p.reserveAmount0 -= amount0ToDeposit;
            p.reserveAmount1 -= amount1ToDeposit;
            p.aaveAmount0 += amount0ToDeposit;
            p.aaveAmount1 += amount1ToDeposit;
            p.state = PositionState.IN_AAVE;

            return true;
        } catch Error(string memory reason) {
            emit DepositFailed(positionKey, reason);
            return false;
        }
    }
}
