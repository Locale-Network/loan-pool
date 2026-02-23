// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {CreditTreasuryPool} from "../src/Loan/CreditTreasuryPool.sol";

/// @dev Minimal interface for UUPSUpgradeable proxy
interface IUUPSProxy {
    function upgradeToAndCall(address newImplementation, bytes memory data) external;
}

/// @dev Minimal interface for OwnableUpgradeable
interface IOwnable {
    function owner() external view returns (address);
}

/// @title UpgradeCreditTreasuryPool
/// @notice Deploys a new CreditTreasuryPool implementation and upgrades the UUPS proxy
/// @dev The proxy's _authorizeUpgrade is gated by onlyOwner, so the deployer EOA must be owner
contract UpgradeCreditTreasuryPoolScript is Script {
    function run() external {
        // Read proxy address and deployer key from environment
        address proxy = vm.envAddress("NEXT_PUBLIC_LOAN_POOL_ADDRESS");
        uint256 deployerPrivateKey = block.chainid == 31_337
            ? vm.envUint("ANVIL_PRIVATE_KEY")
            : vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("===========================================");
        console.log("  CreditTreasuryPool UUPS Upgrade");
        console.log("===========================================");
        console.log("Proxy:      ", proxy);
        console.log("Deployer:   ", deployer);
        console.log("Chain ID:   ", block.chainid);
        console.log("");

        // Pre-flight: verify deployer is owner
        address currentOwner = IOwnable(proxy).owner();
        require(currentOwner == deployer, "Deployer is not proxy owner");
        console.log("Pre-flight: deployer is owner. OK");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new implementation
        console.log("1. Deploying new CreditTreasuryPool implementation...");
        address newImpl = address(new CreditTreasuryPool());
        console.log("   New implementation:", newImpl);

        // 2. Upgrade proxy to new implementation (no additional init call needed)
        console.log("");
        console.log("2. Upgrading proxy...");
        IUUPSProxy(proxy).upgradeToAndCall(newImpl, "");
        console.log("   Proxy upgraded successfully");

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("  Upgrade Complete!");
        console.log("===========================================");
        console.log("");
        console.log("New implementation:", newImpl);
        console.log("Proxy (unchanged):", proxy);
        console.log("");
        console.log("Verify with:");
        console.log("  cast call", proxy, "\"makePartialRepayment(bytes32,uint256)\" <loanId> <amount>");
    }
}
