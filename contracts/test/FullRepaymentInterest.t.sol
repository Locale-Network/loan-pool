// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SimpleLoanPool} from "../src/Loan/SimpleLoanPool.sol";
import {CreditTreasuryPool} from "../src/Loan/CreditTreasuryPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// Shared surface of SimpleLoanPool and CreditTreasuryPool used by these tests.
interface ILoanPool {
    function createLoan(bytes32, address, uint256, uint256, uint256) external;
    function activateLoan(bytes32) external;
    function makeRepayment(bytes32) external;
    function makePartialRepayment(bytes32, uint256) external;
    function updateLoanInterestRate(bytes32, uint256) external;
    function getNextRepayment(bytes32) external view returns (uint256, uint256);
    function loanIdToActive(bytes32) external view returns (bool);
    function loanIdToAmount(bytes32) external view returns (uint256);
    function loanIdToInterestAmount(bytes32) external view returns (uint256);
    function loanIdToRepaymentAmount(bytes32) external view returns (uint256);
    function loanIdToInterestRepaymentAmount(bytes32) external view returns (uint256);
    function totalLentAmount() external view returns (uint256);
}

/// Regression tests: makeRepayment (full payoff) must settle ALL remaining
/// scheduled interest before closing the loan, matching makePartialRepayment.
abstract contract FullRepaymentInterestBase is Test {
    ILoanPool internal pool;
    MockUSDC internal usdc;
    address internal borrower = address(0xB0B);
    address internal approver = address(0xA11);
    bytes32 internal constant LOAN = keccak256("loan-full-repay");

    uint256 internal constant PRINCIPAL = 1000e6; // 1,000 USDC
    uint256 internal constant RATE_BPS = 1000; // 10% APR
    uint256 internal constant MONTHS = 12;
    uint256 internal constant SCHEDULED_INTEREST = 100e6; // 1000 * 10% * 12/12

    function _deployPool(address[] memory approvers) internal virtual returns (address);

    function setUp() public {
        MockUSDC impl = new MockUSDC();
        usdc = MockUSDC(address(new ERC1967Proxy(address(impl), abi.encodeWithSelector(MockUSDC.initialize.selector))));
        address[] memory approvers = new address[](1);
        approvers[0] = approver;
        pool = ILoanPool(_deployPool(approvers));

        usdc.mint(address(pool), 1_000_000e6);
        usdc.mint(borrower, 10_000e6);
        vm.prank(borrower);
        usdc.approve(address(pool), type(uint256).max);

        pool.createLoan(LOAN, borrower, PRINCIPAL, RATE_BPS, MONTHS);
        pool.activateLoan(LOAN);
        assertEq(pool.loanIdToInterestAmount(LOAN), SCHEDULED_INTEREST, "fixture: scheduled interest");
    }

    function _repayFull() internal returns (uint256 paid) {
        uint256 before = usdc.balanceOf(address(pool));
        vm.prank(borrower);
        pool.makeRepayment(LOAN);
        paid = usdc.balanceOf(address(pool)) - before;
    }

    /// The reported bug: immediate full repayment must collect the full 100 USDC
    /// of scheduled interest, not one period (the bug paid ~0.76 USDC).
    function test_fullRepayment_collectsAllScheduledInterest() public {
        uint256 lentBefore = pool.totalLentAmount();
        uint256 paid = _repayFull();

        assertEq(paid, PRINCIPAL + SCHEDULED_INTEREST, "must pay principal + ALL scheduled interest");
        assertEq(pool.loanIdToInterestRepaymentAmount(LOAN), SCHEDULED_INTEREST, "interest ledger");
        assertEq(pool.loanIdToRepaymentAmount(LOAN), PRINCIPAL, "principal ledger");
        assertEq(lentBefore - pool.totalLentAmount(), PRINCIPAL, "totalLentAmount drops by principal only");
        assertFalse(pool.loanIdToActive(LOAN), "loan closed");
    }

    /// After an interest-only partial payment, the payoff covers the rest of the interest.
    function test_fullRepayment_afterInterestOnlyPartial() public {
        vm.prank(borrower);
        pool.makePartialRepayment(LOAN, 30e6);
        uint256 paid = _repayFull();

        assertEq(paid, PRINCIPAL + (SCHEDULED_INTEREST - 30e6), "payoff = principal + remaining interest");
        assertEq(pool.loanIdToInterestRepaymentAmount(LOAN), SCHEDULED_INTEREST, "all interest collected");
        assertFalse(pool.loanIdToActive(LOAN));
    }

    /// After a partial that cleared interest and some principal, payoff is principal only.
    function test_fullRepayment_afterPartialIntoPrincipal() public {
        vm.prank(borrower);
        pool.makePartialRepayment(LOAN, 150e6); // 100 interest + 50 principal
        uint256 paid = _repayFull();

        assertEq(paid, PRINCIPAL - 50e6, "interest already settled, only principal left");
        assertEq(pool.loanIdToInterestRepaymentAmount(LOAN), SCHEDULED_INTEREST);
        assertEq(pool.loanIdToRepaymentAmount(LOAN), PRINCIPAL);
        assertFalse(pool.loanIdToActive(LOAN));
    }

    /// Both close paths must cost the borrower exactly the same.
    function test_fullRepayment_matchesPartialClosePath() public {
        uint256 viaFull = _repayFull();
        assertEq(viaFull, PRINCIPAL + SCHEDULED_INTEREST);
        // makePartialRepayment's own cap is principal + remaining interest; closing with it costs the same.
        // (Checked on a second, fresh loan.)
        bytes32 loan2 = keccak256("loan-partial-close");
        pool.createLoan(loan2, borrower, PRINCIPAL, RATE_BPS, MONTHS);
        pool.activateLoan(loan2);
        uint256 before = usdc.balanceOf(address(pool));
        vm.prank(borrower);
        pool.makePartialRepayment(loan2, PRINCIPAL + SCHEDULED_INTEREST);
        assertEq(usdc.balanceOf(address(pool)) - before, viaFull, "close paths agree");
        assertFalse(pool.loanIdToActive(loan2));
    }

    /// A borrower funding only the old (principal + one period) amount can no longer close.
    function test_fullRepayment_revertsIfOnlyOnePeriodFunded() public {
        (, uint256 onePeriod) = pool.getNextRepayment(LOAN);
        assertLt(onePeriod, SCHEDULED_INTEREST, "fixture: one period < full interest");
        vm.startPrank(borrower);
        usdc.approve(address(pool), PRINCIPAL + onePeriod);
        vm.expectRevert();
        pool.makeRepayment(LOAN);
        vm.stopPrank();
        assertTrue(pool.loanIdToActive(LOAN), "loan stays open");
    }

    /// Rate cut after interest was already paid can leave scheduled < paid.
    /// Payoff must not underflow; it charges principal only.
    function test_fullRepayment_noUnderflowAfterRateCut() public {
        vm.prank(borrower);
        pool.makePartialRepayment(LOAN, 100e6); // all scheduled interest paid
        pool.updateLoanInterestRate(LOAN, 100); // recomputes interestAmount to 10 USDC < 100 paid
        assertLt(pool.loanIdToInterestAmount(LOAN), pool.loanIdToInterestRepaymentAmount(LOAN), "fixture");

        uint256 paid = _repayFull();
        assertEq(paid, PRINCIPAL, "principal only, no extra interest, no revert");
        assertFalse(pool.loanIdToActive(LOAN));
    }

    function testFuzz_fullRepayment_totalEqualsPrincipalPlusScheduled(uint96 partialAmt) public {
        uint256 p = bound(uint256(partialAmt), 0, PRINCIPAL + SCHEDULED_INTEREST - 1);
        uint256 paidPartial;
        if (p > 0) {
            vm.prank(borrower);
            pool.makePartialRepayment(LOAN, p);
            paidPartial = p;
        }
        uint256 paid = _repayFull();
        assertEq(paidPartial + paid, PRINCIPAL + SCHEDULED_INTEREST, "lifetime total is fixed");
        assertFalse(pool.loanIdToActive(LOAN));
    }
}

contract SimpleLoanPool_FullRepaymentInterestTest is FullRepaymentInterestBase {
    function _deployPool(address[] memory approvers) internal override returns (address) {
        SimpleLoanPool impl = new SimpleLoanPool();
        return address(new ERC1967Proxy(address(impl), abi.encodeWithSelector(SimpleLoanPool.initialize.selector, address(this), approvers, usdc)));
    }
}

contract CreditTreasuryPool_FullRepaymentInterestTest is FullRepaymentInterestBase {
    function _deployPool(address[] memory approvers) internal override returns (address) {
        CreditTreasuryPool impl = new CreditTreasuryPool();
        return address(new ERC1967Proxy(address(impl), abi.encodeWithSelector(CreditTreasuryPool.initialize.selector, address(this), approvers, usdc)));
    }
}
