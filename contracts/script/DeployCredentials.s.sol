// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {BorrowerCredential} from "../src/Credentials/BorrowerCredential.sol";
import {InvestorCredential} from "../src/Credentials/InvestorCredential.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployCredentials
/// @notice Script to deploy both BorrowerCredential and InvestorCredential contracts
/// @dev Run with: forge script script/DeployCredentials.s.sol:DeployCredentialsScript --broadcast --verify
contract DeployCredentialsScript is Script {
    function run() external {
        address admin = vm.envAddress("CREDENTIALS_ADMIN");

        vm.startBroadcast();

        // Deploy BorrowerCredential
        console.log("\n=== Deploying BorrowerCredential ===");
        BorrowerCredential borrowerImpl = new BorrowerCredential();
        console.log("BorrowerCredential Implementation:", address(borrowerImpl));

        bytes memory borrowerInitData = abi.encodeWithSelector(
            BorrowerCredential.initialize.selector,
            admin
        );

        ERC1967Proxy borrowerProxy = new ERC1967Proxy(
            address(borrowerImpl),
            borrowerInitData
        );
        console.log("BorrowerCredential Proxy:", address(borrowerProxy));

        // Deploy InvestorCredential
        console.log("\n=== Deploying InvestorCredential ===");
        InvestorCredential investorImpl = new InvestorCredential();
        console.log("InvestorCredential Implementation:", address(investorImpl));

        bytes memory investorInitData = abi.encodeWithSelector(
            InvestorCredential.initialize.selector,
            admin
        );

        ERC1967Proxy investorProxy = new ERC1967Proxy(
            address(investorImpl),
            investorInitData
        );
        console.log("InvestorCredential Proxy:", address(investorProxy));

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("Admin:", admin);
        console.log("\nBorrowerCredential:");
        console.log("  Implementation:", address(borrowerImpl));
        console.log("  Proxy:", address(borrowerProxy));
        console.log("\nInvestorCredential:");
        console.log("  Implementation:", address(investorImpl));
        console.log("  Proxy:", address(investorProxy));

        console.log("\n=== Add to .env ===");
        console.log("BORROWER_CREDENTIAL_ADDRESS=", address(borrowerProxy));
        console.log("INVESTOR_CREDENTIAL_ADDRESS=", address(investorProxy));
    }
}
