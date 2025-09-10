// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Position} from "v4-core/libraries/Position.sol";

import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import "forge-std/console.sol";
import {RehypothecationHooks} from "../src/hooks/RehypothecationHooks.sol";
import {Aave} from "../src/Aave.sol";
import {LiquidityOrchestrator} from "../src/LiquidityOrchestrator.sol";
import {IAave} from "../src/interfaces/IAave.sol";
import {ILiquidityOrchestrator} from "../src/interfaces/ILiquidityOrchestrator.sol";
import {Constant} from "../src/utils/Constant.sol";

// Mock LendingPool for testing
contract MockLendingPool {
    mapping(address => mapping(address => uint256)) public deposits;

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        deposits[onBehalfOf][asset] += amount;
    }

    function withdraw(address asset, uint256 amount, address) external returns (uint256) {
        require(deposits[msg.sender][asset] >= amount, "Not enough balance");
        deposits[msg.sender][asset] -= amount;
        return amount;
    }
}

contract RehypothecationHooksTest is Test, Deployers, ERC1155TokenReceiver {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Contracts
    RehypothecationHooks hook;
    LiquidityOrchestrator orchestrator;
    Aave aaveContract;
    MockLendingPool mockLendingPool;
    MockERC20 token0;
    MockERC20 token1;

    // Addresses
    address user = address(1);

    // Pool data
    PoolKey poolKey;

    function setUp() public {
        // Deploy PoolManager and routers
        deployFreshManagerAndRouters();

        // Deploy tokens
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);

        // Sort tokens to ensure correct currency0/currency1 assignment
        if (address(token0) < address(token1)) {
            currency0 = Currency.wrap(address(token0));
            currency1 = Currency.wrap(address(token1));
        } else {
            currency0 = Currency.wrap(address(token1));
            currency1 = Currency.wrap(address(token0));
        }

        // Mint tokens
        token0.mint(address(this), 1000 ether);
        token0.mint(user, 1000 ether);
        token1.mint(address(this), 1000 ether);
        token1.mint(user, 1000 ether);

        // Deploy mock lending pool
        mockLendingPool = new MockLendingPool();

        // Deploy Aave contract
        aaveContract = new Aave(address(mockLendingPool));

        // Deploy LiquidityOrchestrator
        orchestrator = new LiquidityOrchestrator(address(aaveContract));

        // Deploy hook with correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
        );
        address hookAddress = address(flags);

        // Get hook deployment bytecode
        deployCodeTo("RehypothecationHooks.sol", abi.encode(manager, aaveContract, orchestrator), hookAddress);

        // Deploy the hook to a deterministic address with the hook flags
        hook = RehypothecationHooks(hookAddress);

        // Approve tokens for routers
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);

        // Approve tokens for routers
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // Approve tokens for the orchestrator (needed for Aave deposits)
        token0.approve(address(orchestrator), type(uint256).max);
        token1.approve(address(orchestrator), type(uint256).max);

        // Also approve the Aave contract
        token0.approve(address(aaveContract), type(uint256).max);
        token1.approve(address(aaveContract), type(uint256).max);

        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);
        poolKey = key;
    }

    function test_AddLiquidity() public {
        // Add liquidity to the pool
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 amount0Desired = 1 ether;
        uint256 amount1Desired = 1 ether;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, sqrtPriceLower, sqrtPriceUpper, amount0Desired, amount1Desired
        );

        bytes memory hookData = abi.encode(tickLower, tickUpper);

        // Call modifyLiquidity - this will trigger the afterAddLiquidity hook
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            hookData
        );
        console.log("Added liquidity");

        // Generate position key to check
        bytes32 positionKey = keccak256(abi.encodePacked(poolKey.toId(), tickLower, tickUpper));

        // Check if position exists in orchestrator
        assertTrue(orchestrator.isPositionExists(positionKey), "Position not created");

        // Get position data
        ILiquidityOrchestrator.PositionData memory position = orchestrator.getPosition(positionKey);

        // Check position data
        assertTrue(position.exists, "Position should exist");
        assertEq(position.tickLower, tickLower, "Incorrect lower tick");
        assertEq(position.tickUpper, tickUpper, "Incorrect upper tick");
        assertEq(position.reservePct, Constant.DEFAULT_RESERVE_PCT, "Incorrect reserve percentage");
    }

    function test_AddLiquidityOutOfRange() public {
        // Get current tick
        (, int24 currentTick,,) = manager.getSlot0(poolKey.toId());
        console.log("Current tick:", currentTick);
        // get tick spacing

        // Add liquidity well above current range (out of range)
        int24 tickLower = currentTick + 120;
        int24 tickUpper = currentTick + 240;

        uint256 amount0Desired = 1 ether;
        uint256 amount1Desired = 1 ether;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, sqrtPriceLower, sqrtPriceUpper, amount0Desired, amount1Desired
        );
        console.log("Calculated out of range liquidity:", liquidity);

        bytes memory hookData = abi.encode(tickLower, tickUpper);

        // Add out of range liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            hookData
        );
        console.log("Added out of range liquidity");

        // Check if position was created
        bytes32 positionKey = keccak256(abi.encodePacked(poolKey.toId(), tickLower, tickUpper));
        assertTrue(orchestrator.isPositionExists(positionKey), "Position not created");

        // Check if liquidity went to Aave
        ILiquidityOrchestrator.PositionData memory position = orchestrator.getPosition(positionKey);
        console.log("Position state:", uint8(position.state));
        console.log("Position Aave amount 0:", position.aaveAmount0);
        console.log("Position Aave amount 1:", position.aaveAmount1);
        console.log("Position reserve amount 0:", position.reserveAmount0);
        console.log("Position reserve amount 1:", position.reserveAmount1);
        console.log("Position liquidity:", position.totalLiquidity);
        assertTrue(position.state == ILiquidityOrchestrator.PositionState.IN_AAVE, "Position should be in Aave");
        assertTrue(position.aaveAmount0 > 0 || position.aaveAmount1 > 0, "No liquidity in Aave");
    }
    // function test_Swap() public {
    //     // First add liquidity
    //     test_AddLiquidity();

    //     // Now perform a swap that crosses the price range
    //     SwapParams memory params =
    //         SwapParams({zeroForOne: true, amountSpecified: 0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

    //     // Swap will trigger beforeSwap and afterSwap hooks
    //     BalanceDelta delta =
    //         swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

    //     // Generate position key
    //     bytes32 positionKey = keccak256(abi.encode(poolKey.toId(), address(this)));

    //     // Check position state after swap
    //     ILiquidityOrchestrator.PositionData memory position = orchestrator.getPosition(positionKey);

    //     // Perform assertions based on expected state changes
    //     // This will depend on exact swap mechanics and current tick
    //     assertTrue(position.exists, "Position should still exist after swap");
    // }

    // function test_RemoveLiquidity() public {
    //     // First add liquidity
    //     test_AddLiquidity();

    //     // Generate position key
    //     bytes32 positionKey = keccak256(abi.encode(poolKey.toId(), address(this)));

    //     // Get initial position data
    //     ILiquidityOrchestrator.PositionData memory initialPosition = orchestrator.getPosition(positionKey);

    //     // Remove half of the liquidity
    //     int24 tickLower = -60;
    //     int24 tickUpper = 60;

    //     // Get current liquidity in the position
    //     bytes32 uniswapPositionKey = Position.calculatePositionKey(address(this), tickLower, tickUpper, 0);
    //     Position.State memory positionState = Position.get(self, owner, tickLower, tickUpper, salt);

    //     ModifyLiquidityParams memory params = ModifyLiquidityParams({
    //         tickLower: tickLower,
    //         tickUpper: tickUpper,
    //         liquidityDelta: -int256(uint256(liquidity)) / 2, // Remove half
    //         salt: bytes32(0)
    //     });

    //     // Call modifyLiquidity - this will trigger beforeRemoveLiquidity and afterRemoveLiquidity hooks
    //     BalanceDelta delta = modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

    //     // Check position state after removal
    //     ILiquidityOrchestrator.PositionData memory finalPosition = orchestrator.getPosition(positionKey);

    //     assertTrue(finalPosition.exists, "Position should still exist after partial removal");
    //     // Add more assertions based on expected behavior
    // }

    // function test_CompleteRemoveLiquidity() public {
    //     // First add liquidity
    //     test_AddLiquidity();

    //     // Generate position key
    //     bytes32 positionKey = keccak256(abi.encode(poolKey.toId(), address(this)));

    //     // Get current position data
    //     ILiquidityOrchestrator.PositionData memory initialPosition = orchestrator.getPosition(positionKey);

    //     // Remove all liquidity
    //     int24 tickLower = -60;
    //     int24 tickUpper = 60;

    //     // Get current liquidity in the position
    //     bytes32 uniswapPositionKey = Position.calculatePositionKey(address(this), tickLower, tickUpper, 0);
    //     Position.State memory positionState = manager.getPosition(poolKey.toId(), uniswapPositionKey);
    //     uint128 liquidity = positionState.liquidity;

    //     ModifyLiquidityParams memory params = ModifyLiquidityParams({
    //         tickLower: tickLower,
    //         tickUpper: tickUpper,
    //         liquidityDelta: -int256(uint256(liquidity)), // Remove all
    //         salt: bytes32(0)
    //     });

    //     // Call modifyLiquidity - this will trigger hooks
    //     BalanceDelta delta = modifyLiquidityRouter.modifyLiquidity(poolKey, params, "");

    //     // Check position state after complete removal
    //     ILiquidityOrchestrator.PositionData memory finalPosition = orchestrator.getPosition(positionKey);

    //     assertTrue(finalPosition.exists, "Position record should still exist");
    //     assertEq(
    //         uint8(finalPosition.state),
    //         uint8(ILiquidityOrchestrator.PositionState.IN_RANGE),
    //         "Position should be marked as IN_RANGE"
    //     );
    // }

    // function test_SwapOutOfRange() public {
    //     // First add liquidity
    //     test_AddLiquidity();

    //     // Make a large swap to move price out of range
    //     SwapParams memory params = SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: 0.5 ether, // Large enough to move out of range
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     // Swap will trigger hooks
    //     BalanceDelta delta =
    //         swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

    //     // Generate position key
    //     bytes32 positionKey = keccak256(abi.encode(poolKey.toId(), address(this)));

    //     // Check if position state changed to IN_AAVE
    //     ILiquidityOrchestrator.PositionData memory position = orchestrator.getPosition(positionKey);

    //     // This assertion depends on exact implementation
    //     // If price moved out of range, liquidity should be moved to Aave
    //     assertTrue(position.exists, "Position should still exist after swap");
    // }

    // // Additional tests for specific edge cases
    // function test_RebalancingWhenTickChanges() public {
    //     // First add liquidity
    //     test_AddLiquidity();

    //     // Make a small swap that doesn't cross range boundaries
    //     SwapParams memory smallSwapParams = SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: 0.01 ether,
    //         sqrtPriceLimitX96: SQRT_PRICE_1_2 // Limit to ensure we stay in range
    //     });

    //     // Execute swap
    //     swapRouter.swap(
    //         poolKey, smallSwapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
    //     );

    //     // Now make a large swap to cross range boundaries
    //     SwapParams memory largeSwapParams =
    //         SwapParams({zeroForOne: true, amountSpecified: 0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

    //     // Execute swap that should trigger rebalancing
    //     swapRouter.swap(
    //         poolKey, largeSwapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
    //     );

    //     // Generate position key
    //     bytes32 positionKey = keccak256(abi.encode(poolKey.toId(), address(this)));

    //     // Check position state
    //     ILiquidityOrchestrator.PositionData memory position = orchestrator.getPosition(positionKey);

    //     // Verify state transitions based on implementation
    //     assertTrue(position.exists, "Position should exist after rebalancing");
    // }

    // // Test for multiple positions and swaps
    // function test_MultiplePositionsAndSwaps() public {
    //     // Add first position
    //     test_AddLiquidity();

    //     // Add second position with different range
    //     int24 tickLower2 = -120;
    //     int24 tickUpper2 = 120;

    //     uint160 sqrtPriceLower2 = TickMath.getSqrtPriceAtTick(tickLower2);
    //     uint160 sqrtPriceUpper2 = TickMath.getSqrtPriceAtTick(tickUpper2);

    //     uint128 liquidity2 = LiquidityAmounts.getLiquidityForAmounts(
    //         SQRT_PRICE_1_1, sqrtPriceLower2, sqrtPriceUpper2, 0.5 ether, 0.5 ether
    //     );

    //     ModifyLiquidityParams memory params2 = ModifyLiquidityParams({
    //         tickLower: tickLower2,
    //         tickUpper: tickUpper2,
    //         liquidityDelta: int256(uint256(liquidity2)),
    //         salt: bytes32(0)
    //     });

    //     // Add second position
    //     modifyLiquidityRouter.modifyLiquidity(poolKey, params2, "");

    //     // Execute multiple swaps
    //     for (uint256 i = 0; i < 3; i++) {
    //         SwapParams memory swapParams = SwapParams({
    //             zeroForOne: i % 2 == 0, // Alternate swap direction
    //             amountSpecified: 0.1 ether,
    //             sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
    //         });

    //         swapRouter.swap(
    //             poolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
    //         );
    //     }

    //     // Check both positions
    //     bytes32 positionKey1 = keccak256(abi.encode(poolKey.toId(), address(this)));
    //     ILiquidityOrchestrator.PositionData memory position1 = orchestrator.getPosition(positionKey1);

    //     assertTrue(position1.exists, "First position should still exist");

    //     // Additional assertions based on expected behavior
    // }
}
