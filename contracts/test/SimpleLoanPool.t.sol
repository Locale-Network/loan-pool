// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SimpleLoanPool} from "../src/Loan/SimpleLoanPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SimpleLoanPoolTest is Test {
    SimpleLoanPool public pool;
    MockUSDC public usdc;

    address public owner;
    address public poolManager;
    address public borrower;

    bytes32 public loanId1;
    bytes32 public loanId2;

    function setUp() public {
        owner = address(this);
        poolManager = address(0x1);
        borrower = address(0x2);

        loanId1 = keccak256("loan1");
        loanId2 = keccak256("loan2");

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
        approvers[0] = poolManager;

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

        // Setup: Mint USDC to pool and borrower
        usdc.mint(address(pool), 1000000 * 1e6); // 1M USDC to pool
        usdc.mint(borrower, 10000 * 1e6); // 10k USDC to borrower
    }

    ///////////////////////////////////////////////////////////
    // Test 1: Pause Functionality
    ///////////////////////////////////////////////////////////

    function testPauseUnpause() public {
        // Owner can pause
        pool.pause();
        assertTrue(pool.paused(), "Contract should be paused");

        // Owner can unpause
        pool.unpause();
        assertFalse(pool.paused(), "Contract should be unpaused");
    }

    function testPauseBlocksOperations() public {
        // Create loan first
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12); // 10% APR, 12 months

        // Pause contract
        pool.pause();

        // Creating new loans should fail
        vm.expectRevert();
        pool.createLoan(loanId2, borrower, 2000 * 1e6, 1000, 12);

        // Activating loans should fail
        vm.expectRevert();
        pool.activateLoan(loanId1);

        // Making repayments should fail
        vm.expectRevert();
        vm.prank(borrower);
        pool.makeRepayment(loanId1);
    }

    function testOnlyOwnerCanPause() public {
        vm.prank(poolManager);
        vm.expectRevert();
        pool.pause();

        vm.prank(borrower);
        vm.expectRevert();
        pool.unpause();
    }

    ///////////////////////////////////////////////////////////
    // Test 2: Loan Creation
    ///////////////////////////////////////////////////////////

    function testCreateLoan() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12); // 10% APR

        address _borrower = pool.loanIdToBorrower(loanId1);
        uint256 amount = pool.loanIdToAmount(loanId1);
        uint256 interestRate = pool.loanIdToInterestRate(loanId1);

        assertEq(_borrower, borrower, "Borrower mismatch");
        assertEq(amount, 1000 * 1e6, "Amount mismatch");
        assertEq(interestRate, 1000, "Interest rate mismatch");
    }

    function testCannotCreateDuplicateLoan() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);

        vm.expectRevert();
        pool.createLoan(loanId1, borrower, 2000 * 1e6, 1000, 12);
    }

    ///////////////////////////////////////////////////////////
    // Test 3: Loan Activation (Reentrancy Protection)
    ///////////////////////////////////////////////////////////

    function testActivateLoan() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);

        uint256 borrowerBalanceBefore = usdc.balanceOf(borrower);

        pool.activateLoan(loanId1);

        uint256 borrowerBalanceAfter = usdc.balanceOf(borrower);

        assertEq(
            borrowerBalanceAfter - borrowerBalanceBefore,
            1000 * 1e6,
            "Borrower should receive loan amount"
        );

        bool active = pool.loanIdToActive(loanId1);
        assertTrue(active, "Loan should be active");
    }

    function testCannotActivateTwice() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);
        pool.activateLoan(loanId1);

        vm.expectRevert();
        pool.activateLoan(loanId1);
    }

    ///////////////////////////////////////////////////////////
    // Test 4: Repayment Logic
    ///////////////////////////////////////////////////////////

    function testMakeRepayment() public {
        // Create and activate loan
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);
        pool.activateLoan(loanId1);

        // Get values from contract
        (, uint256 interestForPayment) = pool.getNextRepayment(loanId1);

        // Remaining principal = original amount - repaid amount (0 at start)
        uint256 remainingPrincipal = pool.loanIdToAmount(loanId1) - pool.loanIdToRepaymentAmount(loanId1);

        // Total payment = principal + interest for this payment
        uint256 totalPayment = remainingPrincipal + interestForPayment;

        // Borrower approves pool to spend USDC
        vm.prank(borrower);
        usdc.approve(address(pool), totalPayment);

        // Make repayment
        uint256 poolBalanceBefore = usdc.balanceOf(address(pool));
        uint256 totalLentBefore = pool.totalLentAmount();

        vm.prank(borrower);
        pool.makeRepayment(loanId1);

        uint256 poolBalanceAfter = usdc.balanceOf(address(pool));
        uint256 totalLentAfter = pool.totalLentAmount();

        // Pool should receive payment
        assertEq(
            poolBalanceAfter - poolBalanceBefore,
            totalPayment,
            "Pool should receive payment"
        );

        // totalLentAmount should decrease by principal only (not interest)
        assertEq(
            totalLentBefore - totalLentAfter,
            remainingPrincipal,
            "totalLentAmount should decrease by principal"
        );

        // Loan should be fully repaid and inactive
        bool active = pool.loanIdToActive(loanId1);
        assertFalse(active, "Loan should be inactive after full repayment");
    }

    function testOnlyBorrowerCanRepay() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);
        pool.activateLoan(loanId1);

        vm.prank(poolManager);
        vm.expectRevert("Only borrower can make repayments");
        pool.makeRepayment(loanId1);
    }

    ///////////////////////////////////////////////////////////
    // Test 5: Interest Calculation
    ///////////////////////////////////////////////////////////

    function testInterestCalculation() public {
        // 1000 USDC loan at 10% APR (1000 basis points) for 12 months
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);

        // Formula from createLoan: (amount * interestRate * months) / (12 * 10000)
        uint256 totalInterest = (1000 * 1e6 * 1000 * 12) / (12 * 10000);
        // Total interest = 100 USDC (10% of 1000 USDC)

        // Total amount owed = principal + total interest
        uint256 totalOwed = 1000 * 1e6 + totalInterest;

        // getNextRepayment returns (remainingAmount, interestForThisPayment)
        (uint256 remainingAmount, uint256 interestForPayment) = pool.getNextRepayment(loanId1);

        // Remaining amount should be total owed
        assertEq(remainingAmount, totalOwed, "Remaining amount mismatch");

        // Interest for this payment: (totalOwed * interestRate) / (12 * 10000 * months)
        uint256 expectedInterestForPayment = (totalOwed * 1000) / (12 * 10000 * 12);

        assertEq(interestForPayment, expectedInterestForPayment, "Interest for payment mismatch");
    }

    ///////////////////////////////////////////////////////////
    // Test 6: Access Control
    ///////////////////////////////////////////////////////////

    function testOnlyPoolManagerCanCreateLoans() public {
        vm.prank(borrower);
        vm.expectRevert();
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);
    }

    function testOnlyPoolManagerCanActivateLoans() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);

        vm.prank(borrower);
        vm.expectRevert();
        pool.activateLoan(loanId1);
    }

    ///////////////////////////////////////////////////////////
    // Test 7: View Functions
    ///////////////////////////////////////////////////////////

    function testGetLoanData() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);

        address _borrower = pool.loanIdToBorrower(loanId1);
        uint256 amount = pool.loanIdToAmount(loanId1);
        uint256 interestRate = pool.loanIdToInterestRate(loanId1);
        uint256 repaymentRemainingMonths = pool.loanIdToRepaymentRemainingMonths(loanId1);
        bool active = pool.loanIdToActive(loanId1);

        assertEq(_borrower, borrower);
        assertEq(amount, 1000 * 1e6);
        assertEq(interestRate, 1000);
        assertEq(repaymentRemainingMonths, 12);
        assertFalse(active);
    }

    function testGetNextRepayment() public {
        pool.createLoan(loanId1, borrower, 1200 * 1e6, 1000, 12);

        // Total interest: (amount * interestRate * months) / (12 * 10000)
        uint256 totalInterest = (1200 * 1e6 * 1000 * 12) / (12 * 10000);
        // = 120 USDC (10% of 1200)

        // Total owed = principal + interest
        uint256 totalOwed = 1200 * 1e6 + totalInterest;

        (uint256 remainingAmount, uint256 interestForPayment) = pool
            .getNextRepayment(loanId1);

        // remainingAmount should be total owed (principal + interest)
        assertEq(remainingAmount, totalOwed, "Remaining amount mismatch");

        // interestForPayment: (totalOwed * interestRate) / (12 * 10000 * months)
        uint256 expectedInterestForPayment = (totalOwed * 1000) / (12 * 10000 * 12);
        assertEq(interestForPayment, expectedInterestForPayment, "Interest for payment mismatch");
    }

    ///////////////////////////////////////////////////////////
    // Test 8: Partial Repayment
    ///////////////////////////////////////////////////////////

    function testMakePartialRepayment() public {
        // Create and activate loan
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12); // 10% APR
        pool.activateLoan(loanId1);

        // Make a partial payment (interest first, then principal)
        uint256 partialPayment = 200 * 1e6;

        vm.prank(borrower);
        usdc.approve(address(pool), partialPayment);

        uint256 poolBalanceBefore = usdc.balanceOf(address(pool));

        vm.prank(borrower);
        pool.makePartialRepayment(loanId1, partialPayment);

        uint256 poolBalanceAfter = usdc.balanceOf(address(pool));

        // Pool should receive the partial payment
        assertEq(poolBalanceAfter - poolBalanceBefore, partialPayment);

        // Loan should still be active
        assertTrue(pool.loanIdToActive(loanId1));
    }

    function testPartialRepayment_InterestFirstThenPrincipal() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12); // 10% APR = 100 USDC interest
        pool.activateLoan(loanId1);

        // Total interest is 100 USDC (10% of 1000)
        uint256 totalInterest = pool.loanIdToInterestAmount(loanId1);
        assertEq(totalInterest, 100 * 1e6);

        // Pay exactly the interest amount
        uint256 interestPayment = totalInterest;

        vm.prank(borrower);
        usdc.approve(address(pool), interestPayment);

        vm.prank(borrower);
        pool.makePartialRepayment(loanId1, interestPayment);

        // Interest should be fully paid, principal untouched
        assertEq(pool.loanIdToInterestRepaymentAmount(loanId1), totalInterest);
        assertEq(pool.loanIdToRepaymentAmount(loanId1), 0); // Principal unchanged

        // Now pay principal
        uint256 principalPayment = 500 * 1e6;

        vm.prank(borrower);
        usdc.approve(address(pool), principalPayment);

        vm.prank(borrower);
        pool.makePartialRepayment(loanId1, principalPayment);

        // Principal should be reduced
        assertEq(pool.loanIdToRepaymentAmount(loanId1), principalPayment);
    }

    ///////////////////////////////////////////////////////////
    // Test 9: Loan Default
    ///////////////////////////////////////////////////////////

    function testMarkLoanDefaulted() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);
        pool.activateLoan(loanId1);

        uint256 totalLentBefore = pool.totalLentAmount();

        // Pool manager can mark loan as defaulted
        pool.markLoanDefaulted(loanId1);

        // Loan should be defaulted and inactive
        assertTrue(pool.isLoanDefaulted(loanId1));
        assertFalse(pool.loanIdToActive(loanId1));

        // totalLentAmount should decrease by outstanding principal
        uint256 totalLentAfter = pool.totalLentAmount();
        assertEq(totalLentBefore - totalLentAfter, 1000 * 1e6);
    }

    function testMarkLoanDefaulted_RevertIfNotActive() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);
        // Loan not activated

        vm.expectRevert("Loan is not active");
        pool.markLoanDefaulted(loanId1);
    }

    function testMarkLoanDefaulted_RevertIfAlreadyDefaulted() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);
        pool.activateLoan(loanId1);
        pool.markLoanDefaulted(loanId1);

        // When a loan is defaulted, it's also marked as inactive
        // So the onlyActiveLoan modifier triggers first
        vm.expectRevert("Loan is not active");
        pool.markLoanDefaulted(loanId1);
    }

    function testGetLoanOutstanding() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);
        pool.activateLoan(loanId1);

        (uint256 outstandingPrincipal, uint256 outstandingInterest) = pool.getLoanOutstanding(loanId1);

        assertEq(outstandingPrincipal, 1000 * 1e6);
        assertEq(outstandingInterest, 100 * 1e6); // 10% of 1000
    }

    ///////////////////////////////////////////////////////////
    // Test 10: zkFetch + Cartesi DSCR Verification
    ///////////////////////////////////////////////////////////

    function testSetRelayService() public {
        address relayService = address(0x123);

        pool.setRelayService(relayService);
        assertEq(pool.relayService(), relayService);
    }

    function testSetRelayService_OnlyOwner() public {
        vm.prank(borrower);
        vm.expectRevert();
        pool.setRelayService(address(0x123));
    }

    function testHandleNotice_DscrVerifiedZkFetch() public {
        address relayService = address(0x123);
        pool.setRelayService(relayService);

        // Simulate relay service calling handleNotice
        bytes32 loanId = keccak256("zkfetch_loan");
        uint256 dscrValue = 1500; // 1.5 DSCR (scaled by 1000)
        uint256 interestRate = 500; // 5% APR
        bytes32 proofHash = keccak256("proof_data");

        bytes memory noticeData = abi.encode(loanId, dscrValue, interestRate, proofHash);

        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);

        // Verify the DSCR result was stored
        assertTrue(pool.hasZkFetchVerifiedDscr(loanId));

        (uint256 storedDscr, uint256 storedRate, bytes32 storedHash, uint256 verifiedAt) =
            pool.getZkFetchDscrResult(loanId);

        assertEq(storedDscr, dscrValue);
        assertEq(storedRate, interestRate);
        assertEq(storedHash, proofHash);
        assertGt(verifiedAt, 0);

        // Verify borrower's latest loan ID is tracked
        assertEq(pool.getBorrowerLatestVerifiedLoan(borrower), loanId);
    }

    function testHandleNotice_RevertIfNotRelayService() public {
        address relayService = address(0x123);
        pool.setRelayService(relayService);

        bytes memory noticeData = abi.encode(loanId1, 1500, 500, keccak256("proof"));

        vm.prank(borrower); // Not the relay service
        vm.expectRevert("Only relay service can call this");
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);
    }

    function testHandleNotice_RevertUnknownNoticeType() public {
        address relayService = address(0x123);
        pool.setRelayService(relayService);

        bytes memory noticeData = abi.encode(loanId1, 1500, 500, keccak256("proof"));

        vm.prank(relayService);
        vm.expectRevert("Unknown notice type");
        pool.handleNotice("unknown_type", borrower, noticeData);
    }

    function testCreateLoanWithZkFetchDscr() public {
        address relayService = address(0x123);
        pool.setRelayService(relayService);

        bytes32 zkLoanId = keccak256("zk_loan");
        uint256 dscrValue = 1500; // 1.5 DSCR
        uint256 interestRate = 500; // 5% APR
        bytes32 proofHash = keccak256("proof_data");

        // First, submit the DSCR verification via relay
        bytes memory noticeData = abi.encode(zkLoanId, dscrValue, interestRate, proofHash);
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);

        // Now create the loan using verified DSCR
        uint256 loanAmount = 10000 * 1e6;
        uint256 months = 24;

        pool.createLoanWithZkFetchDscr(zkLoanId, borrower, loanAmount, months);

        // Verify loan was created with the verified interest rate
        assertEq(pool.loanIdToBorrower(zkLoanId), borrower);
        assertEq(pool.loanIdToAmount(zkLoanId), loanAmount);
        assertEq(pool.loanIdToInterestRate(zkLoanId), interestRate);

        // Interest amount should use verified rate: (amount * rate * months) / (12 * 10000)
        uint256 expectedInterest = (loanAmount * interestRate * months) / (12 * 10000);
        assertEq(pool.loanIdToInterestAmount(zkLoanId), expectedInterest);
    }

    function testCreateLoanWithZkFetchDscr_RevertIfNoVerification() public {
        bytes32 unverifiedLoanId = keccak256("unverified_loan");

        vm.expectRevert("No valid zkFetch DSCR for this loan");
        pool.createLoanWithZkFetchDscr(unverifiedLoanId, borrower, 10000 * 1e6, 24);
    }

    function testHasZkFetchVerifiedDscr() public {
        // Should be false for non-existent loan
        assertFalse(pool.hasZkFetchVerifiedDscr(loanId1));

        // Submit verification
        address relayService = address(0x123);
        pool.setRelayService(relayService);

        bytes memory noticeData = abi.encode(loanId1, 1500, 500, keccak256("proof"));
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);

        // Should be true now
        assertTrue(pool.hasZkFetchVerifiedDscr(loanId1));
    }

    function testGetZkFetchDscrResult_RevertIfNotVerified() public {
        vm.expectRevert("No verified DSCR for this loan");
        pool.getZkFetchDscrResult(loanId1);
    }

    ///////////////////////////////////////////////////////////
    // Test 11: Event Emissions
    ///////////////////////////////////////////////////////////

    function testEvent_DscrVerifiedZkFetch() public {
        address relayService = address(0x123);
        pool.setRelayService(relayService);

        bytes32 loanId = keccak256("event_test_loan");
        uint256 dscrValue = 1500;
        uint256 interestRate = 500;
        bytes32 proofHash = keccak256("proof");

        bytes memory noticeData = abi.encode(loanId, dscrValue, interestRate, proofHash);

        vm.prank(relayService);
        vm.expectEmit(true, true, false, true);
        emit SimpleLoanPool.DscrVerifiedZkFetch(
            loanId,
            borrower,
            dscrValue,
            interestRate,
            proofHash,
            block.timestamp
        );
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);
    }

    function testEvent_LoanCreatedWithVerifiedDscr() public {
        address relayService = address(0x123);
        pool.setRelayService(relayService);

        bytes32 loanId = keccak256("verified_loan");
        uint256 dscrValue = 1500;
        uint256 interestRate = 500;

        bytes memory noticeData = abi.encode(loanId, dscrValue, interestRate, keccak256("proof"));
        vm.prank(relayService);
        pool.handleNotice("dscr_verified_zkfetch", borrower, noticeData);

        uint256 amount = 10000 * 1e6;

        vm.expectEmit(true, true, false, true);
        emit SimpleLoanPool.LoanCreatedWithVerifiedDscr(loanId, borrower, amount, dscrValue, interestRate);
        pool.createLoanWithZkFetchDscr(loanId, borrower, amount, 24);
    }

    function testEvent_LoanDefaulted() public {
        pool.createLoan(loanId1, borrower, 1000 * 1e6, 1000, 12);
        pool.activateLoan(loanId1);

        vm.expectEmit(true, true, false, true);
        emit SimpleLoanPool.LoanDefaulted(loanId1, borrower, 1000 * 1e6, 100 * 1e6);
        pool.markLoanDefaulted(loanId1);
    }
}
