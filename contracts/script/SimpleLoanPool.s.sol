// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import { SimpleLoanPool } from "../src/Loan/SimpleLoanPool.sol";
import { UpgradeableCommunityToken } from "../src/ERC20/UpgradeableCommunityToken.sol";

contract SimpleLoanPoolScript is Script {
	SimpleLoanPool public simpleLoanPool;

	address public proxy;

	function deploy(address owner, address[] calldata approvers, address token) public {
		uint256 deployerPrivateKey = isAnvil()
			? vm.envUint("ANVIL_PRIVATE_KEY")
			: vm.envUint("PRIVATE_KEY");

		vm.startBroadcast(deployerPrivateKey);

		address implementation = address(new SimpleLoanPool());

		bytes memory data = abi.encodeCall(SimpleLoanPool.initialize, (owner, approvers, ERC20Upgradeable(token)));
		proxy = address(new ERC1967Proxy(implementation, data));

		simpleLoanPool = SimpleLoanPool(proxy);

		console.logAddress(proxy);

		vm.stopBroadcast();
	}

	function deployWithToken(address owner, address[] calldata approvers) public {
		uint256 deployerPrivateKey = isAnvil()
			? vm.envUint("ANVIL_PRIVATE_KEY")
			: vm.envUint("PRIVATE_KEY");

		vm.startBroadcast(deployerPrivateKey);

		address tokenImplementation = address(new UpgradeableCommunityToken());

		address[] memory minters = new address[](1);
		minters[0] = owner;

		bytes memory tokenData = abi.encodeCall(UpgradeableCommunityToken.initialize, (owner, minters, "Mock Token", "MCT"));
		address tokenProxy = address(new ERC1967Proxy(tokenImplementation, tokenData));

		console.logAddress(tokenProxy);

		address implementation = address(new SimpleLoanPool());

		bytes memory data = abi.encodeCall(SimpleLoanPool.initialize, (owner, approvers, ERC20Upgradeable(tokenProxy)));
		proxy = address(new ERC1967Proxy(implementation, data));

		simpleLoanPool = SimpleLoanPool(proxy);

		console.logAddress(proxy);

		if (isAnvil()) {
			UpgradeableCommunityToken token = UpgradeableCommunityToken(tokenProxy);

			token.mint(proxy, 1000000000000);

			console.log("Minted 1000000000000 tokens to the proxy");
			console.log(token.balanceOf(proxy));
		}

		vm.stopBroadcast();
	}

	function isAnvil() private view returns (bool) {
		return block.chainid == 31_337;
	}
}
