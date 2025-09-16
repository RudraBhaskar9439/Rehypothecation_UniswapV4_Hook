// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {euint256, FHE, ebool, euint32} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {InEuint32} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";

import {LiquidityOrchestrator} from "../LiquidityOrchestrator.sol";

import {Constant} from "../utils/Constant.sol";

import {ILiquidityOrchestrator} from "../interfaces/ILiquidityOrchestrator.sol";
import {IAave} from "../interfaces/IAave.sol";

contract RehypothecationHooks is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Encrypted tick storage for privacy
    mapping(bytes32 => euint32) private encryptedLastActiveTicks;

    // State Variable
    IAave public immutable aavePool;
    ILiquidityOrchestrator public immutable liquidityOrchestrator;
    int24 public lastActiveTick;
    mapping(bytes32 => ebool) private encryptedWithdrawalNeeded;
    mapping(bytes32 => euint32) private encryptedTimestamp;

    // Owner
    address public owner;

    // Events
    event HookInitialized(
        address indexed poolManager,
        address indexed aavePool
    );
    event ReservePercentageUpdated(
        bytes32 indexed positionKey,
        uint256 oldPercentage,
        uint256 newPercentage
    );
    event EncryptedLiquiditySignal(
        bytes32 indexed positionKey,
        bytes encryptedSignal
    );
    event EncryptedWithdrawalPrepared(
        bytes32 indexed positionKey,
        bytes encryptedAmount
    );
    event EncryptedRebalancingDecision(
        bytes32 indexed positionKey,
        bytes encryptedDecision
    );
    event EncryptedPostSwapCompleted(
        bytes32 indexed positionKey,
        bytes encryptedResult
    );

    // Custom Errors
    error LiquidityAdditionFailed();
    error LiquidityRemovalFailed();
    error PostWithdrawalRebalanceFailed();
    error PreSwapLiquidityPreparationFailed();
    error PostSwapManagementFailed();
    error DecryptionFailed();

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
        ILiquidityOrchestrator _liquidityOrchestrator
    ) BaseHook(_poolManager) {
        aavePool = _aavePool;
        liquidityOrchestrator = _liquidityOrchestrator;
        owner = msg.sender;

        emit HookInitialized(address(_poolManager), address(_aavePool));
    }

    /**
     * @dev Returns the hook permissions required for this contract
     */
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
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
     * @notice  Decrypts the hook data to extract lower and upper ticks.
     * @param   hookData  The encrypted or plain hook data.
     * @return  lowerTick  lower tick.
     * @return  upperTick  upper tick.
     */
    function _decryptHookData(
        bytes calldata hookData
    ) internal returns (int24 lowerTick, int24 upperTick) {
        if (hookData.length == 0) {
            revert DecryptionFailed();
        }

        bool isEncrypted = hookData[0] == 0x01;
        if (isEncrypted) {
            // Extract encrypted data (skip first flag byte)
            bytes memory encryptedData = hookData[1:];

            // Decode the encrypted ticks to the InEuint32 type
            (InEuint32 memory encLowerTick, InEuint32 memory encUpperTick) = abi
                .decode(encryptedData, (InEuint32, InEuint32));

            // Convert InEuint32 to euint32 using FHE.asEuint32
            // This is the correct way to handle InEuint32 inputs
            euint32 lowerTickEnc = FHE.asEuint32(encLowerTick);
            euint32 upperTickEnc = FHE.asEuint32(encUpperTick);

            // Decrypt the values
            (uint32 lowerTickOffset, ) = FHE.getDecryptResultSafe(lowerTickEnc);
            (uint32 upperTickOffset, ) = FHE.getDecryptResultSafe(upperTickEnc);

            // Convert back to signed ticks by removing the offset
            // Offset = 2^23 = 8,388,608 (allows range from -8,388,608 to +8,388,607)
            uint32 TICK_OFFSET = 8388608;
            lowerTick = int24(int32(lowerTickOffset) - int32(TICK_OFFSET));
            upperTick = int24(int32(upperTickOffset) - int32(TICK_OFFSET));
        } else {
            // Decode plain data
            (lowerTick, upperTick) = abi.decode(hookData[1:], (int24, int24));
        }
    }

    /**
     * @notice  Will perform liquidity management after liquidity is added to a pool, either creating a new
     *          position or updating an existing one.
     * @param   key  The pool key
     * @param   params  The parameters for modifying liquidity
     * @param   delta  The change in balance
     * @param   hookData  Additional data for the hook
     */
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4 selector, BalanceDelta returnedDelta) {
        (int24 lowerTick, int24 upperTick) = _decryptHookData(hookData);
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());

        bytes32 positionKey = _generatePositionKey(
            key,
            params.tickLower,
            params.tickUpper
        );

        // Move this logic to a helper to reduce stack usage
        _handleAfterAddLiquidity(
            key,
            params,
            delta,
            lowerTick,
            upperTick,
            currentTick,
            positionKey
        );

        return (
            this.afterAddLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

    function _handleAfterAddLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        int24 lowerTick,
        int24 upperTick,
        int24 currentTick,
        bytes32 positionKey
    ) internal {
        uint256 amount0In = delta.amount0() < 0
            ? uint256(int256(-delta.amount0()))
            : 0;
        uint256 amount1In = delta.amount1() < 0
            ? uint256(int256(-delta.amount1()))
            : 0;

        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        if (liquidityOrchestrator.isPositionExists(positionKey)) {
            _updateExistingPosition(
                positionKey,
                currentTick,
                amount0In,
                amount1In,
                asset0,
                asset1
            );
        } else {
            _createNewPosition(
                key,
                lowerTick,
                upperTick,
                amount0In,
                amount1In,
                positionKey,
                currentTick,
                asset0,
                asset1
            );
        }
    }

    function _updateExistingPosition(
        bytes32 positionKey,
        int24 currentTick,
        uint256 amount0In,
        uint256 amount1In,
        address asset0,
        address asset1
    ) internal {
        bool success = liquidityOrchestrator.processLiquidityAdditionDeposit(
            positionKey,
            currentTick,
            amount0In,
            amount1In,
            asset0,
            asset1
        );
        if (!success) {
            revert LiquidityAdditionFailed();
        }
    }

    function _createNewPosition(
        PoolKey calldata key,
        int24 lowerTick,
        int24 upperTick,
        uint256 amount0In,
        uint256 amount1In,
        bytes32 positionKey,
        int24 currentTick,
        address asset0,
        address asset1
    ) internal {
        uint256 totalLiquidity = amount0In + amount1In;

        ILiquidityOrchestrator.PositionData memory data = ILiquidityOrchestrator
            .PositionData({
                tickLower: lowerTick,
                tickUpper: upperTick,
                totalLiquidity: FHE.asEuint256(totalLiquidity),
                reservePct: Constant.DEFAULT_RESERVE_PCT,
                reserveAmount0: FHE.asEuint256(amount0In),
                reserveAmount1: FHE.asEuint256(amount1In),
                aaveAmount0: FHE.asEuint256(0),
                aaveAmount1: FHE.asEuint256(0),
                exists: true,
                state: ILiquidityOrchestrator.PositionState.IN_RANGE
            });

        liquidityOrchestrator.upsertPosition(positionKey, data);

        bool success = liquidityOrchestrator.processLiquidityAdditionDeposit(
            positionKey,
            currentTick,
            amount0In,
            amount1In,
            asset0,
            asset1
        );
        if (!success) {
            revert LiquidityAdditionFailed();
        }
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4 selector) {
        // Generate position key from pool key and sender
        bytes32 positionKey = _generatePositionKey(
            key,
            params.tickLower,
            params.tickUpper
        );

        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        bool success = liquidityOrchestrator.preparePositionForWithdrawal(
            positionKey,
            asset0,
            asset1
        );

        if (!success) {
            revert LiquidityRemovalFailed();
        }

        return (this.beforeRemoveLiquidity.selector);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 positionKey = _generatePositionKey(
            key,
            params.tickLower,
            params.tickUpper
        );
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        lastActiveTick = currentTick;

        (
            uint256 liqAmount0,
            uint256 liqAmount1,
            address asset0,
            address asset1
        ) = _computeAfterRemoveAmounts(key, positionKey, delta);

        bool success = liquidityOrchestrator.handlePostWithdrawalRebalance(
            positionKey,
            currentTick,
            liqAmount0,
            liqAmount1,
            asset0,
            asset1
        );

        if (!success) {
            revert PostWithdrawalRebalanceFailed();
        }

        return (this.afterRemoveLiquidity.selector, delta);
    }

    function _computeAfterRemoveAmounts(
        PoolKey calldata key,
        bytes32 positionKey,
        BalanceDelta delta
    )
        internal
        view
        returns (
            uint256 liqAmount0,
            uint256 liqAmount1,
            address asset0,
            address asset1
        )
    {
        uint256 withdrawn0 = delta.amount0() > 0
            ? uint256(int256(delta.amount0()))
            : 0;
        uint256 withdrawn1 = delta.amount1() > 0
            ? uint256(int256(delta.amount1()))
            : 0;

        ILiquidityOrchestrator.PositionData memory pos = liquidityOrchestrator
            .getPosition(positionKey);

        // Decrypt amounts first to avoid comparison issues
        (uint256 reserveAmount0, ) = FHE.getDecryptResultSafe(
            pos.reserveAmount0
        );
        (uint256 reserveAmount1, ) = FHE.getDecryptResultSafe(
            pos.reserveAmount1
        );

        // Allow for rounding errors: if almost all is withdrawn, treat as zero
        uint256 tolerance = 2; // 2 wei tolerance for rounding
        if (
            (reserveAmount0 <= withdrawn0 + tolerance) &&
            (reserveAmount1 <= withdrawn1 + tolerance)
        ) {
            liqAmount0 = 0;
            liqAmount1 = 0;
        } else {
            liqAmount0 = reserveAmount0 > withdrawn0
                ? reserveAmount0 - withdrawn0
                : 0;
            liqAmount1 = reserveAmount1 > withdrawn1
                ? reserveAmount1 - withdrawn1
                : 0;
        }

        asset0 = Currency.unwrap(key.currency0);
        asset1 = Currency.unwrap(key.currency1);
    }

    /**
     * @dev Hook called before a swap to ensure sufficient liquidity.
     * @param key => The pool key
     * @param hookData => Additional data passed to the hook
     * @return selector => Function selecrotor to continue execution
     * @return beforeSwapDelta => The delta to apply befoe swap
     * @return fee => The fee to apply
     */
    function _beforeSwap(
        address, // Address calling the swap
        PoolKey calldata key, // PoolKey which identifies the specific pool
        SwapParams calldata,
        bytes calldata hookData // Extra data passed to the hook by the swap caller
    )
        internal
        override
        returns (bytes4 selector, BeforeSwapDelta beforeSwapDelta, uint24 fee)
    {
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());

        (int24 lowerTick, int24 upperTick) = _decryptHookData(hookData);

        bytes32 positionKey = _generatePositionKey(key, lowerTick, upperTick);

        _emitEncryptedLiquiditySignal(positionKey, currentTick);

        bool actualNeedsWithdrawal = liquidityOrchestrator
            .checkPreSwapLiquidityNeeds(positionKey, currentTick);

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        if (actualNeedsWithdrawal) {
            _preparePreSwap(positionKey, currentTick, token0, token1);
        }

        _emitEncryptedWithdrawalPrepared(positionKey);

        lastActiveTick = currentTick;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _emitEncryptedLiquiditySignal(
        bytes32 positionKey,
        int24 currentTick
    ) internal {
        euint32 encryptedCurrentTick = FHE.asEuint32(
            uint32(int32(currentTick))
        );
        encryptedLastActiveTicks[positionKey] = encryptedCurrentTick;

        ebool encryptedNeedsWithdrawal = FHE.asEbool(true);
        euint32 encryptedTime = FHE.asEuint32(uint32(block.timestamp));

        emit EncryptedLiquiditySignal(
            positionKey,
            abi.encode(encryptedNeedsWithdrawal, encryptedTime)
        );
    }

    function _preparePreSwap(
        bytes32 positionKey,
        int24 currentTick,
        address token0,
        address token1
    ) internal {
        bool success = liquidityOrchestrator.preparePreSwapLiquidity(
            positionKey,
            currentTick,
            token0,
            token1
        );
        if (!success) {
            revert PreSwapLiquidityPreparationFailed();
        }
    }

    function _emitEncryptedWithdrawalPrepared(bytes32 positionKey) internal {
        euint32 encryptedSuccess = FHE.asEuint32(1);
        emit EncryptedWithdrawalPrepared(
            positionKey,
            abi.encode(encryptedSuccess)
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        (, int24 newTick, , ) = poolManager.getSlot0(key.toId());
        int24 oldTick = lastActiveTick;

        (int24 lowerTick, int24 upperTick) = _decryptHookData(hookData);
        bytes32 positionKey = _generatePositionKey(key, lowerTick, upperTick);

        // Split into smaller functions to reduce stack depth
        _handleSwapStateUpdates(
            key,
            params,
            delta,
            positionKey,
            oldTick,
            newTick,
            lowerTick,
            upperTick
        );

        _emitSwapEvents(positionKey, oldTick, newTick, params.zeroForOne);

        return (this.afterSwap.selector, 0);
    }

    function _handleSwapStateUpdates(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes32 positionKey,
        int24 oldTick,
        int24 newTick,
        int24 lowerTick,
        int24 upperTick
    ) internal {
        ILiquidityOrchestrator.PositionData
            memory position = liquidityOrchestrator.getPosition(positionKey);
        require(position.exists, "Position must exist");

        // Update reserves first
        _updatePositionReserves(position, positionKey, params, delta);

        // Check and handle rebalancing
        bool shouldRebalance = liquidityOrchestrator
            .checkPostSwapLiquidityNeeds(positionKey, oldTick, newTick);

        if (shouldRebalance) {
            _handleRebalancing(
                key,
                positionKey,
                oldTick,
                newTick,
                lowerTick,
                upperTick
            );
        }
    }

    function _updatePositionReserves(
        ILiquidityOrchestrator.PositionData memory position,
        bytes32 positionKey,
        SwapParams calldata params,
        BalanceDelta delta
    ) internal {
        (uint256 reserveAmount0, ) = FHE.getDecryptResultSafe(
            position.reserveAmount0
        );
        (uint256 reserveAmount1, ) = FHE.getDecryptResultSafe(
            position.reserveAmount1
        );

        if (params.zeroForOne) {
            (reserveAmount0, reserveAmount1) = _updateReservesZeroForOne(
                reserveAmount0,
                reserveAmount1,
                delta
            );
        } else {
            (reserveAmount0, reserveAmount1) = _updateReservesOneForZero(
                reserveAmount0,
                reserveAmount1,
                delta
            );
        }

        liquidityOrchestrator.updateReserves(
            positionKey,
            reserveAmount0,
            reserveAmount1
        );
    }

    function _updateReservesZeroForOne(
        uint256 reserve0,
        uint256 reserve1,
        BalanceDelta delta
    ) internal pure returns (uint256, uint256) {
        uint256 amount0In = delta.amount0() < 0
            ? uint256(int256(-delta.amount0()))
            : 0;
        uint256 amount1Out = delta.amount1() > 0
            ? uint256(int256(delta.amount1()))
            : 0;

        reserve0 += amount0In;
        reserve1 = reserve1 > amount1Out ? reserve1 - amount1Out : 0;

        return (reserve0, reserve1);
    }

    function _updateReservesOneForZero(
        uint256 reserve0,
        uint256 reserve1,
        BalanceDelta delta
    ) internal pure returns (uint256, uint256) {
        uint256 amount1In = delta.amount1() < 0
            ? uint256(int256(-delta.amount1()))
            : 0;
        uint256 amount0Out = delta.amount0() > 0
            ? uint256(int256(delta.amount0()))
            : 0;

        reserve1 += amount1In;
        reserve0 = reserve0 > amount0Out ? reserve0 - amount0Out : 0;

        return (reserve0, reserve1);
    }

    function _handleRebalancing(
        PoolKey calldata key,
        bytes32 positionKey,
        int24 oldTick,
        int24 newTick,
        int24 lowerTick,
        int24 upperTick
    ) internal {
        require(
            oldTick >= lowerTick && oldTick <= upperTick,
            "Invalid old tick range"
        );
        require(
            newTick < lowerTick || newTick > upperTick,
            "New tick should be out of range"
        );

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        bool success = liquidityOrchestrator.executePostSwapManagement(
            positionKey,
            oldTick,
            newTick,
            token0,
            token1
        );
        if (!success) {
            revert PostSwapManagementFailed();
        }

        ILiquidityOrchestrator.PositionData
            memory finalPosition = liquidityOrchestrator.getPosition(
                positionKey
            );
        require(
            finalPosition.state == ILiquidityOrchestrator.PositionState.IN_AAVE,
            "Position should be in Aave after out-of-range swap"
        );
    }

    function _emitSwapEvents(
        bytes32 positionKey,
        int24 oldTick,
        int24 newTick,
        bool zeroForOne
    ) internal {
        emit EncryptedRebalancingDecision(
            positionKey,
            abi.encode(
                FHE.asEuint32(uint32(int32(oldTick))),
                FHE.asEuint32(uint32(int32(newTick))),
                FHE.asEbool(zeroForOne),
                FHE.asEuint32(0), // Delta amounts set to 0 for privacy
                FHE.asEuint32(0),
                FHE.asEbool(true)
            )
        );

        emit EncryptedPostSwapCompleted(
            positionKey,
            abi.encode(FHE.asEuint32(1))
        );
    }

    /**
     * @dev Generates a unique position key based on the pool key and owner address
     * @param key The pool key
     * @param lowerTick The lower tick of the position
     * @param upperTick The upper tick of the position
     * @return positionKey The generated position key
     */
    function _generatePositionKey(
        PoolKey calldata key,
        int24 lowerTick,
        int24 upperTick
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(key.toId(), lowerTick, upperTick));
    }
}
