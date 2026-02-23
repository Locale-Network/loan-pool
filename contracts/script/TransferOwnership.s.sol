// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev Minimal interface for OwnableUpgradeable
interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @title TransferOwnership - Multi-Sig Migration Script
/// @notice Transfers ownership and DEFAULT_ADMIN_ROLE from deployer EOA to a Gnosis Safe
/// @dev Run once after contracts are deployed. The deployer keeps POOL_MANAGER_ROLE
///      and APPROVER_ROLE so the backend continues to work.
///
///      Order of operations (critical):
///      1. Grant roles to Safe
///      2. Transfer ownership to Safe
///      3. Revoke admin roles from deployer
///      If reversed, the deployer loses ability to complete the migration.
contract TransferOwnershipScript is Script {
    // Gnosis Safe address
    address constant SAFE = 0xA117a8f511EC2f3d2bB5ffcffcBe3F0Fc2d4a299;

    // Role constants (must match contract definitions)
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 constant APPROVER_ROLE = keccak256("APPROVER_ROLE");
    bytes32 constant SYSTEM_ROLE = keccak256("SYSTEM_ROLE");
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    function run() external {
        // Read contract addresses from environment
        address creditTreasuryPool = vm.envAddress("NEXT_PUBLIC_LOAN_POOL_ADDRESS");
        address stakingPool = vm.envAddress("NEXT_PUBLIC_STAKING_POOL_ADDRESS");

        // Read deployer key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("===========================================");
        console.log("  Multi-Sig Ownership Transfer");
        console.log("===========================================");
        console.log("Deployer (current owner):", deployer);
        console.log("Safe (new owner):        ", SAFE);
        console.log("CreditTreasuryPool:      ", creditTreasuryPool);
        console.log("StakingPool:             ", stakingPool);
        console.log("Chain ID:                ", block.chainid);
        console.log("");

        // Pre-flight checks
        _preflight(creditTreasuryPool, stakingPool, deployer);

        vm.startBroadcast(deployerPrivateKey);

        // =============================================
        // Step 1: Grant DEFAULT_ADMIN_ROLE to Safe
        // =============================================
        console.log("Step 1: Granting DEFAULT_ADMIN_ROLE to Safe...");

        IAccessControl(creditTreasuryPool).grantRole(DEFAULT_ADMIN_ROLE, SAFE);
        console.log("   CreditTreasuryPool: DEFAULT_ADMIN_ROLE granted to Safe");

        IAccessControl(stakingPool).grantRole(DEFAULT_ADMIN_ROLE, SAFE);
        console.log("   StakingPool: DEFAULT_ADMIN_ROLE granted to Safe");

        // =============================================
        // Step 2: Grant UPGRADER_ROLE to Safe on StakingPool
        // =============================================
        console.log("");
        console.log("Step 2: Granting UPGRADER_ROLE to Safe on StakingPool...");

        IAccessControl(stakingPool).grantRole(UPGRADER_ROLE, SAFE);
        console.log("   StakingPool: UPGRADER_ROLE granted to Safe");

        // =============================================
        // Step 3: Transfer ownership to Safe
        // =============================================
        console.log("");
        console.log("Step 3: Transferring ownership to Safe...");

        IOwnable(creditTreasuryPool).transferOwnership(SAFE);
        console.log("   CreditTreasuryPool: ownership transferred to Safe");

        IOwnable(stakingPool).transferOwnership(SAFE);
        console.log("   StakingPool: ownership transferred to Safe");

        // =============================================
        // Step 4: Revoke admin roles from deployer
        // =============================================
        console.log("");
        console.log("Step 4: Revoking admin roles from deployer...");

        // Revoke DEFAULT_ADMIN_ROLE from deployer on both contracts
        // The Safe now holds this role and can re-grant if needed
        IAccessControl(creditTreasuryPool).revokeRole(DEFAULT_ADMIN_ROLE, deployer);
        console.log("   CreditTreasuryPool: DEFAULT_ADMIN_ROLE revoked from deployer");

        IAccessControl(stakingPool).revokeRole(DEFAULT_ADMIN_ROLE, deployer);
        console.log("   StakingPool: DEFAULT_ADMIN_ROLE revoked from deployer");

        // Revoke UPGRADER_ROLE from deployer on StakingPool
        IAccessControl(stakingPool).revokeRole(UPGRADER_ROLE, deployer);
        console.log("   StakingPool: UPGRADER_ROLE revoked from deployer");

        vm.stopBroadcast();

        // =============================================
        // Post-migration verification
        // =============================================
        console.log("");
        console.log("===========================================");
        console.log("  Verification");
        console.log("===========================================");
        _verify(creditTreasuryPool, stakingPool, deployer);

        console.log("");
        console.log("===========================================");
        console.log("  Migration Complete!");
        console.log("===========================================");
        console.log("");
        console.log("Deployer retains:");
        console.log("  - POOL_MANAGER_ROLE on both contracts (backend operations)");
        console.log("  - APPROVER_ROLE on CreditTreasuryPool (loan approvals)");
        console.log("");
        console.log("Safe now controls:");
        console.log("  - Contract ownership (upgrades on CreditTreasuryPool)");
        console.log("  - DEFAULT_ADMIN_ROLE (role management)");
        console.log("  - UPGRADER_ROLE on StakingPool (upgrades)");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("  1. Generate separate EOA keys for POOL_ADMIN and CARTESI");
        console.log("  2. Via the Safe, grant POOL_MANAGER_ROLE to new keys");
        console.log("  3. Update .env with new keys");
        console.log("  4. Revoke POOL_MANAGER_ROLE from old deployer (via Safe)");
    }

    /// @dev Pre-flight checks before migration
    function _preflight(address creditTreasuryPool, address stakingPool, address deployer) internal view {
        // Verify deployer is current owner
        require(
            IOwnable(creditTreasuryPool).owner() == deployer,
            "Deployer is not CreditTreasuryPool owner"
        );
        require(
            IOwnable(stakingPool).owner() == deployer,
            "Deployer is not StakingPool owner"
        );

        // Verify deployer has DEFAULT_ADMIN_ROLE
        require(
            IAccessControl(creditTreasuryPool).hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "Deployer missing DEFAULT_ADMIN_ROLE on CreditTreasuryPool"
        );
        require(
            IAccessControl(stakingPool).hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "Deployer missing DEFAULT_ADMIN_ROLE on StakingPool"
        );

        // Verify Safe is not zero address
        require(SAFE != address(0), "Safe address is zero");

        // Verify Safe is not already owner
        require(
            IOwnable(creditTreasuryPool).owner() != SAFE,
            "Safe is already CreditTreasuryPool owner - already migrated?"
        );

        console.log("Pre-flight checks passed.");
        console.log("");
    }

    /// @dev Post-migration verification
    function _verify(address creditTreasuryPool, address stakingPool, address deployer) internal view {
        // Ownership
        bool ctpOwnerOk = IOwnable(creditTreasuryPool).owner() == SAFE;
        bool spOwnerOk = IOwnable(stakingPool).owner() == SAFE;
        console.log("CreditTreasuryPool owner is Safe:", ctpOwnerOk ? "YES" : "FAIL");
        console.log("StakingPool owner is Safe:        ", spOwnerOk ? "YES" : "FAIL");

        // Safe has admin roles
        bool ctpAdminOk = IAccessControl(creditTreasuryPool).hasRole(DEFAULT_ADMIN_ROLE, SAFE);
        bool spAdminOk = IAccessControl(stakingPool).hasRole(DEFAULT_ADMIN_ROLE, SAFE);
        console.log("Safe has DEFAULT_ADMIN on CTP:    ", ctpAdminOk ? "YES" : "FAIL");
        console.log("Safe has DEFAULT_ADMIN on SP:     ", spAdminOk ? "YES" : "FAIL");

        // Safe has UPGRADER_ROLE on StakingPool
        bool spUpgraderOk = IAccessControl(stakingPool).hasRole(UPGRADER_ROLE, SAFE);
        console.log("Safe has UPGRADER_ROLE on SP:     ", spUpgraderOk ? "YES" : "FAIL");

        // Deployer lost admin roles
        bool ctpDeployerNoAdmin = !IAccessControl(creditTreasuryPool).hasRole(DEFAULT_ADMIN_ROLE, deployer);
        bool spDeployerNoAdmin = !IAccessControl(stakingPool).hasRole(DEFAULT_ADMIN_ROLE, deployer);
        console.log("Deployer lost admin on CTP:       ", ctpDeployerNoAdmin ? "YES" : "FAIL");
        console.log("Deployer lost admin on SP:        ", spDeployerNoAdmin ? "YES" : "FAIL");

        // Deployer retains operational roles
        bool ctpManagerOk = IAccessControl(creditTreasuryPool).hasRole(POOL_MANAGER_ROLE, deployer);
        bool spManagerOk = IAccessControl(stakingPool).hasRole(POOL_MANAGER_ROLE, deployer);
        bool ctpApproverOk = IAccessControl(creditTreasuryPool).hasRole(APPROVER_ROLE, deployer);
        console.log("Deployer keeps POOL_MANAGER CTP:  ", ctpManagerOk ? "YES" : "FAIL");
        console.log("Deployer keeps POOL_MANAGER SP:   ", spManagerOk ? "YES" : "FAIL");
        console.log("Deployer keeps APPROVER CTP:      ", ctpApproverOk ? "YES" : "FAIL");

        require(ctpOwnerOk && spOwnerOk, "OWNERSHIP TRANSFER FAILED");
        require(ctpAdminOk && spAdminOk, "ADMIN ROLE GRANT FAILED");
        require(ctpDeployerNoAdmin && spDeployerNoAdmin, "ADMIN ROLE REVOKE FAILED");
        require(ctpManagerOk && spManagerOk, "DEPLOYER LOST OPERATIONAL ROLES");
    }
}
