// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EligibilityRegistry} from "../src/Compliance/EligibilityRegistry.sol";
import {IEligibilityRegistry} from "../src/Compliance/IEligibilityRegistry.sol";

/// @title EligibilityRegistryTest
/// @notice Comprehensive tests for SEC Reg D 506(b) compliance
contract EligibilityRegistryTest is Test {
    EligibilityRegistry public registry;

    address public admin = address(1);
    address public verifier = address(2);
    address public poolContract = address(3);
    address public investor1 = address(4);
    address public investor2 = address(5);
    address public unauthorized = address(6);

    uint256 public constant MAX_NON_ACCREDITED = 35;

    function setUp() public {
        // Deploy EligibilityRegistry
        address implementation = address(new EligibilityRegistry());
        bytes memory data = abi.encodeCall(
            EligibilityRegistry.initialize,
            (admin, MAX_NON_ACCREDITED)
        );
        address proxy = address(new ERC1967Proxy(implementation, data));
        registry = EligibilityRegistry(proxy);

        // Grant roles
        vm.startPrank(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        registry.grantRole(registry.POOL_ROLE(), poolContract);
        vm.stopPrank();
    }

    ///////////////////////////////////////////////////////////
    // INITIALIZATION TESTS
    ///////////////////////////////////////////////////////////

    function test_Initialize() public view {
        assertEq(registry.maxNonAccreditedInvestors(), MAX_NON_ACCREDITED);
        assertEq(registry.nonAccreditedInvestorCount(), 0);
        assertFalse(registry.upgradesLocked());
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.VERIFIER_ROLE(), admin));
        assertTrue(registry.hasRole(registry.UPGRADER_ROLE(), admin));
    }

    function test_Initialize_RevertIfZeroAddress() public {
        address implementation = address(new EligibilityRegistry());
        bytes memory data = abi.encodeCall(
            EligibilityRegistry.initialize,
            (address(0), MAX_NON_ACCREDITED)
        );

        vm.expectRevert(EligibilityRegistry.ZeroAddress.selector);
        new ERC1967Proxy(implementation, data);
    }

    ///////////////////////////////////////////////////////////
    // INVESTOR STATUS TESTS
    ///////////////////////////////////////////////////////////

    function test_SetInvestorStatus_Accredited() public {
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        assertEq(
            uint256(registry.getInvestorStatus(investor1)),
            uint256(IEligibilityRegistry.InvestorStatus.ACCREDITED)
        );
    }

    function test_SetInvestorStatus_NonAccredited() public {
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

        assertEq(
            uint256(registry.getInvestorStatus(investor1)),
            uint256(IEligibilityRegistry.InvestorStatus.NON_ACCREDITED)
        );
    }

    function test_SetInvestorStatus_RevertIfNotVerifier() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);
    }

    function test_SetInvestorStatus_RevertIfZeroAddress() public {
        vm.prank(verifier);
        vm.expectRevert(EligibilityRegistry.ZeroAddress.selector);
        registry.setInvestorStatus(address(0), IEligibilityRegistry.InvestorStatus.ACCREDITED);
    }

    function test_SetInvestorStatus_RevertIfAlreadyInvested() public {
        // Set status and mark as invested
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        vm.prank(poolContract);
        registry.markAsInvested(investor1);

        // Try to change status after investment
        vm.prank(verifier);
        vm.expectRevert(EligibilityRegistry.InvestorAlreadyInvested.selector);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);
    }

    ///////////////////////////////////////////////////////////
    // CAN INVEST TESTS
    ///////////////////////////////////////////////////////////

    function test_CanInvest_AccreditedInvestor() public {
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        (bool canInvest, string memory reason) = registry.canInvest(investor1);
        assertTrue(canInvest);
        assertEq(reason, "");
    }

    function test_CanInvest_NonAccreditedInvestor() public {
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

        (bool canInvest, string memory reason) = registry.canInvest(investor1);
        assertTrue(canInvest);
        assertEq(reason, "");
    }

    function test_CanInvest_IneligibleInvestor() public {
        // Default status is INELIGIBLE
        (bool canInvest, string memory reason) = registry.canInvest(investor1);
        assertFalse(canInvest);
        assertEq(reason, "Investor not verified");
    }

    function test_CanInvest_ZeroAddress() public {
        (bool canInvest, string memory reason) = registry.canInvest(address(0));
        assertFalse(canInvest);
        assertEq(reason, "Invalid address");
    }

    ///////////////////////////////////////////////////////////
    // 35 NON-ACCREDITED INVESTOR LIMIT TESTS (506(b) CORE)
    ///////////////////////////////////////////////////////////

    function test_NonAccreditedLimit_AtLimit() public {
        // Set up 35 non-accredited investors
        for (uint256 i = 0; i < MAX_NON_ACCREDITED; i++) {
            address investor = address(uint160(100 + i));

            vm.prank(verifier);
            registry.setInvestorStatus(investor, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

            vm.prank(poolContract);
            registry.markAsInvested(investor);
        }

        // Verify count
        assertEq(registry.nonAccreditedInvestorCount(), MAX_NON_ACCREDITED);

        // 36th non-accredited investor should be rejected
        address investor36 = address(uint160(200));
        vm.prank(verifier);
        registry.setInvestorStatus(investor36, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

        (bool canInvest, string memory reason) = registry.canInvest(investor36);
        assertFalse(canInvest);
        assertEq(reason, "Non-accredited investor limit reached");
    }

    function test_NonAccreditedLimit_MarkAsInvestedReverts() public {
        // Fill up to 35 non-accredited investors
        for (uint256 i = 0; i < MAX_NON_ACCREDITED; i++) {
            address investor = address(uint160(100 + i));

            vm.prank(verifier);
            registry.setInvestorStatus(investor, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

            vm.prank(poolContract);
            registry.markAsInvested(investor);
        }

        // Try to mark 36th non-accredited as invested
        address investor36 = address(uint160(200));
        vm.prank(verifier);
        registry.setInvestorStatus(investor36, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

        vm.prank(poolContract);
        vm.expectRevert(EligibilityRegistry.MaxNonAccreditedReached.selector);
        registry.markAsInvested(investor36);
    }

    function test_NonAccreditedLimit_AccreditedNotCounted() public {
        // Fill up to 35 non-accredited
        for (uint256 i = 0; i < MAX_NON_ACCREDITED; i++) {
            address investor = address(uint160(100 + i));

            vm.prank(verifier);
            registry.setInvestorStatus(investor, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

            vm.prank(poolContract);
            registry.markAsInvested(investor);
        }

        // Accredited investors should still be allowed
        address accreditedInvestor = address(uint160(200));
        vm.prank(verifier);
        registry.setInvestorStatus(accreditedInvestor, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        (bool canInvest, ) = registry.canInvest(accreditedInvestor);
        assertTrue(canInvest);

        // Should not revert when marking as invested
        vm.prank(poolContract);
        registry.markAsInvested(accreditedInvestor);

        // Count should still be 35 (accredited not counted)
        assertEq(registry.nonAccreditedInvestorCount(), MAX_NON_ACCREDITED);
    }

    function test_NonAccreditedLimit_ExistingInvestorCanAddMore() public {
        // Set up investor and mark as invested
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

        vm.prank(poolContract);
        registry.markAsInvested(investor1);

        // Fill remaining 34 slots
        for (uint256 i = 0; i < MAX_NON_ACCREDITED - 1; i++) {
            address investor = address(uint160(100 + i));

            vm.prank(verifier);
            registry.setInvestorStatus(investor, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

            vm.prank(poolContract);
            registry.markAsInvested(investor);
        }

        // Existing investor should still be allowed to invest more
        (bool canInvest, ) = registry.canInvest(investor1);
        assertTrue(canInvest);
    }

    ///////////////////////////////////////////////////////////
    // MARK AS INVESTED TESTS
    ///////////////////////////////////////////////////////////

    function test_MarkAsInvested_Success() public {
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        assertFalse(registry.hasInvested(investor1));

        vm.prank(poolContract);
        registry.markAsInvested(investor1);

        assertTrue(registry.hasInvested(investor1));
    }

    function test_MarkAsInvested_RevertIfNotPoolRole() public {
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        vm.prank(unauthorized);
        vm.expectRevert();
        registry.markAsInvested(investor1);
    }

    function test_MarkAsInvested_RevertIfZeroAddress() public {
        vm.prank(poolContract);
        vm.expectRevert(EligibilityRegistry.ZeroAddress.selector);
        registry.markAsInvested(address(0));
    }

    function test_MarkAsInvested_Idempotent() public {
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

        vm.prank(poolContract);
        registry.markAsInvested(investor1);

        uint256 countBefore = registry.nonAccreditedInvestorCount();

        // Mark again - should be no-op
        vm.prank(poolContract);
        registry.markAsInvested(investor1);

        uint256 countAfter = registry.nonAccreditedInvestorCount();
        assertEq(countBefore, countAfter);
    }

    ///////////////////////////////////////////////////////////
    // UPGRADE LOCKING TESTS (REGULATORY COMPLIANCE)
    ///////////////////////////////////////////////////////////

    function test_UpgradesLocked_AfterFirstInvestment() public {
        assertFalse(registry.upgradesLocked());

        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        vm.prank(poolContract);
        registry.markAsInvested(investor1);

        assertTrue(registry.upgradesLocked());
    }

    function test_SetMaxNonAccredited_RevertIfLocked() public {
        // Make an investment to lock upgrades
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        vm.prank(poolContract);
        registry.markAsInvested(investor1);

        // Try to change max
        vm.prank(admin);
        vm.expectRevert(EligibilityRegistry.UpgradesAreLocked.selector);
        registry.setMaxNonAccreditedInvestors(50);
    }

    function test_SetMaxNonAccredited_AllowedBeforeInvestment() public {
        vm.prank(admin);
        registry.setMaxNonAccreditedInvestors(50);

        assertEq(registry.maxNonAccreditedInvestors(), 50);
    }

    ///////////////////////////////////////////////////////////
    // VIEW FUNCTIONS TESTS
    ///////////////////////////////////////////////////////////

    function test_GetNonAccreditedInvestorCount() public {
        assertEq(registry.getNonAccreditedInvestorCount(), 0);

        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

        vm.prank(poolContract);
        registry.markAsInvested(investor1);

        assertEq(registry.getNonAccreditedInvestorCount(), 1);
    }

    function test_GetMaxNonAccreditedInvestors() public view {
        assertEq(registry.getMaxNonAccreditedInvestors(), MAX_NON_ACCREDITED);
    }

    function test_AreUpgradesLocked() public {
        assertFalse(registry.areUpgradesLocked());

        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        vm.prank(poolContract);
        registry.markAsInvested(investor1);

        assertTrue(registry.areUpgradesLocked());
    }

    ///////////////////////////////////////////////////////////
    // EVENT TESTS
    ///////////////////////////////////////////////////////////

    function test_Event_InvestorStatusUpdated() public {
        vm.prank(verifier);
        vm.expectEmit(true, false, false, true);
        emit IEligibilityRegistry.InvestorStatusUpdated(
            investor1,
            IEligibilityRegistry.InvestorStatus.INELIGIBLE,
            IEligibilityRegistry.InvestorStatus.ACCREDITED
        );
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);
    }

    function test_Event_InvestorMarkedAsInvested() public {
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        vm.prank(poolContract);
        vm.expectEmit(true, false, false, true);
        emit IEligibilityRegistry.InvestorMarkedAsInvested(
            investor1,
            IEligibilityRegistry.InvestorStatus.ACCREDITED
        );
        registry.markAsInvested(investor1);
    }

    function test_Event_UpgradesLocked() public {
        vm.prank(verifier);
        registry.setInvestorStatus(investor1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        vm.prank(poolContract);
        vm.expectEmit(false, false, false, true);
        emit IEligibilityRegistry.UpgradesLocked();
        registry.markAsInvested(investor1);
    }
}
