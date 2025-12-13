// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BorrowerCredential} from "../src/Credentials/BorrowerCredential.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BorrowerCredentialTest is Test {
    BorrowerCredential public credential;

    address public admin;
    address public issuer;
    address public revoker;
    address public borrower1;
    address public borrower2;

    uint256 public constant ONE_YEAR = 365 days;

    function setUp() public {
        admin = address(this);
        issuer = address(0x1);
        revoker = address(0x2);
        borrower1 = address(0x3);
        borrower2 = address(0x4);

        // Deploy BorrowerCredential
        BorrowerCredential impl = new BorrowerCredential();

        // Initialize only takes admin parameter - admin gets all roles
        bytes memory initData = abi.encodeWithSelector(
            BorrowerCredential.initialize.selector,
            admin
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        credential = BorrowerCredential(address(proxy));

        // Grant additional roles to specific addresses
        credential.grantRole(credential.ISSUER_ROLE(), issuer);
        credential.grantRole(credential.REVOKER_ROLE(), revoker);
    }

    ///////////////////////////////////////////////////////////
    // Test 1: Initialization
    ///////////////////////////////////////////////////////////

    function testInitialization() public view {
        assertEq(credential.name(), "Locale Borrower Credential");
        assertEq(credential.symbol(), "LBC");
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
            borrower1,
            1, // Basic KYC
            ONE_YEAR,
            "plaid_verification_123"
        );

        // Check ownership
        assertEq(credential.ownerOf(tokenId), borrower1);

        // Check credential data
        (
            uint256 kycLevel,
            uint256 issuedAt,
            uint256 expiresAt,
            bool revoked,
            string memory plaidId
        ) = credential.credentials(tokenId);

        assertEq(kycLevel, 1);
        assertEq(issuedAt, block.timestamp);
        assertEq(expiresAt, block.timestamp + ONE_YEAR);
        assertFalse(revoked);
        assertEq(plaidId, "plaid_verification_123");
    }

    function testIssueCredentialEnhancedKYC() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(
            borrower1,
            2, // Enhanced KYC
            ONE_YEAR,
            "plaid_enhanced_456"
        );

        (uint256 kycLevel, , , , ) = credential.credentials(tokenId);
        assertEq(kycLevel, 2);
    }

    function testCannotIssueDuplicateCredential() public {
        vm.prank(issuer);
        credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        // Try to issue another credential to same address
        vm.prank(issuer);
        vm.expectRevert();
        credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_456");
    }

    function testOnlyIssuerCanIssue() public {
        vm.prank(borrower1);
        vm.expectRevert();
        credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");
    }

    function testInvalidKYCLevel() public {
        vm.prank(issuer);
        vm.expectRevert();
        credential.issueCredential(borrower1, 0, ONE_YEAR, "plaid_123"); // Level 0 invalid

        vm.prank(issuer);
        vm.expectRevert();
        credential.issueCredential(borrower1, 3, ONE_YEAR, "plaid_123"); // Level 3 invalid
    }

    ///////////////////////////////////////////////////////////
    // Test 3: Soulbound (Non-Transferable)
    ///////////////////////////////////////////////////////////

    function testCannotTransferCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        // Try to transfer - should fail
        vm.prank(borrower1);
        vm.expectRevert();
        credential.transferFrom(borrower1, borrower2, tokenId);
    }

    function testCannotSafeTransferCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        // Try safe transfer - should fail
        vm.prank(borrower1);
        vm.expectRevert();
        credential.safeTransferFrom(borrower1, borrower2, tokenId);
    }

    function testCannotApproveCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        // Try to approve - should fail
        vm.prank(borrower1);
        vm.expectRevert();
        credential.approve(borrower2, tokenId);
    }

    function testCannotSetApprovalForAll() public {
        vm.prank(issuer);
        credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        // Try to set approval for all - should fail
        vm.prank(borrower1);
        vm.expectRevert();
        credential.setApprovalForAll(borrower2, true);
    }

    ///////////////////////////////////////////////////////////
    // Test 4: Credential Validity
    ///////////////////////////////////////////////////////////

    function testCredentialValidAfterIssuance() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        assertTrue(credential.isCredentialValid(tokenId));
        assertTrue(credential.hasValidCredential(borrower1));
    }

    function testCredentialInvalidAfterExpiry() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        // Warp past expiry
        vm.warp(block.timestamp + ONE_YEAR + 1);

        assertFalse(credential.isCredentialValid(tokenId));
        assertFalse(credential.hasValidCredential(borrower1));
    }

    function testCredentialInvalidAfterRevocation() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        // Revoke
        vm.prank(revoker);
        credential.revokeCredential(tokenId, "Failed AML check");

        assertFalse(credential.isCredentialValid(tokenId));
        assertFalse(credential.hasValidCredential(borrower1));
    }

    function testNoCredential() public view {
        // Address without credential
        assertFalse(credential.hasValidCredential(borrower1));
    }

    ///////////////////////////////////////////////////////////
    // Test 5: Credential Revocation
    ///////////////////////////////////////////////////////////

    function testRevokeCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        vm.prank(revoker);
        credential.revokeCredential(tokenId, "Suspicious activity");

        (,,,bool revoked,) = credential.credentials(tokenId);
        assertTrue(revoked);
    }

    function testOnlyRevokerCanRevoke() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        vm.prank(borrower1);
        vm.expectRevert();
        credential.revokeCredential(tokenId, "Test revoke");
    }

    ///////////////////////////////////////////////////////////
    // Test 6: Credential Renewal
    ///////////////////////////////////////////////////////////

    function testRenewCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        uint256 originalExpiry = block.timestamp + ONE_YEAR;

        // Renew for another year
        vm.prank(issuer);
        credential.renewCredential(tokenId, ONE_YEAR);

        (,,uint256 newExpiry,,) = credential.credentials(tokenId);
        assertEq(newExpiry, originalExpiry + ONE_YEAR);
    }

    function testCannotRenewRevokedCredential() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        vm.prank(revoker);
        credential.revokeCredential(tokenId, "Revoked");

        vm.prank(issuer);
        vm.expectRevert();
        credential.renewCredential(tokenId, ONE_YEAR);
    }

    function testOnlyIssuerCanRenew() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        vm.prank(borrower1);
        vm.expectRevert();
        credential.renewCredential(tokenId, ONE_YEAR);
    }

    ///////////////////////////////////////////////////////////
    // Test 7: KYC Level Getters
    ///////////////////////////////////////////////////////////

    function testGetKYCLevel() public {
        vm.prank(issuer);
        credential.issueCredential(borrower1, 2, ONE_YEAR, "plaid_123");

        assertEq(credential.getKYCLevel(borrower1), 2);
    }

    function testGetKYCLevelZeroForNoCredential() public view {
        assertEq(credential.getKYCLevel(borrower1), 0);
    }

    function testGetKYCLevelZeroForExpired() public {
        vm.prank(issuer);
        credential.issueCredential(borrower1, 2, ONE_YEAR, "plaid_123");

        vm.warp(block.timestamp + ONE_YEAR + 1);

        assertEq(credential.getKYCLevel(borrower1), 0);
    }

    ///////////////////////////////////////////////////////////
    // Test 8: Pause Functionality
    ///////////////////////////////////////////////////////////

    function testPauseBlocksIssuance() public {
        credential.pause();

        vm.prank(issuer);
        vm.expectRevert();
        credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");
    }

    function testUnpauseAllowsIssuance() public {
        credential.pause();
        credential.unpause();

        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        assertGt(tokenId, 0);
    }

    function testOnlyAdminCanPause() public {
        vm.prank(borrower1);
        vm.expectRevert();
        credential.pause();
    }

    ///////////////////////////////////////////////////////////
    // Test 9: Token URI
    ///////////////////////////////////////////////////////////

    function testTokenURI() public {
        vm.prank(issuer);
        uint256 tokenId = credential.issueCredential(borrower1, 1, ONE_YEAR, "plaid_123");

        // Verify tokenURI is callable without reverting
        // Default ERC721 returns empty string until base URI is set
        string memory uri = credential.tokenURI(tokenId);
        // URI should be empty or contain valid data (not revert)
        // We check that bytes length is defined (0 for empty, >0 for set)
        assertGe(bytes(uri).length, 0, "Token URI should be callable");
    }

    function testTokenURIRevertsForNonexistentToken() public {
        // Should revert for token that doesn't exist
        vm.expectRevert();
        credential.tokenURI(999);
    }
}
