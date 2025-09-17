// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {RehypothecationHooks} from "../src/hooks/RehypothecationHooks.sol";
import {LiquidityOrchestrator} from "../src/LiquidityOrchestrator.sol";
import {MockAave} from "../test/MockAave.sol";
import {Aave} from "../src/Aave.sol";
import {IAave} from "../src/interfaces/IAave.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {ILiquidityOrchestrator} from "../src/interfaces/ILiquidityOrchestrator.sol";

contract DeployToSepolia is Script {
    // Sepolia Uniswap V4 PoolManager address
    // Note: Replace with actual Sepolia V4 PoolManager when available
    address constant SEPOLIA_POOL_MANAGER = 0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A;

    // CREATE2 Deployer address (standard across most chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Sepolia Aave V3 Pool address (if you want to use real Aave)
    address constant SEPOLIA_AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;

    function setUp() public {}

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Define the hook flags that your RehypothecationHooks contract implements
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
        );

        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying to Sepolia...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));

        // Deploy contracts in correct order and mine hook address
        (address aaveAddr, address orchestratorAddr, address hookAddr) = deployContracts(flags);

        vm.stopBroadcast();

        // Log all deployed addresses
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Aave (Mock):", aaveAddr);
        console.log("LiquidityOrchestrator:", orchestratorAddr);
        console.log("RehypothecationHooks:", hookAddr);
        console.log("==========================");

        // Save addresses to file for verification
        saveDeploymentAddresses(aaveAddr, orchestratorAddr, hookAddr);
    }

    function deployContracts(uint160 flags)
        internal
        returns (address aaveAddr, address orchestratorAddr, address hookAddr)
    {
        // 1. Deploy MockAave (since we're on testnet)
        console.log("Deploying MockAave...");
        MockAave mockAave = new MockAave();
        aaveAddr = address(mockAave);
        console.log("MockAave deployed at:", aaveAddr);

        // 2. Deploy LiquidityOrchestrator
        console.log("Deploying LiquidityOrchestrator...");
        LiquidityOrchestrator orchestrator = new LiquidityOrchestrator(aaveAddr);
        orchestratorAddr = address(orchestrator);
        console.log("LiquidityOrchestrator deployed at:", orchestratorAddr);

        // 3. Mine the correct hook address
        console.log("Mining hook address...");
        bytes memory constructorArgs = abi.encode(SEPOLIA_POOL_MANAGER, aaveAddr, orchestratorAddr);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(RehypothecationHooks).creationCode, constructorArgs);

        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        // 4. Deploy RehypothecationHooks using CREATE2 with the mined salt
        console.log("Deploying RehypothecationHooks...");
        RehypothecationHooks hook = new RehypothecationHooks{salt: salt}(
            IPoolManager(SEPOLIA_POOL_MANAGER), IAave(aaveAddr), ILiquidityOrchestrator(orchestratorAddr)
        );

        // Verify the deployed address matches the mined address
        require(address(hook) == hookAddress, "DeployToSepolia: hook address mismatch");
        hookAddr = address(hook);
        console.log("RehypothecationHooks deployed at:", hookAddr);

        return (aaveAddr, orchestratorAddr, hookAddr);
    }

    function saveDeploymentAddresses(address aave, address orchestrator, address hook) internal {
        string memory json = string(
            abi.encodePacked(
                "{\n",
                '  "network": "sepolia",\n',
                '  "chainId": 11155111,\n',
                '  "deployedAt": "',
                vm.toString(block.timestamp),
                '",\n',
                '  "contracts": {\n',
                '    "MockAave": "',
                vm.toString(aave),
                '",\n',
                '    "LiquidityOrchestrator": "',
                vm.toString(orchestrator),
                '",\n',
                '    "RehypothecationHooks": "',
                vm.toString(hook),
                '"\n',
                "  }\n",
                "}"
            )
        );
    }
}
