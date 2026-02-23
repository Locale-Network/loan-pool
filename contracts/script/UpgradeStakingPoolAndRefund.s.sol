// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {StakingPool} from "../src/Staking/StakingPool.sol";

/// @dev Minimal interface for UUPSUpgradeable proxy
interface IUUPSProxy {
    function upgradeToAndCall(address newImplementation, bytes memory data) external;
}

/// @dev Minimal interface for checking owner
interface IOwnable {
    function owner() external view returns (address);
}

/// @dev Minimal interface for SimpleLoanPool.transferFunds
interface ISimpleLoanPool {
    function transferFunds(address to, uint256 amount) external returns (bool);
}

/// @dev Minimal ERC20 interface for balance check
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

/// @title UpgradeStakingPoolAndRefund
/// @notice 1) Upgrades StakingPool UUPS proxy to latest implementation (cooldownWaived fix)
///         2) Transfers USDC from LoanPool back to StakingPool so investors can withdraw
/// @dev Deployer EOA must be owner of both StakingPool and SimpleLoanPool
contract UpgradeStakingPoolAndRefundScript is Script {
    function run() external {
        // Read addresses from environment
        address stakingPoolProxy = vm.envAddress("NEXT_PUBLIC_STAKING_POOL_ADDRESS");
        address loanPoolProxy = vm.envAddress("NEXT_PUBLIC_LOAN_POOL_ADDRESS");
        address stakingToken = vm.envAddress("NEXT_PUBLIC_TOKEN_ADDRESS");
        uint256 refundAmount = vm.envOr("REFUND_AMOUNT", uint256(0)); // In raw units (6 decimals for USDC)

        uint256 deployerPrivateKey = block.chainid == 31_337
            ? vm.envUint("ANVIL_PRIVATE_KEY")
            : vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("===========================================");
        console.log("  StakingPool Upgrade + USDC Refund");
        console.log("===========================================");
        console.log("StakingPool proxy:", stakingPoolProxy);
        console.log("LoanPool proxy:  ", loanPoolProxy);
        console.log("Staking token:   ", stakingToken);
        console.log("Deployer:        ", deployer);
        console.log("Chain ID:        ", block.chainid);
        console.log("");

        // Pre-flight checks
        address stakingOwner = IOwnable(stakingPoolProxy).owner();
        address loanOwner = IOwnable(loanPoolProxy).owner();
        require(stakingOwner == deployer, "Deployer is not StakingPool owner");
        require(loanOwner == deployer, "Deployer is not LoanPool owner");
        console.log("Pre-flight: deployer is owner of both contracts. OK");

        // Check balances
        uint256 stakingPoolBalance = IERC20Minimal(stakingToken).balanceOf(stakingPoolProxy);
        uint256 loanPoolBalance = IERC20Minimal(stakingToken).balanceOf(loanPoolProxy);
        console.log("StakingPool USDC balance:", stakingPoolBalance);
        console.log("LoanPool USDC balance:   ", loanPoolBalance);

        // Auto-calculate refund if not provided
        if (refundAmount == 0) {
            // Calculate: totalStaked - currentBalance
            // Use low-level call to extract just totalStaked (3rd return value)
            bytes32 poolId = keccak256(abi.encodePacked("mini-scholars-learning-center"));
            (bool ok, bytes memory result) = stakingPoolProxy.staticcall(
                abi.encodeWithSignature("getPool(bytes32)", poolId)
            );
            require(ok, "getPool call failed");
            // totalStaked is at offset: skip string pointer (32) + minimumStake (32) = 64 bytes in
            // But string is dynamic, so ABI encoding has pointer at offset 0, then fixed values follow
            // Actually for ABI encoding with leading dynamic type:
            //   [0..31]   = offset to string data
            //   [32..63]  = minimumStake
            //   [64..95]  = totalStaked  <-- this is what we want
            uint256 totalStaked;
            assembly {
                // result data starts at result + 32 (skip length prefix)
                // totalStaked is at ABI offset 64 (third slot)
                totalStaked := mload(add(add(result, 32), 64))
            }
            console.log("Pool totalStaked:        ", totalStaked);

            if (totalStaked > stakingPoolBalance) {
                refundAmount = totalStaked - stakingPoolBalance;
            }
        }

        if (refundAmount > loanPoolBalance) {
            console.log("");
            console.log("WARNING: LoanPool balance insufficient for full refund!");
            console.log("  Needed: ", refundAmount);
            console.log("  Available:", loanPoolBalance);
            refundAmount = loanPoolBalance; // Transfer what we can
        }

        console.log("Refund amount:           ", refundAmount);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============================================
        // STEP 1: Upgrade StakingPool implementation
        // ============================================
        console.log("STEP 1: Deploying new StakingPool implementation...");
        address newImpl = address(new StakingPool());
        console.log("  New implementation:", newImpl);

        console.log("  Upgrading proxy...");
        IUUPSProxy(stakingPoolProxy).upgradeToAndCall(newImpl, "");
        console.log("  Proxy upgraded successfully!");
        console.log("");

        // ============================================
        // STEP 2: Transfer USDC from LoanPool to StakingPool
        // ============================================
        if (refundAmount > 0) {
            console.log("STEP 2: Transferring USDC from LoanPool to StakingPool...");
            bool success = ISimpleLoanPool(loanPoolProxy).transferFunds(stakingPoolProxy, refundAmount);
            require(success, "USDC transfer failed");
            console.log("  Transferred:", refundAmount, "to StakingPool");
        } else {
            console.log("STEP 2: No refund needed (StakingPool has sufficient balance).");
        }

        vm.stopBroadcast();

        // Verify final state
        uint256 finalStakingBalance = IERC20Minimal(stakingToken).balanceOf(stakingPoolProxy);
        uint256 finalLoanBalance = IERC20Minimal(stakingToken).balanceOf(loanPoolProxy);

        console.log("");
        console.log("===========================================");
        console.log("  Complete!");
        console.log("===========================================");
        console.log("StakingPool USDC balance:", finalStakingBalance);
        console.log("LoanPool USDC balance:   ", finalLoanBalance);
        console.log("");
        console.log("Next: run force-unstake.js to withdraw investor funds.");
    }
}
