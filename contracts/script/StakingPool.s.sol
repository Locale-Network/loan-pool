// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakingPool} from "../src/Staking/StakingPool.sol";
import {UpgradeableCommunityToken} from "../src/ERC20/UpgradeableCommunityToken.sol";

/// @title StakingPool Deployment Script
/// @notice Deploys the StakingPool contract with UUPS proxy
contract StakingPoolScript is Script {
    StakingPool public stakingPool;
    address public proxy;

    /// @notice Deploys StakingPool with existing token
    /// @param owner Admin/owner address
    /// @param token Staking token address (e.g., USDC)
    /// @param feeRecipient Address to receive staking fees
    /// @param cooldownPeriod Cooldown period in seconds (e.g., 604800 for 7 days)
    function deploy(
        address owner,
        address token,
        address feeRecipient,
        uint256 cooldownPeriod
    ) public {
        uint256 deployerPrivateKey = isAnvil()
            ? vm.envUint("ANVIL_PRIVATE_KEY")
            : vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        address implementation = address(new StakingPool());

        bytes memory data = abi.encodeCall(
            StakingPool.initialize,
            (owner, IERC20(token), feeRecipient, cooldownPeriod)
        );
        proxy = address(new ERC1967Proxy(implementation, data));

        stakingPool = StakingPool(proxy);

        console.log("StakingPool deployed at:", proxy);

        vm.stopBroadcast();
    }

    /// @notice Deploys StakingPool with a new mock token (for testing)
    /// @param owner Admin/owner address
    /// @param feeRecipient Address to receive staking fees
    function deployWithMockToken(address owner, address feeRecipient) public {
        uint256 deployerPrivateKey = isAnvil()
            ? vm.envUint("ANVIL_PRIVATE_KEY")
            : vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock token first
        address tokenImplementation = address(new UpgradeableCommunityToken());

        address[] memory minters = new address[](1);
        minters[0] = owner;

        bytes memory tokenData = abi.encodeCall(
            UpgradeableCommunityToken.initialize,
            (owner, minters, "Mock USDC", "mUSDC")
        );
        address tokenProxy = address(new ERC1967Proxy(tokenImplementation, tokenData));

        console.log("Mock Token deployed at:", tokenProxy);

        // Deploy StakingPool
        address implementation = address(new StakingPool());

        uint256 cooldownPeriod = isAnvil() ? 60 : 7 days; // 60 seconds for local, 7 days for production

        bytes memory data = abi.encodeCall(
            StakingPool.initialize,
            (owner, IERC20(tokenProxy), feeRecipient, cooldownPeriod)
        );
        proxy = address(new ERC1967Proxy(implementation, data));

        stakingPool = StakingPool(proxy);

        console.log("StakingPool deployed at:", proxy);
        console.log("Cooldown period:", cooldownPeriod, "seconds");

        // Mint some tokens to owner for testing
        if (isAnvil()) {
            UpgradeableCommunityToken token = UpgradeableCommunityToken(tokenProxy);
            token.mint(owner, 1000000 * 1e6); // 1M tokens
            console.log("Minted 1,000,000 tokens to owner");
        }

        vm.stopBroadcast();
    }

    /// @notice Creates an initial pool after deployment
    /// @param poolId Unique pool identifier (bytes32)
    /// @param name Pool name
    /// @param minimumStake Minimum stake amount
    /// @param feeRate Fee rate in basis points
    function createPool(
        bytes32 poolId,
        string calldata name,
        uint256 minimumStake,
        uint256 feeRate
    ) public {
        uint256 deployerPrivateKey = isAnvil()
            ? vm.envUint("ANVIL_PRIVATE_KEY")
            : vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        stakingPool.createPool(poolId, name, minimumStake, feeRate);

        console.log("Pool created:", name);

        vm.stopBroadcast();
    }

    function isAnvil() private view returns (bool) {
        return block.chainid == 31_337;
    }
}
