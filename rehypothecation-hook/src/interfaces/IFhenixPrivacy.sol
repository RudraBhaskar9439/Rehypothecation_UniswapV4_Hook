// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@fhenixprotocol/contracts/FHE.sol";

interface IFhenixPrivacy {
    // Events for encrypted operations
    event EncryptedReservePercentageSet(bytes32 indexed positionKey, bytes encryptedPercentage);
    event EncryptedTickStored(bytes32 indexed positionKey, bytes encryptedTick);
    event EncryptedCalculationPerformed(bytes32 indexed positionKey, string operation);
    
    // Functions for encrypted reserve percentage management
    function setEncryptedReservePercentage(bytes32 positionKey, bytes calldata encryptedPercentage) external;
    function getEncryptedReservePercentage(bytes32 positionKey) external view returns (bytes memory);
    
    // Functions for encrypted tick management
    function storeEncryptedTick(bytes32 positionKey, bytes calldata encryptedTick) external;
    function getEncryptedTick(bytes32 positionKey) external view returns (bytes memory);
    
    // Functions for encrypted range detection
    function isEncryptedOutOfRange(
        bytes32 positionKey, 
        bytes calldata encryptedCurrentTick
    ) external view returns (bytes memory);
    
    // Functions for encrypted liquidity movement triggers
    function shouldTriggerLiquidityMovement(
        bytes32 positionKey,
        bytes calldata encryptedOldTick,
        bytes calldata encryptedNewTick
    ) external view returns (bytes memory);
}