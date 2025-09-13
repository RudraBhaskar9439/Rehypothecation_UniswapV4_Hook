// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@fhenixprotocol/contracts/FHE.sol";
import "./interfaces/IFhenixPrivacy.sol";
import "./interfaces/ILiquidityOrchestrator.sol";

contract FhenixPrivacyManager is IFhenixPrivacy {
    // Encrypted storage
    mapping(bytes32 => euint32) private encryptedReservePercentages;
    mapping(bytes32 => euint32) private encryptedTicks;
    mapping(bytes32 => euint32) private encryptedTickLower;
    mapping(bytes32 => euint32) private encryptedTickUpper;
    
    ILiquidityOrchestrator public immutable liquidityOrchestrator;
    
    constructor(address _liquidityOrchestrator) {
        liquidityOrchestrator = ILiquidityOrchestrator(_liquidityOrchestrator);
    }
    
    function setEncryptedReservePercentage(bytes32 positionKey, bytes calldata encryptedPercentage) external override {
        encryptedReservePercentages[positionKey] = FHE.asEuint32(encryptedPercentage, 0);
        emit EncryptedReservePercentageSet(positionKey, encryptedPercentage);
    }
    
    function getEncryptedReservePercentage(bytes32 positionKey) external view override returns (bytes memory) {
        return FHE.asEuint32(encryptedReservePercentages[positionKey], bytes32(0));
    }
    
    function storeEncryptedTick(bytes32 positionKey, bytes calldata encryptedTick) external override {
        encryptedTicks[positionKey] = FHE.asEuint32(encryptedTick, 0);
        emit EncryptedTickStored(positionKey, encryptedTick);
    }
    
    function getEncryptedTick(bytes32 positionKey) external view override returns (bytes memory) {
        return FHE.asEuint32(encryptedTicks[positionKey]);
    }
    
    function isEncryptedOutOfRange(
        bytes32 positionKey, 
        bytes calldata encryptedCurrentTick
    ) external view override returns (bytes memory) {
        euint32 currentTick = FHE.asEuint32(encryptedCurrentTick, 0);
        euint32 tickLower = encryptedTickLower[positionKey];
        euint32 tickUpper = encryptedTickUpper[positionKey];
        
        // Encrypted out-of-range check: currentTick < tickLower || currentTick > tickUpper
        ebool belowLower = FHE.lt(currentTick, tickLower);
        ebool aboveUpper = FHE.gt(currentTick, tickUpper);
        ebool outOfRange = belowLower | aboveUpper;
        return FHE.asEuint32(outOfRange);
    }
    
    function shouldTriggerLiquidityMovement(
        bytes32 positionKey,
        bytes calldata encryptedOldTick,
        bytes calldata encryptedNewTick
    ) external view override returns (bytes memory) {
        euint32 oldTick = FHE.asEuint32(encryptedOldTick, 0);
        euint32 newTick = FHE.asEuint32(encryptedNewTick, 0);
        euint32 tickLower = encryptedTickLower[positionKey];
        euint32 tickUpper = encryptedTickUpper[positionKey];
        
        // Encrypted logic: wasInRange && !currentlyInRange
        ebool wasInRange = (FHE.gt(oldTick, tickLower) | FHE.eq(oldTick, tickLower)) & 
                   (FHE.lt(oldTick, tickUpper) | FHE.eq(oldTick, tickUpper));
        ebool currentlyInRange = (FHE.gt(newTick, tickLower) | FHE.eq(newTick, tickLower)) & 
                         (FHE.lt(newTick, tickUpper) | FHE.eq(newTick, tickUpper));
        ebool shouldTrigger = wasInRange & FHE.not(currentlyInRange);
        
        emit EncryptedCalculationPerformed(positionKey, "shouldTriggerLiquidityMovement");
        return FHE.asEuint32(shouldTrigger);
    }
    
    // Helper function to set encrypted tick ranges
    function setEncryptedTickRange(
        bytes32 positionKey,
        bytes calldata encryptedLowerTick,
        bytes calldata encryptedUpperTick
    ) external {
        encryptedTickLower[positionKey] = FHE.asEuint32(encryptedLowerTick, 0);
        encryptedTickUpper[positionKey] = FHE.asEuint32(encryptedUpperTick, 0);
    }
}