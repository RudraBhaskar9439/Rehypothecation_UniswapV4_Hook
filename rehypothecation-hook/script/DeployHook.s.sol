// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RehypothecationHooks} from "../src/hooks/RehypothecationHooks.sol";
import {LiquidityOrchestrator} from "../src/LiquidityOrchestrator.sol";
import {IAave} from "../src/interfaces/IAave.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Deployintegration} from "./Deployintegration.s.sol";

contract DeployHook is Script {
    // Replace with your actual PoolManager addresses
    address constant ANVIL_POOL_MANAGER =
        0x0000000000000000000000000000000000000001;
    address constant SEPOLIA_POOL_MANAGER =
        0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    function run() external returns (address hookAddr) {
        // By default, deploy to Sepolia
        return deploySepoliaHook();
    }

    function deploySepoliaHook() public returns (address hookAddr) {
        // Deploy Aave and LiquidityOrchestrator using Deployintegration
        Deployintegration integration = new Deployintegration();
        (address aaveAddr, address orchestratorAddr) = integration
            .deploySepolia();

        vm.startBroadcast();

        RehypothecationHooks hook = new RehypothecationHooks(
            IPoolManager(SEPOLIA_POOL_MANAGER),
            IAave(aaveAddr),
            LiquidityOrchestrator(orchestratorAddr)
        );

        vm.stopBroadcast();

        // Log deployed addresses
        console.log("Deployed Aave at:", aaveAddr);
        console.log("Deployed Orchestrator at:", orchestratorAddr);
        console.log("Deployed Hook at:", address(hook));

        return address(hook);
    }

    function deployAnvilHook() public returns (address hookAddr) {
        // Deploy Aave and LiquidityOrchestrator using Deployintegration
        Deployintegration integration = new Deployintegration();
        (address aaveAddr, address orchestratorAddr) = integration
            .deployAnvil();

        vm.startBroadcast();

        RehypothecationHooks hook = new RehypothecationHooks(
            IPoolManager(ANVIL_POOL_MANAGER),
            IAave(aaveAddr),
            LiquidityOrchestrator(orchestratorAddr)
        );

        vm.stopBroadcast();
        return address(hook);
    }
}
