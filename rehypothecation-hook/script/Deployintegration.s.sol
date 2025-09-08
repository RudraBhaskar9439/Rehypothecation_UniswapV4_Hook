//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Aave} from "../src/Aave.sol";
import {LiquidityOrchestrator} from "../src/LiquidityOrchestrator.sol";

contract Deployintegration is Script {
    // Replace with the actual LendingPool addresses for each network
    address constant ANVIL_LENDING_POOL = 0x387d311e47e80b498169e6fb51d3193167d89F7D; // Dummy for local
    address constant SEPOLIA_LENDING_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951; // <-- Put Sepolia Aave pool address here

    function deployAnvil() external returns (address aaveAddr, address orchestratorAddr) {
        vm.startBroadcast();

        // Deploy Aave contract with local LendingPool address
        Aave aave = new Aave(ANVIL_LENDING_POOL);

        // Deploy LiquidityOrchestrator with Aave contract address
        LiquidityOrchestrator orchestrator = new LiquidityOrchestrator(address(aave));

        vm.stopBroadcast();

        return (address(aave), address(orchestrator));
    }

    function deploySepolia() external returns (address aaveAddr, address orchestratorAddr) {
        vm.startBroadcast();

        // Deploy Aave contract with Sepolia LendingPool address
        Aave aave = new Aave(SEPOLIA_LENDING_POOL);

        // Deploy LiquidityOrchestrator with Aave contract address
        LiquidityOrchestrator orchestrator = new LiquidityOrchestrator(address(aave));

        vm.stopBroadcast();

        return (address(aave), address(orchestrator));
    }
}