// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EligibilityRegistry} from "../src/Compliance/EligibilityRegistry.sol";

/// @title DeployEligibilityRegistry
/// @notice Deploys EligibilityRegistry behind a UUPS proxy
contract DeployEligibilityRegistry is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        EligibilityRegistry impl = new EligibilityRegistry();
        console.log("Implementation:", address(impl));

        // Deploy proxy with initialize(admin, maxNonAccredited=35)
        bytes memory initData = abi.encodeWithSelector(
            EligibilityRegistry.initialize.selector,
            deployer,
            35
        );
        address proxy = address(new ERC1967Proxy(address(impl), initData));
        console.log("Proxy:", proxy);

        // Grant POOL_ROLE to StakingPool so it can call markAsInvested
        address stakingPool = vm.envAddress("STAKING_POOL_ADDRESS");
        EligibilityRegistry(proxy).grantRole(
            EligibilityRegistry(proxy).POOL_ROLE(),
            stakingPool
        );
        console.log("Granted POOL_ROLE to StakingPool:", stakingPool);

        vm.stopBroadcast();
    }
}
