// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {IRehypothecationHook} from "../interfaces/IRehypothecationHook.sol";
import {IAave} from "../interfaces/IAave.sol";
import {Constant} from "../utils/Constant.sol";

abstract contract RehypothecationHook is IRehypothecationHook {
    // State Vairable 
    IAave public immutable aavePool;
    mapping(uint256 => PositionData) public positions;
    mapping(uint256=> uint256) public emergencyWithdrawlTimestamps;

    // Owner
    address public owner;

     // Events
    event HookInitialized(address indexed aavePool);
    event ReservePercentageUpdated(uint256 indexed tokenId, uint256 oldPercentage, uint256 newPercentage);
    event EmergencyWithdrawalTriggered(
        address indexed caller,
        uint256 indexed tokenId,
        address asset,
        uint256 amount,
        uint256 timestamp
    );

/**
 *@dev This constructor:Takes the Aave Pool contract as input.
 * Stores it in the contract state (aavePool).
 * Records the deployer as the owner.
 * Emits an event to signal that the hook/contract was initialized with a specific Aave pool. 
 */
    constructor(IAave _aavePool) {
        aavePool = _aavaPool;
        owner = msg.sender;

        emit HookInitialized(address(_aavePool));
    }

    modifier onlyOwner() {
        require(msg.sender == owner,"Only Owner");
        _;
    }

    /**
     * @dev Hook called before a swap to ensure sufficient liquidity
     */

     function beforeSwap(
        address sender,
        address recipient,
        bytes calldata hookData
     ) external returns (bytes4) 
     {

     }
    


}
