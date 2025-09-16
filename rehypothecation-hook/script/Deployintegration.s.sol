pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Aave} from "../src/Aave.sol";
import {LiquidityOrchestrator} from "../src/LiquidityOrchestrator.sol";

contract Deployintegration is Script {
    // Aave V3 Sepolia Addresses
    address constant SEPOLIA_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951; // Aave V3 Pool
    address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // USDC on Sepolia
    address constant SEPOLIA_WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9; // WETH on Sepolia

    function deploySepolia()
        external
        returns (address aaveAddr, address orchestratorAddr)
    {
        vm.startBroadcast();

        // Deploy Aave contract with Sepolia Pool address
        Aave aave = new Aave(SEPOLIA_POOL);

        // Deploy LiquidityOrchestrator with Aave contract address
        LiquidityOrchestrator orchestrator = new LiquidityOrchestrator(
            address(aave)
        );

        vm.stopBroadcast();

        return (address(aave), address(orchestrator));
    }

    function deployAnvil ()
        external
        pure
        returns (address aaveAddr, address orchestratorAddr)
    {
        // Implement as needed, or return dummy addresses for now
        return (address(0), address(0));
    }
}
