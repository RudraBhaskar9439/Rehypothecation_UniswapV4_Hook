// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {euint256, FHE, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
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
import {IAave, ReserveData} from "../src/interfaces/IAave.sol";
import {ILiquidityOrchestrator} from "../src/interfaces/ILiquidityOrchestrator.sol";
import {Constant} from "../src/utils/Constant.sol";

// Mock aToken that represents Aave interest-bearing tokens
contract MockAToken is MockERC20 {
    address public underlyingAsset;

    constructor(string memory name, string memory symbol, address _underlyingAsset) MockERC20(name, symbol, 18) {
        underlyingAsset = _underlyingAsset;
    }
}

// Mock LendingPool for testing
// Mock LendingPool for testing
contract MockLendingPool {
    mapping(address => mapping(address => uint256)) public deposits;
    mapping(address => MockAToken) public aTokens;

    constructor() {}

    function createAToken(address asset, string memory name, string memory symbol) external {
        aTokens[asset] = new MockAToken(name, symbol, asset);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        deposits[onBehalfOf][asset] += amount;
        // Mint aTokens to represent the deposit (1:1 ratio for simplicity)
        aTokens[asset].mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        // Get the current aToken balance to determine actual withdrawable amount
        uint256 aTokenBalance = aTokens[asset].balanceOf(to);
        uint256 withdrawAmount;

        console.log("Current aToken balance:", aTokenBalance);
        console.log("Deposits mapping balance:", deposits[to][asset]);
        console.log("Requested withdrawal amount:", amount);

        if (amount == type(uint256).max) {
            require(aTokenBalance > 0, "Not enough balance");
            withdrawAmount = aTokenBalance;
        } else {
            require(aTokenBalance >= amount, "Not enough balance");
            withdrawAmount = amount;
        }

        // Update deposits to reflect the withdrawal
        // Note: deposits should track the aToken balance, not just initial deposits
        deposits[to][asset] = aTokenBalance - withdrawAmount;

        // Burn aTokens
        aTokens[asset].burn(to, withdrawAmount);

        console.log("Actual withdrawal amount:", withdrawAmount);
        return withdrawAmount;
    }

    function getReserveData(address asset) external view returns (ReserveData memory) {
        return ReserveData({
            liquidityIndex: 0,
            currentLiquidityRate: 0,
            variableBorrowIndex: 0,
            currentVariableBorrowRate: 0,
            currentStableBorrowRate: 0,
            lastUpdateTimestamp: 0,
            id: 0,
            aTokenAddress: address(aTokens[asset]),
            stableDebtTokenAddress: address(0),
            variableDebtTokenAddress: address(0),
            interestRateStrategyAddress: address(0),
            accruedToTreasury: 0,
            unbacked: 0,
            isolationModeTotalDebt: 0
        });
    }

    // Helper function to simulate yield by updating deposits mapping
    function simulateYield(address asset, address user, uint256 yieldAmount) external {
        deposits[user][asset] += yieldAmount;
        aTokens[asset].mint(user, yieldAmount);
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

        // Create aTokens for the underlying assets
        mockLendingPool.createAToken(address(token0), "aToken0", "aTKN0");
        mockLendingPool.createAToken(address(token1), "aToken1", "aTKN1");

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

        // Approve the mock lending pool to transfer tokens from orchestrator
        vm.startPrank(address(orchestrator));
        token0.approve(address(mockLendingPool), type(uint256).max);
        token1.approve(address(mockLendingPool), type(uint256).max);
        vm.stopPrank();

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

        // Fund the orchestrator with tokens for Aave deposits
        token0.mint(address(orchestrator), 10 ether);
        token1.mint(address(orchestrator), 10 ether);

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

        // console.log("Position Aave amount 0:", FHE.decrypt(position.aaveAmount0));
        // console.log("Position Aave amount 1:", FHE.decrypt(position.aaveAmount1));
        // console.log("Position reserve amount 0:", FHE.decrypt(position.reserveAmount0));
        // console.log("Position reserve amount 1:", FHE.decrypt(position.reserveAmount1));
        // console.log("Position liquidity:", FHE.decrypt(position.totalLiquidity));
        assertTrue(position.state == ILiquidityOrchestrator.PositionState.IN_AAVE, "Position should be in Aave");
        assertTrue(position.aaveAmount0 > 0 || position.aaveAmount1 > 0, "No liquidity in Aave");
    }

    function test_removeLiquidityOutOfRange() public {
        // Get current tick and set range
        (, int24 currentTick,,) = manager.getSlot0(poolKey.toId());
        int24 tickLower = currentTick + 120;
        int24 tickUpper = currentTick + 240;

        // Calculate liquidity amount
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            1 ether,
            1 ether
        );

        bytes memory hookData = abi.encode(tickLower, tickUpper);
        bytes32 positionKey = keccak256(abi.encodePacked(poolKey.toId(), tickLower, tickUpper));

        // Fund the orchestrator with tokens for Aave deposits
        token0.mint(address(orchestrator), 10 ether);
        token1.mint(address(orchestrator), 10 ether);

        // Add liquidity first
        _addLiquidity(tickLower, tickUpper, liquidity, hookData);

        // Verify funds are in Aave
        ILiquidityOrchestrator.PositionData memory positionBefore = orchestrator.getPosition(positionKey);
        assertTrue(positionBefore.state == ILiquidityOrchestrator.PositionState.IN_AAVE, "Not in Aave");
        assertTrue(positionBefore.aaveAmount0 > 0 || positionBefore.aaveAmount1 > 0, "No Aave liquidity");

        // Record balances
        uint256 balanceBefore0 = token0.balanceOf(address(this));
        uint256 balanceBefore1 = token1.balanceOf(address(this));

        // Remove liquidity
        _removeLiquidity(tickLower, tickUpper, liquidity, hookData);

        // Check balances increased
        assertTrue(
            token0.balanceOf(address(this)) > balanceBefore0 || token1.balanceOf(address(this)) > balanceBefore1,
            "No tokens returned"
        );

        // Verify Aave withdrawal and position deletion
        ILiquidityOrchestrator.PositionData memory positionAfter = orchestrator.getPosition(positionKey);
        assertTrue(!positionAfter.exists, "Position should not exist after complete removal");
    }

    function _addLiquidity(int24 lower, int24 upper, uint128 liq, bytes memory data) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(lower, upper, int256(uint256(liq)), bytes32(0)), data
        );
    }

    function _removeLiquidity(int24 lower, int24 upper, uint128 liq, bytes memory data) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(lower, upper, -int256(uint256(liq)), bytes32(0)), data
        );
    }

    function test_swapwithFinalTickOutOfRange() public {
        // 1. Add liquidity in range
        (, int24 currentTick,,) = manager.getSlot0(poolKey.toId());
        int24 tickLower = currentTick - 60;
        int24 tickUpper = currentTick + 60;

        uint256 amount0Desired = 1 ether;
        uint256 amount1Desired = 1 ether;

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, sqrtPriceLower, sqrtPriceUpper, amount0Desired, amount1Desired
        );

        bytes memory hookData = abi.encode(tickLower, tickUpper);
        bytes32 positionKey = keccak256(abi.encodePacked(poolKey.toId(), tickLower, tickUpper));

        // Fund the orchestrator with tokens for potential Aave operations
        token0.mint(address(orchestrator), 10 ether);
        token1.mint(address(orchestrator), 10 ether);

        _addLiquidity(tickLower, tickUpper, liquidity, hookData);

        // 2. Check position is in range and not in Aave
        ILiquidityOrchestrator.PositionData memory positionBefore = orchestrator.getPosition(positionKey);
        assertEq(positionBefore.aaveAmount0, 0, "Token0 Aave amount should be 0 before swap");
        assertEq(positionBefore.aaveAmount1, 0, "Token1 Aave amount should be 0 before swap");
        assertTrue(
            positionBefore.state == ILiquidityOrchestrator.PositionState.IN_RANGE,
            "State should be IN_RANGE before swap"
        );

        // 3. Perform a swap that moves the tick out of range (e.g. large swap)
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: 2 ether, // Large enough to move price out of range
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Perform the swap (triggers hooks)
        swapRouter.swap(
            poolKey, swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData
        );

        // 4. Check tick is now out of range
        int24 newTick = _getTickFromPoolManager(poolKey);
        assertTrue(newTick < tickLower || newTick > tickUpper, "Tick should be out of range after swap");

        // 5. Check position is now in Aave and both tokens are deposited to Aave (80% each)
        ILiquidityOrchestrator.PositionData memory positionAfter = orchestrator.getPosition(positionKey);

        // Each token's Aave amount should be 80% of its liquidity after swap
        assertApproxEqAbs(
            positionAfter.aaveAmount0,
            ((positionAfter.totalLiquidity / 2) * 80) / 100,
            1,
            "Token0 Aave amount should be 80% of its liquidity after swap"
        );
        assertApproxEqAbs(
            positionAfter.aaveAmount1,
            ((positionAfter.totalLiquidity / 2) * 80) / 100,
            1,
            "Token1 Aave amount should be 80% of its liquidity after swap"
        );

        assertTrue(
            positionAfter.state == ILiquidityOrchestrator.PositionState.IN_AAVE,
            "Position should be in Aave after out-of-range swap"
        );
    }

    // Helper to get current tick from pool manager
    function _getTickFromPoolManager(PoolKey memory _poolKey) internal view returns (int24) {
        (, int24 currentTick,,) = manager.getSlot0(_poolKey.toId());
        return currentTick;
    }

    function test_removeLiquidityInRange() public {
        // 1. Add liquidity in range
        (, int24 currentTick,,) = manager.getSlot0(poolKey.toId());
        int24 tickLower = currentTick - 60;
        int24 tickUpper = currentTick + 60;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            1 ether,
            1 ether
        );

        bytes memory hookData = abi.encode(tickLower, tickUpper);
        bytes32 positionKey = keccak256(abi.encodePacked(poolKey.toId(), tickLower, tickUpper));

        _addLiquidity(tickLower, tickUpper, liquidity, hookData);

        // Remove all liquidity
        _removeLiquidity(tickLower, tickUpper, liquidity, hookData);

        // Check position after removal
        ILiquidityOrchestrator.PositionData memory positionAfter = orchestrator.getPosition(positionKey);

        // All values should be zero and position should not exist
        assertEq(positionAfter.aaveAmount0, 0, "Token0 Aave amount should be zero after removal");
        assertEq(positionAfter.aaveAmount1, 0, "Token1 Aave amount should be zero after removal");
        assertEq(positionAfter.totalLiquidity, 0, "Total liquidity should be zero after complete removal");
        assertTrue(!positionAfter.exists, "Position should not exist after removal");
    }

    function test_swapWithFinalTickInRange() public {
        // Add liquidity in range
        (, int24 currentTickBeforeAdd,,) = manager.getSlot0(poolKey.toId());
        int24 tickLower = currentTickBeforeAdd - 60;
        int24 tickUpper = currentTickBeforeAdd + 60;

        uint256 amount0Desired = 1 ether;
        uint256 amount1Desired = 1 ether;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );
        bytes memory hookData = abi.encode(tickLower, tickUpper);
        bytes32 positionKey = keccak256(abi.encodePacked(poolKey.toId(), tickLower, tickUpper));

        _addLiquidity(tickLower, tickUpper, liquidity, hookData);

        ILiquidityOrchestrator.PositionData memory positionBeforeSwap = orchestrator.getPosition(positionKey);
        assertEq(positionBeforeSwap.aaveAmount0, 0, "Token0 Aave amount should be 0 before swap");
        assertEq(positionBeforeSwap.aaveAmount1, 0, "Token1 Aave amount should be 0 before swap");
        assertTrue(
            positionBeforeSwap.state == ILiquidityOrchestrator.PositionState.IN_RANGE,
            "State should be IN_RANGE before swap"
        );

        // Record initial balances of the orchestrator to check for any unexpected transfers
        uint256 orchestratorBalance0BeforeSwap = token0.balanceOf(address(orchestrator));
        uint256 orchestratorBalance1BeforeSwap = token1.balanceOf(address(orchestrator));

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true, // Swap token0 for token1
            amountSpecified: 0.01 ether, // Small amount
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 // Allow price to move
        });

        int24 oldTick = _getTickFromPoolManager(poolKey);
        console.log("Old tick before swap:", oldTick);

        _performSwap(poolKey, swapParams, hookData);

        int24 newTick = _getTickFromPoolManager(poolKey);
        console.log("New tick after swap:", newTick);

        // Verify final state: liquidity should still be IN_RANGE and not in Aave
        ILiquidityOrchestrator.PositionData memory positionAfterSwap = orchestrator.getPosition(positionKey);
        assertEq(positionAfterSwap.aaveAmount0, 0, "Token0 Aave amount should still be 0 after in-range swap");
        assertEq(positionAfterSwap.aaveAmount1, 0, "Token1 Aave amount should still be 0 after in-range swap");
        assertTrue(
            positionAfterSwap.state == ILiquidityOrchestrator.PositionState.IN_RANGE,
            "State should remain IN_RANGE after in-range swap"
        );

        // Verify orchestrator balances did not change due to Aave deposits/withdrawals
        assertEq(
            token0.balanceOf(address(orchestrator)),
            orchestratorBalance0BeforeSwap,
            "Orchestrator token0 balance changed unexpectedly"
        );
        assertEq(
            token1.balanceOf(address(orchestrator)),
            orchestratorBalance1BeforeSwap,
            "Orchestrator token1 balance changed unexpectedly"
        );

        // Assert that the new tick is still within the original range
        assertTrue(newTick >= tickLower && newTick <= tickUpper, "Final tick should remain within the liquidity range");

        console.log("Swap completed successfully with final tick in range.");
    }

    function _performSwap(PoolKey memory _poolKey, SwapParams memory _swapParams, bytes memory _hookData) internal {
        // The modifyLiquidityRouter's swap function will trigger the hooks
        swapRouter.swap(
            _poolKey, _swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), _hookData
        );
    }
}
