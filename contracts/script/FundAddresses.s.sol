// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {UpgradeableCommunityToken} from "../src/ERC20/UpgradeableCommunityToken.sol";

/// @title FundAddresses - Mint tokens to multiple addresses
/// @notice Mints 50,000 lUSD test tokens to specified addresses
contract FundAddressesScript is Script {
    // Token address from .env.local
    address constant TOKEN = 0x20FC87a7E0D63C50332C6F15B5f91ad63A559459;

    // Amount to mint per address (50,000 with 6 decimals)
    uint256 constant AMOUNT = 50_000 * 1e6;

    // Addresses to fund
    address[] public recipients;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Initialize recipients array (EIP-55 checksummed addresses)
        recipients.push(0x0a9871196E546a277072a04a6E1C1bC2CC25aaA2);
        recipients.push(0x183bCFa83319c1b38c55ED520a0b073D4d92D98F);
        recipients.push(0x4Fd6b6b0A0ABbBa48B48BE5c5bcD4c3b6BCc142B);
        recipients.push(0x828ea694625DEEFfE93527165F23ff6DCA3a877A);
        recipients.push(0x89E61f8702Fe398d7172450F44348F6deBE68D93);
        recipients.push(0x94802E7a5e8bf7871Db02888846D948C4d8CC093);
        recipients.push(0xb3Ba7a27A8F3DbC4efa867e9C62c7b8E0ea579A6);
        recipients.push(0xbd6B37d5C89AFaEBD8333365a4cA722CC204ea9D);

        console.log("===========================================");
        console.log("  Fund Addresses Script");
        console.log("===========================================");
        console.log("Token:", TOKEN);
        console.log("Amount per address:", AMOUNT / 1e6, "lUSD");
        console.log("Deployer:", deployer);
        console.log("");

        UpgradeableCommunityToken token = UpgradeableCommunityToken(TOKEN);

        vm.startBroadcast(deployerPrivateKey);

        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 balanceBefore = token.balanceOf(recipient);

            console.log("Minting to:", recipient);
            token.mint(recipient, AMOUNT);

            uint256 balanceAfter = token.balanceOf(recipient);
            console.log("  Balance before:", balanceBefore / 1e6, "lUSD");
            console.log("  Balance after:", balanceAfter / 1e6, "lUSD");
            console.log("");
        }

        vm.stopBroadcast();

        console.log("===========================================");
        console.log("  Funding Complete!");
        console.log("===========================================");
        console.log("Total funded:", recipients.length, "addresses");
        console.log("Total minted:", (AMOUNT * recipients.length) / 1e6, "lUSD");
    }
}
