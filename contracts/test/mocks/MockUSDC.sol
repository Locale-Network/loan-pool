// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/// @title MockUSDC
/// @notice A mock USDC token for testing purposes
/// @dev Upgradeable ERC20 with 6 decimals and public mint function
contract MockUSDC is ERC20Upgradeable {
    function initialize() public initializer {
        __ERC20_init("USD Coin", "USDC");
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
