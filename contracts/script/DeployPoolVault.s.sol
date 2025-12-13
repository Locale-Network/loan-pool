// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PoolVault} from "../src/Vault/PoolVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployPoolVault
/// @notice Script to deploy PoolVault with UUPS proxy pattern
/// @dev Run with: forge script script/DeployPoolVault.s.sol:DeployPoolVaultScript --broadcast --verify
contract DeployPoolVaultScript is Script {
    function run() external {
        // Read deployment configuration from environment
        address admin = vm.envAddress("POOL_VAULT_ADMIN");
        address asset = vm.envAddress("POOL_VAULT_ASSET"); // USDC address
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        string memory poolName = vm.envString("POOL_NAME");
        string memory poolSymbol = vm.envString("POOL_SYMBOL");
        string memory poolType = vm.envString("POOL_TYPE");

        vm.startBroadcast();

        // Deploy implementation
        PoolVault implementation = new PoolVault();
        console.log("PoolVault Implementation deployed at:", address(implementation));

        // Encode initialize call
        bytes memory initData = abi.encodeWithSelector(
            PoolVault.initialize.selector,
            IERC20(asset),
            poolName,
            poolSymbol,
            poolType,
            admin,
            feeRecipient
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        console.log("PoolVault Proxy deployed at:", address(proxy));

        vm.stopBroadcast();

        // Save deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("Implementation:", address(implementation));
        console.log("Proxy:", address(proxy));
        console.log("Admin:", admin);
        console.log("Asset:", asset);
        console.log("Pool Name:", poolName);
        console.log("Pool Type:", poolType);
    }
}
