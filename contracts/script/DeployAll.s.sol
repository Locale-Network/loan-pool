// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Core contracts
import {SimpleLoanPool} from "../src/Loan/SimpleLoanPool.sol";
import {StakingPool} from "../src/Staking/StakingPool.sol";
import {UpgradeableCommunityToken} from "../src/ERC20/UpgradeableCommunityToken.sol";

// Credential contracts
import {BorrowerCredential} from "../src/Credentials/BorrowerCredential.sol";
import {InvestorCredential} from "../src/Credentials/InvestorCredential.sol";

/// @title DeployAll - Master Deployment Script
/// @notice Deploys all Locale Lending contracts in the correct order
/// @dev Outputs JSON file with all deployed addresses
contract DeployAllScript is Script {
    // Deployed contract addresses
    address public token;
    address public loanPool;
    address public stakingPool;
    address public borrowerCredential;
    address public investorCredential;

    /// @notice Deploy all contracts for local development
    function run() external {
        uint256 deployerPrivateKey = isAnvil()
            ? vm.envUint("ANVIL_PRIVATE_KEY")
            : vm.envUint("PRIVATE_KEY");

        // Derive deployer address from private key
        address deployer = vm.addr(deployerPrivateKey);

        console.log("===========================================");
        console.log("  Locale Lending - Full Deployment");
        console.log("===========================================");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Token
        console.log("1. Deploying Token...");
        address tokenImpl = address(new UpgradeableCommunityToken());

        address[] memory minters = new address[](1);
        minters[0] = deployer;

        bytes memory tokenData = abi.encodeCall(
            UpgradeableCommunityToken.initialize,
            (deployer, minters, "Locale USD", "lUSD")
        );
        token = address(new ERC1967Proxy(tokenImpl, tokenData));
        console.log("   Token (lUSD):", token);

        // 2. Deploy SimpleLoanPool
        console.log("");
        console.log("2. Deploying SimpleLoanPool...");
        address loanPoolImpl = address(new SimpleLoanPool());

        address[] memory approvers = new address[](1);
        approvers[0] = deployer;

        bytes memory loanPoolData = abi.encodeCall(
            SimpleLoanPool.initialize,
            (deployer, approvers, ERC20Upgradeable(token))
        );
        loanPool = address(new ERC1967Proxy(loanPoolImpl, loanPoolData));
        console.log("   SimpleLoanPool:", loanPool);

        // 3. Deploy StakingPool
        console.log("");
        console.log("3. Deploying StakingPool...");
        address stakingPoolImpl = address(new StakingPool());

        uint256 cooldownPeriod = isAnvil() ? 60 : 7 days;

        bytes memory stakingPoolData = abi.encodeCall(
            StakingPool.initialize,
            (deployer, IERC20(token), deployer, cooldownPeriod)
        );
        stakingPool = address(new ERC1967Proxy(stakingPoolImpl, stakingPoolData));
        console.log("   StakingPool:", stakingPool);

        // 4. Deploy Credentials
        console.log("");
        console.log("4. Deploying Credentials...");

        address borrowerCredImpl = address(new BorrowerCredential());
        bytes memory borrowerCredData = abi.encodeCall(BorrowerCredential.initialize, (deployer));
        borrowerCredential = address(new ERC1967Proxy(borrowerCredImpl, borrowerCredData));
        console.log("   BorrowerCredential:", borrowerCredential);

        address investorCredImpl = address(new InvestorCredential());
        bytes memory investorCredData = abi.encodeCall(InvestorCredential.initialize, (deployer));
        investorCredential = address(new ERC1967Proxy(investorCredImpl, investorCredData));
        console.log("   InvestorCredential:", investorCredential);

        // 5. Post-deployment setup (Anvil only)
        if (isAnvil()) {
            console.log("");
            console.log("5. Post-deployment setup (Anvil)...");
            _setupAnvilTokens(deployer);
            _setupAnvilStakingPool();
        }

        vm.stopBroadcast();

        // Print summary
        console.log("");
        console.log("===========================================");
        console.log("  Deployment Complete!");
        console.log("===========================================");
        console.log("");
        printEnvFormat();
    }

    /// @notice Print addresses in .env format for easy copy-paste
    function printEnvFormat() internal view {
        console.log("# Add to .env.local:");
        console.log("");
        console.log("# Core Contracts");
        console.log("NEXT_PUBLIC_TOKEN_ADDRESS=", token);
        console.log("NEXT_PUBLIC_LOAN_POOL_ADDRESS=", loanPool);
        console.log("NEXT_PUBLIC_STAKING_POOL_ADDRESS=", stakingPool);
        console.log("");
        console.log("# Credentials");
        console.log("NEXT_PUBLIC_BORROWER_NFT_ADDRESS=", borrowerCredential);
        console.log("NEXT_PUBLIC_INVESTOR_NFT_ADDRESS=", investorCredential);
    }

    function isAnvil() internal view returns (bool) {
        return block.chainid == 31_337;
    }

    /// @dev Mint tokens for Anvil testing
    /// @param deployerAddress The address to receive deployer tokens
    function _setupAnvilTokens(address deployerAddress) internal {
        UpgradeableCommunityToken tokenContract = UpgradeableCommunityToken(token);
        tokenContract.mint(loanPool, 10_000_000 * 1e6); // 10M to loan pool
        tokenContract.mint(deployerAddress, 1_000_000 * 1e6);  // 1M to deployer
        console.log("   Minted 10M lUSD to LoanPool");
        console.log("   Minted 1M lUSD to deployer:", deployerAddress);
    }

    /// @dev Create initial staking pool for Anvil testing
    function _setupAnvilStakingPool() internal {
        StakingPool(stakingPool).createPool(
            keccak256("default-pool"),
            "Default Pool",
            100 * 1e6, // 100 lUSD minimum stake
            100        // 1% fee (100 basis points)
        );
        console.log("   Created default staking pool");
    }
}
