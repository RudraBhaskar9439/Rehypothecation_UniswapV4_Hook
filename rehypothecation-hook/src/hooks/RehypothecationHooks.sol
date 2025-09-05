// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {LiquidityOrchestrator} from "../LiquidityOrchestrator.sol";
import {IAave} from "../interfaces/IAave.sol";

import {Constant} from "../utils/Constant.sol";
import {LiquidityOrchestrator} from "../LiquidityOrchestrator.sol";

import {ILiquidityOrchestrator} from "../interfaces/ILiquidityOrchestrator.sol";

contract RehypothecationHooks is BaseHook, ILiquidityOrchestrator {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    // State Variable
    IAave public immutable aavePool;
    LiquidityOrchestrator public immutable liquidityOrchestrator;
    mapping(bytes32 => uint256) public emergencyWithdrawlTimestamps;

    // Owner
    address public owner;

    // Events
    event HookInitialized(address indexed poolManager, address indexed aavePool);
    event ReservePercentageUpdated(bytes32 indexed positionKey, uint256 oldPercentage, uint256 newPercentage);
    event EmergencyWithdrawalTriggered(
        address indexed caller, bytes32 indexed positionKey, address asset, uint256 amount, uint256 timestamp
    );

    modifier onlyOwner() {
        require(msg.sender == owner, " Only Owner");
        _;
    }

    /**
     * @dev Constructor initializes the hook with Uniswap PoolManager and Aave Pool
     * @param _poolManager The Uniswap v4 PoolManager contract
     * @param _aavePool The Aave Pool contract for yield generation
     * @param _liquidityOrchestrator The LiquidityOrchestrator contract
     */
    constructor(IPoolManager _poolManager, IAave _aavePool, LiquidityOrchestrator _liquidityOrchestrator)
        BaseHook(_poolManager)
    {
        aavePool = _aavePool;
        liquidityOrchestrator = _liquidityOrchestrator;
        owner = msg.sender;

        emit HookInitialized(address(_poolManager), address(_aavePool));
    }

    /**
     * @dev Returns the hook permissions required for this contract
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
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
     * @notice  Will perform liquidity management after liquidity is added to a pool, either creating a new position or updating an existing one.
     * @param   sender  The address adding liquidity
     * @param   key  The pool key
     * @param   params  The parameters for modifying liquidity
     * @param   delta  The change in balance
     * @param   feesAccrued  The fees accrued
     * @param   hookData  Additional data for the hook
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override {
        // Generate position key from pool key and sender
        bytes32 positionKey = _generatePositionKey(key, params.tickLower, params.tickUpper);
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        uint256 amount0In = delta.amount0() < 0 ? uint256(int256(-delta.amount0())) : 0;
        uint256 amount1In = delta.amount1() < 0 ? uint256(int256(-delta.amount1())) : 0;

        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        if (liquidityOrchestrator.isPositionExists(positionKey)) {
            bool success = liquidityOrchestrator.processLiquidityAdditionDeposit(
                positionKey, currentTick, amount0In, amount1In, asset0, asset1
            );

            if (!success) {
                revert LiquidityAdditionFailed();
            }

            return (this.afterAddLiquidity.selector, delta);
        }
        uint256 totalLiquidity = amount0In + amount1In;

        PositionData memory data = PositionData({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            totalLiquidity: totalLiquidity,
            reservePct: Constant.DEFAULT_RESERVE_PCT,
            reserveAmount0: amount0In,
            reserveAmount1: amount1In,
            aaveAmount0: 0,
            aaveAmount1: 0,
            exists: true,
            state: PositionState.IN_RANGE
        });

        // This will create a new position.
        liquidityOrchestrator.upsertPosition(positionKey, data);

        bool success = liquidityOrchestrator.processLiquidityAdditionDeposit(
            positionKey, currentTick, amount0In, amount1In, asset0, asset1
        );

        if (!success) {
            revert LiquidityAdditionFailed();
        }

        return (this.afterAddLiquidity.selector, delta);
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4 selector) {
        // Generate position key from pool key and sender
        bytes32 positionKey = _generatePositionKey(key, params.tickLower, params.tickUpper);
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        bool success = liquidityOrchestrator.preparePositionForWithdrawal(positionKey, asset0, asset1);

        if (!success) {
            revert LiquidityRemovalFailed();
        }

        return (this.beforeRemoveLiquidity.selector);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feeAccured,
        bytes calldata hookData
    ) internal override returns (bytes4 selector) {
        // Generate position key from pool key and sender
        bytes32 positionKey = _generatePositionKey(key, params.tickLower, params.tickUpper);
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // Calculate the amount to be withdrawn
        // WHen liq is removed , delta is +ve (tokens returned to user)
        uint256 liqAmount0 = delta.amount0 > 0 ? uint256(int256(delta.amount0())) : 0;
        uint256 liqAmount1 = delta.amount1 > 0 ? uint256(int256(delta.amount1())) : 0;

        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        // Calling ther liqorchestrator contract to handle post-withdrawal rebalance
        bool success = liquidityOrchestrator.handlePostWithdrawalRebalance(
            positionKey, currentTick, liqAmount0, liqAmount1, asset0, asset1
        );

        if (!success) {
            revert PostWithdrawalRebalanceFailed();
        }

        return this.afterRemoveLiquidity.selector;
    }

    /**
     * @dev Hook called before a swap to ensure sufficient liquidity.
     * @param key => The pool key
     * @param params => Swap parameters
     * @param hookData => Additional data passed to the hook
     * @return selector => Function selecrotor to continue execution
     * @return beforeSwapDelta => The delta to apply befoe swap
     * @return fee => The fee to apply
     */
    function _beforeSwap(
        address sender, // Address calling the swap
        PoolKey calldata key, // PoolKey which identifies the specific pool
        SwapParams calldata params,
        bytes calldata hookData // Extra data passed to the hook by the swpa caller
    ) internal override returns (bytes4 selector, BeforeSwapDelta beforeSwapDelta, uint24 fee) {
        // Fetching current tick from pool manager
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        (int24 upperTick, int24 lowerTick) = abi.decode(hookData, (int24, int24));

        bytes32 positionKey = _generatePositionKey(key, lowerTick, upperTick);

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Call LiquidityOrchestrator to prepare pre-swap liquidity
        bool success = liquidityOrchestrator.preparePreSwapLiquidity(positionKey, currentTick, token0, token1);

        if (!success) {
            revert PreSwapLiquidityPreparationFailed();
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4 selector, int128 fee) {
        // Getting the old tick from LiquidityOrchestrator lastActiveTick
        int24 oldTick = liquidityOrchestrator.LastActiveTick(positionKey);

        (, int24 newTick,,) = poolManager.getSlot0(key.toId());

        (int24 upperTick, int24 lowerTick) = abi.decode(hookData, (int24, int24));

        bytes32 positionKey = _generatePositionKey(key, lowerTick, upperTick);
        PositionData memory p = liquidityOrchestrator.getPosition(positionKey);

        if (params.zeroForOne) {
            // token0 -> token1
            uint256 amount0In = delta.amount0 < 0 ? uint256(int256(-delta.amount0())) : 0;
            p.reserveAmount0 += amount0In;
            uint256 amount1Out = delta.amount1 > 0 ? uint256(int256(delta.amount1())) : 0;
            p.reserveAmount1 -= amount1Out;
        } else {
            // token1 -> token0
            uint256 amount1In = delta.amount1 < 0 ? uint256(int256(-delta.amount1())) : 0;
            p.reserveAmount1 += amount1In;
            uint256 amount0Out = delta.amount0 > 0 ? uint256(int256(delta.amount0())) : 0;
            p.reserveAmount0 -= amount0Out;
        }

        bool success = liquidityOrchestrator.executePostSwapManagement(positionKey, oldTick, newTick);

        return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @dev Generates a unique position key based on the pool key and owner address
     * @param key The pool key
     * @param owner The address of the position owner
     * @return A unique bytes32 position key
     */
    function _generatePositionKey(PoolKey calldata key, int24 lowerTick, int24 upperTick)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(key.toId(), lowerTick, upperTick));
    }
}
