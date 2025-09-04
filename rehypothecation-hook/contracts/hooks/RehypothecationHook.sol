// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Remapping karne ka maan nhi koi krdo 
import {BaseHook} from "../../lib/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "../../lib/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "../../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../../lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../lib/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "../../lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "../../lib/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "../../lib/v4-core/src/types/Currency.sol";
import {SafeCast} from "../../lib/v4-core/src/libraries/SafeCast.sol";

import {LiquidityOrchestrator} from "../LiquidityOrchestrator.sol";
import {IRehypothecationHook} from "../interfaces/IRehypothecationHook.sol";
import {IAave} from "../interfaces/IAave.sol";

import {Constant} from "../utils/Constant.sol";
import {LiquidityOrchestrator} from "../LiquidityOrchestrator.sol";

import {ILiquidityOrchestrator} from "../interfaces/ILiquidityOrchestrator.sol";



contract RehypothecationHooks is BaseHook, IRehypothecationHook {
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
        address indexed caller,
        bytes32 indexed positionKey,
        address asset,
        uint256 amount,
        uint256 timestamp
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

     constructor(
        IPoolManager _poolManager,
        IAave _aavePool,
        LiquidityOrchestrator _liquidityOrchestrator
     ) BaseHook(_poolManager) {
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
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
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
     * @dev Hook called before a swap to ensure sufficient liquidity.
     * @param key => The pool key
     * @param params => Swap parameters
     * @param hookData => Additional data passed to the hook
     * @return selector => Function selecrotor to continue execution
     * @return beforeSwapDelta => The delta to apply befoe swap
     * @return fee => The fee to apply
     */

     function beforeSwap(
        address sender, // Address calling the swap
        PoolKey calldata key, // PoolKey which identifies the specific pool
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData // Extra data passed to the hook by the swpa caller
     ) external override poolManagerOnly returns (bytes4 selector, BeforeSwapDelta beforeSwapDelta, uint24 fee)
     {

        // Fetching current tick from pool manager
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());

        // Generate position key from pool key and sender
        bytes32 positionKey = _generatePositionKey(key, sender);

        // Call LiquidityOrchestrator to prepare pre-swap liquidity
        (bool success, uint256 availableAmount0, uint256 availableAmount1) = 
            liquidityOrchestrator.preparePreSwapLiquidity(positionKey, currentTick);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);


     }

     function afterSwap(
        address sender, 
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta, 
        bytes calldata hookData
    ) external override poolManagerOnly returns(bytes4 selector, int128 fee )
     {
        // Generate position key from pool key and sender
        bytes32 positionKey = _generatePositionKey(key, sender);
        
        // Getting the old tick from LiquidityOrchestrator lastActiveTick 
        int24 oldTick = liquidityOrchestrator.LastActiveTick(positionKey);

        (, int24 newTick, , ) = poolManager.getSlot0(key.toId());

        bool success = liquidityOrchestrator.executePostSwapManagement(positionKey, oldTick, newTick);

        return (BaseHook.afterSwap.selector, 0);
     }
}
