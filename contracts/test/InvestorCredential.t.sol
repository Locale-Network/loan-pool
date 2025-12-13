// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {InvestorCredential} from "../src/Credentials/InvestorCredential.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract InvestorCredentialTest is Test {
    InvestorCredential public credential;

    address public admin;
    address public issuer;
    address public revoker;
    address public investor1;
    address public investor2;

    uint256 public constant ONE_YEAR = 365 days;
    uint256 public constant DEFAULT_LIMIT = 100000 * 1e6; // 100k USDC

    function setUp() public {
        admin = address(this);
        issuer = address(0x1);
        revoker = address(0x2);
        investor1 = address(0x3);
        investor2 = address(0x4);

        // Deploy InvestorCredential
        InvestorCredential impl = new InvestorCredential();

        // Initialize only takes admin parameter
        bytes memory initData = abi.encodeWithSelector(
            InvestorCredential.initialize.selector,
            admin
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        credential = InvestorCredential(address(proxy));

        // Grant additional roles
        credential.grantRole(credential.ISSUER_ROLE(), issuer);
        credential.grantRole(credential.REVOKER_ROLE(), revoker);
    }

    ///////////////////////////////////////////////////////////
    // Test 1: Initialization
    ///////////////////////////////////////////////////////////

    function testInitialization() public view {
        assertEq(credential.name(), "Locale Investor Credential");
        assertEq(credential.symbol(), "LIC");
        assertTrue(credential.hasRole(credential.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(credential.hasRole(credential.ISSUER_ROLE(), issuer));
        assertTrue(credential.hasRole(credential.REVOKER_ROLE(), revoker));
    }

    ///////////////////////////////////////////////////////////
    // Test 2: Credential Issuance
    ///////////////////////////////////////////////////////////

    function testIssueCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(
            investor1,
            1, // Accredited
            ONE_YEAR,
            DEFAULT_LIMIT,
            "plaid_verification_123"
        );

        // Check ownership
        assertEq(credential.ownerOf(tokenId), investor1);

        // Check credential data
        (
            uint256 accreditationLevel,
            uint256 issuedAt,
            uint256 expiresAt,
            bool revoked,
            string memory plaidId,
            uint256 investmentLimit
        ) = credential.credentials(tokenId);

        assertEq(accreditationLevel, 1);
        assertEq(issuedAt, block.timestamp);
        assertEq(expiresAt, block.timestamp + ONE_YEAR);
        assertFalse(revoked);
        assertEq(plaidId, "plaid_verification_123");
        assertEq(investmentLimit, DEFAULT_LIMIT);
    }

    function testIssueCredentialAllLevels() public {
        // Test all accreditation levels (0-3)
        address[] memory investors = new address[](4);
        investors[0] = address(0x10);
        investors[1] = address(0x11);
        investors[2] = address(0x12);
        investors[3] = address(0x13);

        for (uint256 level = 0; level <= 3; level++) {
            vm.prank(issuer);
            uint256 tokenId = credential.issueCredential(
                investors[level],
                level,
                ONE_YEAR,
                DEFAULT_LIMIT,
                "plaid_id"
            );

            (uint256 accLevel, , , , , ) = credential.credentials(tokenId);
            assertEq(accLevel, level);
        }
    }

    function testCannotIssueDuplicateCredential() public {
        vm.prank(issuer);
        credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(issuer);
        vm.expectRevert();
        credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_456");
    }

    function testOnlyIssuerCanIssue() public {
        vm.prank(investor1);
        vm.expectRevert();
        credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");
    }

    function testInvalidAccreditationLevel() public {
        vm.prank(issuer);
        vm.expectRevert();
        credential.issueCredential(investor1, 4, ONE_YEAR, DEFAULT_LIMIT, "plaid_123"); // Level 4 invalid
    }

    ///////////////////////////////////////////////////////////
    // Test 3: Soulbound (Non-Transferable)
    ///////////////////////////////////////////////////////////

    function testCannotTransferCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(investor1);
        vm.expectRevert();
        credential.transferFrom(investor1, investor2, tokenId);
    }

    function testCannotSafeTransferCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(investor1);
        vm.expectRevert();
        credential.safeTransferFrom(investor1, investor2, tokenId);
    }

    function testCannotApproveCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(investor1);
        vm.expectRevert();
        credential.approve(investor2, tokenId);
    }

    function testCannotSetApprovalForAll() public {
        vm.prank(issuer);
        credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(investor1);
        vm.expectRevert();
        credential.setApprovalForAll(investor2, true);
    }

    ///////////////////////////////////////////////////////////
    // Test 4: Credential Validity
    ///////////////////////////////////////////////////////////

    function testCredentialValidAfterIssuance() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        assertTrue(credential.isCredentialValid(tokenId));
        assertTrue(credential.hasValidCredential(investor1));
    }

    function testCredentialInvalidAfterExpiry() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.warp(block.timestamp + ONE_YEAR + 1);

        assertFalse(credential.isCredentialValid(tokenId));
        assertFalse(credential.hasValidCredential(investor1));
    }

    function testCredentialInvalidAfterRevocation() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(revoker);
        credential.revokeCredential(tokenId, "Failed compliance check");

        assertFalse(credential.isCredentialValid(tokenId));
        assertFalse(credential.hasValidCredential(investor1));
    }

    function testNoCredential() public view {
        assertFalse(credential.hasValidCredential(investor1));
    }

    ///////////////////////////////////////////////////////////
    // Test 5: Accreditation Status
    ///////////////////////////////////////////////////////////

    function testIsAccredited() public {
        // Level 0 = Retail (not accredited)
        address retail = address(0x10);
        vm.prank(issuer);
        credential.issueCredential(retail, 0, ONE_YEAR, DEFAULT_LIMIT, "plaid_retail");
        assertFalse(credential.isAccredited(retail));

        // Level 1+ = Accredited
        vm.prank(issuer);
        credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_accredited");
        assertTrue(credential.isAccredited(investor1));

        vm.prank(issuer);
        credential.issueCredential(investor2, 2, ONE_YEAR, DEFAULT_LIMIT, "plaid_qualified");
        assertTrue(credential.isAccredited(investor2));
    }

    function testGetAccreditationLevel() public {
        vm.prank(issuer);
        credential.issueCredential(investor1, 2, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        assertEq(credential.getAccreditationLevel(investor1), 2);
    }

    function testGetAccreditationLevelZeroForNoCredential() public view {
        assertEq(credential.getAccreditationLevel(investor1), 0);
    }

    function testGetAccreditationLevelZeroForExpired() public {
        vm.prank(issuer);
        credential.issueCredential(investor1, 2, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.warp(block.timestamp + ONE_YEAR + 1);

        assertEq(credential.getAccreditationLevel(investor1), 0);
    }

    ///////////////////////////////////////////////////////////
    // Test 6: Investment Limits
    ///////////////////////////////////////////////////////////

    function testGetInvestmentLimit() public {
        vm.prank(issuer);
        credential.issueCredential(investor1, 1, ONE_YEAR, 500000 * 1e6, "plaid_123");

        assertEq(credential.getInvestmentLimit(investor1), 500000 * 1e6);
    }

    function testGetInvestmentLimitZeroForNoCredential() public view {
        assertEq(credential.getInvestmentLimit(investor1), 0);
    }

    function testGetInvestmentLimitZeroForInvalid() public {
        vm.prank(issuer);
        credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        // Revoke credential
        vm.prank(revoker);
        credential.revokeCredential(1, "Revoked");

        assertEq(credential.getInvestmentLimit(investor1), 0);
    }

    function testUpdateInvestmentLimit() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        uint256 newLimit = 500000 * 1e6;
        vm.prank(issuer);
        credential.updateInvestmentLimit(tokenId, newLimit);

        assertEq(credential.getInvestmentLimit(investor1), newLimit);
    }

    function testCannotUpdateLimitOfRevoked() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(revoker);
        credential.revokeCredential(tokenId, "Revoked");

        vm.prank(issuer);
        vm.expectRevert();
        credential.updateInvestmentLimit(tokenId, 200000 * 1e6);
    }

    ///////////////////////////////////////////////////////////
    // Test 7: Accreditation Upgrade
    ///////////////////////////////////////////////////////////

    function testUpgradeAccreditation() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        // Upgrade from Accredited (1) to Qualified Purchaser (2)
        vm.prank(issuer);
        credential.upgradeAccreditation(tokenId, 2);

        assertEq(credential.getAccreditationLevel(investor1), 2);
    }

    function testCannotUpgradeRevokedCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(revoker);
        credential.revokeCredential(tokenId, "Revoked");

        vm.prank(issuer);
        vm.expectRevert();
        credential.upgradeAccreditation(tokenId, 2);
    }

    function testOnlyIssuerCanUpgrade() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(investor1);
        vm.expectRevert();
        credential.upgradeAccreditation(tokenId, 2);
    }

    ///////////////////////////////////////////////////////////
    // Test 8: Credential Renewal
    ///////////////////////////////////////////////////////////

    function testRenewCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        uint256 originalExpiry = block.timestamp + ONE_YEAR;

        vm.prank(issuer);
        credential.renewCredential(tokenId, ONE_YEAR);

        (,,uint256 newExpiry,,,) = credential.credentials(tokenId);
        assertEq(newExpiry, originalExpiry + ONE_YEAR);
    }

    function testCannotRenewRevokedCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(revoker);
        credential.revokeCredential(tokenId, "Revoked");

        vm.prank(issuer);
        vm.expectRevert();
        credential.renewCredential(tokenId, ONE_YEAR);
    }

    ///////////////////////////////////////////////////////////
    // Test 9: Credential Revocation
    ///////////////////////////////////////////////////////////

    function testRevokeCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(revoker);
        credential.revokeCredential(tokenId, "Suspicious activity");

        (,,,bool revoked,,) = credential.credentials(tokenId);
        assertTrue(revoked);
    }

    function testOnlyRevokerCanRevoke() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        vm.prank(investor1);
        vm.expectRevert();
        credential.revokeCredential(tokenId, "Test revoke");
    }

    ///////////////////////////////////////////////////////////
    // Test 10: Pause Functionality
    ///////////////////////////////////////////////////////////

    function testPauseBlocksIssuance() public {
        credential.pause();

        vm.prank(issuer);
        vm.expectRevert();
        credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");
    }

    function testUnpauseAllowsIssuance() public {
        credential.pause();
        credential.unpause();

        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(investor1, 1, ONE_YEAR, DEFAULT_LIMIT, "plaid_123");

        assertGt(tokenId, 0);
    }

    function testOnlyAdminCanPause() public {
        vm.prank(investor1);
        vm.expectRevert();
        credential.pause();
    }
}
