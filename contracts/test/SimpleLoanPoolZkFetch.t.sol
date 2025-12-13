// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SimpleLoanPool} from "../src/Loan/SimpleLoanPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title SimpleLoanPoolZkFetchTest
 * @notice Tests for zkFetch + Cartesi DSCR verification functionality
 *
 * This test suite covers:
 * 1. Relay service management
 * 2. handleNotice() function for dscr_verified_zkfetch notices
 * 3. DSCR result storage and retrieval
 * 4. Loan creation with zkFetch verified DSCR
 * 5. Access control and security
 */
contract SimpleLoanPoolZkFetchTest is Test {
    SimpleLoanPool public pool;
    MockUSDC public usdc;

    address public owner;
    address public relayService;
    address public borrower;
    address public unauthorized;

    bytes32 public loanId1;
    bytes32 public loanId2;

    // DSCR test values
    uint256 public constant DSCR_VALUE = 1500; // 1.5 DSCR (scaled by 1000)
    uint256 public constant INTEREST_RATE = 850; // 8.5% in basis points
    bytes32 public constant PROOF_HASH = keccak256("zkfetch-proof-12345");

    function setUp() public {
        owner = address(this);
        relayService = address(0x1);
        borrower = address(0x2);
        unauthorized = address(0x3);

        loanId1 = keccak256("loan-zkfetch-1");
        loanId2 = keccak256("loan-zkfetch-2");

        // Deploy MockUSDC
        MockUSDC usdcImpl = new MockUSDC();
        ERC1967Proxy usdcProxy = new ERC1967Proxy(
            address(usdcImpl),
            abi.encodeWithSelector(MockUSDC.initialize.selector)
        );
        usdc = MockUSDC(address(usdcProxy));

        // Deploy SimpleLoanPool
        SimpleLoanPool poolImpl = new SimpleLoanPool();
        address[] memory approvers = new address[](1);
        approvers[0] = owner;

        ERC1967Proxy poolProxy = new ERC1967Proxy(
            address(poolImpl),
            abi.encodeWithSelector(
                SimpleLoanPool.initialize.selector,
                owner,
                approvers,
                usdc
            )
        );
        pool = SimpleLoanPool(address(poolProxy));

        // Setup: Mint USDC and set relay service
        usdc.mint(address(pool), 1000000 * 1e6); // 1M USDC to pool
        usdc.mint(borrower, 10000 * 1e6); // 10k USDC to borrower

        // Set relay service
        pool.setRelayService(relayService);
    }

    ///////////////////////////////////////////////////////////
    // Test: Relay Service Management
    ///////////////////////////////////////////////////////////

    function testSetRelayService() public {
        address newRelay = address(0x99);

        vm.expectEmit(true, true, false, false);
        emit SimpleLoanPool.RelayServiceUpdated(relayService, newRelay);

        pool.setRelayService(newRelay);

        assertEq(pool.relayService(), newRelay, "Relay service should be updated");
    }

    function testOnlyOwnerCanSetRelayService() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        pool.setRelayService(address(0x99));
    }

    ///////////////////////////////////////////////////////////
    // Test: handleNotice() - dscr_verified_zkfetch
    ///////////////////////////////////////////////////////////

    function testHandleNoticeStoresDscrResult() public {
        bytes memory noticeData = abi.encode(
            loanId1,
            DSCR_VALUE,
            INTEREST_RATE,
            PROOF_HASH
        );

        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);

        // Verify storage
        (
            uint256 dscrValue,
            uint256 interestRate,
            bytes32 proofHash,
            uint256 verifiedAt
        ) = pool.getZkFetchDscrResult(loanId1);

        assertEq(dscrValue, DSCR_VALUE, "DSCR value mismatch");
        assertEq(interestRate, INTEREST_RATE, "Interest rate mismatch");
        assertEq(proofHash, PROOF_HASH, "Proof hash mismatch");
        assertGt(verifiedAt, 0, "Verified timestamp should be set");
    }

    function testHandleNoticeUpdatesBorrowerLatestLoan() public {
        bytes memory noticeData = abi.encode(
            loanId1,
            DSCR_VALUE,
            INTEREST_RATE,
            PROOF_HASH
        );

        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);

        bytes32 latestLoan = pool.getBorrowerLatestVerifiedLoan(borrower);
        assertEq(latestLoan, loanId1, "Borrower latest loan should be updated");
    }

    function testHandleNoticeEmitsEvent() public {
        bytes memory noticeData = abi.encode(
            loanId1,
            DSCR_VALUE,
            INTEREST_RATE,
            PROOF_HASH
        );

        vm.expectEmit(true, true, false, true);
        emit SimpleLoanPool.DscrVerifiedZkFetch(
            loanId1,
            borrower,
            DSCR_VALUE,
            INTEREST_RATE,
            PROOF_HASH,
            block.timestamp
        );

        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);
    }

    function testHandleNoticeOnlyRelayService() public {
        bytes memory noticeData = abi.encode(
            loanId1,
            DSCR_VALUE,
            INTEREST_RATE,
            PROOF_HASH
        );

        vm.prank(unauthorized);
        vm.expectRevert("Only relay service can call this");
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);
    }

    function testHandleNoticeRevertsUnknownType() public {
        bytes memory noticeData = abi.encode(loanId1, DSCR_VALUE);

        vm.prank(relayService);
        vm.expectRevert("Unknown notice type");
        pool.handleNotice("unknown_type", borrower, noticeData);
    }

    ///////////////////////////////////////////////////////////
    // Test: DSCR Result Verification Checks
    ///////////////////////////////////////////////////////////

    function testHasZkFetchVerifiedDscr() public {
        // Before notice - should be false
        bool hasBefore = pool.hasZkFetchVerifiedDscr(loanId1);
        assertFalse(hasBefore, "Should not have verified DSCR before notice");

        // Submit notice
        bytes memory noticeData = abi.encode(
            loanId1,
            DSCR_VALUE,
            INTEREST_RATE,
            PROOF_HASH
        );
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);

        // After notice - should be true
        bool hasAfter = pool.hasZkFetchVerifiedDscr(loanId1);
        assertTrue(hasAfter, "Should have verified DSCR after notice");
    }

    function testGetZkFetchDscrResultRevertsIfNotVerified() public {
        vm.expectRevert("No verified DSCR for this loan");
        pool.getZkFetchDscrResult(loanId2);
    }

    ///////////////////////////////////////////////////////////
    // Test: Loan Creation with zkFetch DSCR
    ///////////////////////////////////////////////////////////

    function testCreateLoanWithZkFetchDscr() public {
        // First, submit DSCR verification notice
        bytes memory noticeData = abi.encode(
            loanId1,
            DSCR_VALUE,
            INTEREST_RATE,
            PROOF_HASH
        );
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);

        // Now create loan with verified DSCR
        uint256 loanAmount = 10000 * 1e6; // 10,000 USDC
        uint256 months = 12;

        pool.createLoanWithZkFetchDscr(loanId1, borrower, loanAmount, months);

        // Verify loan was created with verified interest rate
        assertEq(pool.loanIdToBorrower(loanId1), borrower, "Borrower mismatch");
        assertEq(pool.loanIdToAmount(loanId1), loanAmount, "Amount mismatch");
        assertEq(pool.loanIdToInterestRate(loanId1), INTEREST_RATE, "Interest rate should match verified rate");
        assertEq(pool.loanIdToRepaymentRemainingMonths(loanId1), months, "Months mismatch");
    }

    function testCreateLoanWithZkFetchDscrRevertsWithoutVerification() public {
        uint256 loanAmount = 10000 * 1e6;
        uint256 months = 12;

        vm.expectRevert("No valid zkFetch DSCR for this loan");
        pool.createLoanWithZkFetchDscr(loanId1, borrower, loanAmount, months);
    }

    function testCreateLoanWithZkFetchDscrCalculatesCorrectInterest() public {
        // Submit DSCR verification
        bytes memory noticeData = abi.encode(
            loanId1,
            DSCR_VALUE,
            INTEREST_RATE, // 850 basis points = 8.5%
            PROOF_HASH
        );
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);

        // Create loan
        uint256 loanAmount = 10000 * 1e6; // 10,000 USDC
        uint256 months = 12;

        pool.createLoanWithZkFetchDscr(loanId1, borrower, loanAmount, months);

        // Expected interest: (amount * rate * months) / (12 * 10000)
        // = (10000e6 * 850 * 12) / (12 * 10000)
        // = 10000e6 * 850 / 10000
        // = 850e6 = $850
        uint256 expectedInterest = (loanAmount * INTEREST_RATE * months) / (12 * 10000);

        assertEq(
            pool.loanIdToInterestAmount(loanId1),
            expectedInterest,
            "Interest amount should be correctly calculated from verified rate"
        );
    }

    ///////////////////////////////////////////////////////////
    // Test: Multiple DSCR Verifications
    ///////////////////////////////////////////////////////////

    function testMultipleVerificationsUpdateLatestLoan() public {
        // First verification
        bytes memory noticeData1 = abi.encode(
            loanId1,
            DSCR_VALUE,
            INTEREST_RATE,
            PROOF_HASH
        );
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData1);

        bytes32 firstLatest = pool.getBorrowerLatestVerifiedLoan(borrower);
        assertEq(firstLatest, loanId1, "First loan should be latest");

        // Second verification
        bytes memory noticeData2 = abi.encode(
            loanId2,
            DSCR_VALUE + 100, // Different DSCR
            INTEREST_RATE - 50, // Better rate
            keccak256("proof-2")
        );
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData2);

        bytes32 secondLatest = pool.getBorrowerLatestVerifiedLoan(borrower);
        assertEq(secondLatest, loanId2, "Second loan should now be latest");

        // Both loans should have valid DSCR results
        assertTrue(pool.hasZkFetchVerifiedDscr(loanId1), "First loan should still be verified");
        assertTrue(pool.hasZkFetchVerifiedDscr(loanId2), "Second loan should be verified");
    }

    ///////////////////////////////////////////////////////////
    // Test: DSCR-Based Interest Rate Tiers
    ///////////////////////////////////////////////////////////

    function testDifferentDscrValuesYieldDifferentRates() public {
        // Note: In production, the interest rate is computed by Cartesi based on DSCR
        // These tests verify the contract stores and uses whatever rate Cartesi provides

        // High DSCR = Low rate (simulated)
        bytes memory highDscrNotice = abi.encode(
            loanId1,
            2000,  // 2.0 DSCR - excellent
            500,   // 5% rate
            keccak256("proof-high")
        );
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, highDscrNotice);

        // Low DSCR = High rate (simulated)
        bytes memory lowDscrNotice = abi.encode(
            loanId2,
            1100,  // 1.1 DSCR - borderline
            1200,  // 12% rate
            keccak256("proof-low")
        );
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, lowDscrNotice);

        // Verify different rates were stored
        (uint256 dscr1, uint256 rate1,,) = pool.getZkFetchDscrResult(loanId1);
        (uint256 dscr2, uint256 rate2,,) = pool.getZkFetchDscrResult(loanId2);

        assertEq(rate1, 500, "High DSCR should have 5% rate");
        assertEq(rate2, 1200, "Low DSCR should have 12% rate");
        assertTrue(rate1 < rate2, "Higher DSCR should yield lower rate");
    }

    ///////////////////////////////////////////////////////////
    // Test: End-to-End zkFetch Flow
    ///////////////////////////////////////////////////////////

    function testFullZkFetchLoanFlow() public {
        // Step 1: Relay service submits DSCR verification from Cartesi
        bytes memory noticeData = abi.encode(
            loanId1,
            1500,  // 1.5 DSCR
            800,   // 8% interest rate
            keccak256("zkfetch-proof-full-flow")
        );
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);

        // Step 2: Create loan with verified DSCR
        uint256 loanAmount = 50000 * 1e6; // $50,000
        pool.createLoanWithZkFetchDscr(loanId1, borrower, loanAmount, 24);

        // Step 3: Activate the loan
        pool.activateLoan(loanId1);

        // Step 4: Verify borrower received funds
        assertGe(
            usdc.balanceOf(borrower),
            50000 * 1e6,
            "Borrower should have received loan funds"
        );

        // Step 5: Verify loan is active with correct parameters
        assertTrue(pool.loanIdToActive(loanId1), "Loan should be active");
        assertEq(pool.loanIdToInterestRate(loanId1), 800, "Interest rate should be 8%");
    }
}
