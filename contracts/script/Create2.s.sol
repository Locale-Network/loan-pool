// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";

import { Create2 } from "../src/Create2/Create2.sol";

contract Create2Script is Script {
	Create2 public create2;

	function run() public {
		vm.broadcast();

		create2 = new Create2();

		console.logAddress(address(create2));
	}
}
