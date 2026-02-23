// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {CreditTreasuryPool} from "../src/Loan/CreditTreasuryPool.sol";
import {StakingPool} from "../src/Staking/StakingPool.sol";
import {BorrowerCredential} from "../src/Credentials/BorrowerCredential.sol";
import {InvestorCredential} from "../src/Credentials/InvestorCredential.sol";

/// @title GrantRoles - Post-deployment role assignment
/// @notice Grants operational roles to Privy server wallets and EOA operators
/// @dev Run AFTER DeployAll.s.sol with contract addresses set in .env
contract GrantRolesScript is Script {
    // CreditTreasuryPool roles
    bytes32 constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 constant SYSTEM_ROLE = keccak256("SYSTEM_ROLE");
    bytes32 constant APPROVER_ROLE = keccak256("APPROVER_ROLE");

    // StakingPool roles
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Credential roles
    bytes32 constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Wallet addresses from .env
        address loanOpsWallet = vm.envAddress("LOAN_OPS_WALLET_ADDRESS");
        address poolAdminWallet = vm.envAddress("POOL_ADMIN_WALLET_ADDRESS");
        address relayOperator = vm.envAddress("RELAY_OPERATOR_ADDRESS");
        address credentialIssuer = vm.envAddress("CREDENTIAL_ISSUER_ADDRESS");

        // Contract addresses (set these after DeployAll)
        address creditTreasuryPool = vm.envAddress("CREDIT_TREASURY_POOL_ADDRESS");
        address stakingPool = vm.envAddress("STAKING_POOL_ADDRESS");
        address borrowerCredential = vm.envAddress("BORROWER_CREDENTIAL_ADDRESS");
        address investorCredential = vm.envAddress("INVESTOR_CREDENTIAL_ADDRESS");

        console.log("===========================================");
        console.log("  Locale Lending - Role Assignment");
        console.log("===========================================");
        console.log("Deployer:", deployer);
        console.log("");
        console.log("Loan Ops Wallet:", loanOpsWallet);
        console.log("Pool Admin Wallet:", poolAdminWallet);
        console.log("Relay Operator:", relayOperator);
        console.log("Credential Issuer:", credentialIssuer);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // =========================================
        // 1. CreditTreasuryPool roles
        // =========================================
        console.log("1. CreditTreasuryPool roles...");
        CreditTreasuryPool pool = CreditTreasuryPool(creditTreasuryPool);

        // Loan Ops wallet: creates loans, activates, records repayments
        pool.grantRole(POOL_MANAGER_ROLE, loanOpsWallet);
        console.log("   Granted POOL_MANAGER_ROLE to Loan Ops");

        pool.grantRole(APPROVER_ROLE, loanOpsWallet);
        console.log("   Granted APPROVER_ROLE to Loan Ops");

        pool.grantRole(SYSTEM_ROLE, loanOpsWallet);
        console.log("   Granted SYSTEM_ROLE to Loan Ops");

        // Set relay service for Cartesi notice handling
        pool.setRelayService(relayOperator);
        console.log("   Set relay service to:", relayOperator);

        // =========================================
        // 2. StakingPool roles
        // =========================================
        console.log("");
        console.log("2. StakingPool roles...");
        StakingPool sp = StakingPool(stakingPool);

        // Pool Admin wallet: pool deployment, yield distribution, cooldown management
        sp.grantRole(POOL_MANAGER_ROLE, poolAdminWallet);
        console.log("   Granted POOL_MANAGER_ROLE to Pool Admin");

        // Loan Ops wallet: transferToLoanPool, distributeYield
        sp.grantRole(POOL_MANAGER_ROLE, loanOpsWallet);
        console.log("   Granted POOL_MANAGER_ROLE to Loan Ops");

        // =========================================
        // 3. Credential roles
        // =========================================
        console.log("");
        console.log("3. Credential roles...");

        // Credential Issuer: mints KYC/accreditation SBTs
        BorrowerCredential bc = BorrowerCredential(borrowerCredential);
        bc.grantRole(ISSUER_ROLE, credentialIssuer);
        console.log("   Granted ISSUER_ROLE on BorrowerCredential to Credential Issuer");

        InvestorCredential ic = InvestorCredential(investorCredential);
        ic.grantRole(ISSUER_ROLE, credentialIssuer);
        console.log("   Granted ISSUER_ROLE on InvestorCredential to Credential Issuer");

        vm.stopBroadcast();

        // =========================================
        // Summary
        // =========================================
        console.log("");
        console.log("===========================================");
        console.log("  Role Assignment Complete!");
        console.log("===========================================");
        console.log("");
        console.log("Deployer retains: owner, DEFAULT_ADMIN_ROLE, POOL_MANAGER_ROLE, APPROVER_ROLE");
        console.log("Loan Ops Wallet: POOL_MANAGER_ROLE + APPROVER_ROLE + SYSTEM_ROLE (CTP), POOL_MANAGER_ROLE (SP)");
        console.log("Pool Admin Wallet: POOL_MANAGER_ROLE (SP)");
        console.log("Relay Operator: relayService on CTP");
        console.log("Credential Issuer: ISSUER_ROLE on BC + IC");
    }
}
