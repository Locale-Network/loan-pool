// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakingPool} from "../src/Staking/StakingPool.sol";
import {UpgradeableCommunityToken} from "../src/ERC20/UpgradeableCommunityToken.sol";
import {EligibilityRegistry} from "../src/Compliance/EligibilityRegistry.sol";
import {IEligibilityRegistry} from "../src/Compliance/IEligibilityRegistry.sol";

contract StakingPoolTest is Test {
    StakingPool public stakingPool;
    UpgradeableCommunityToken public token;

    address public owner = address(1);
    address public feeRecipient = address(2);
    address public user1 = address(3);
    address public user2 = address(4);

    bytes32 public constant POOL_ID = keccak256("TEST_POOL");
    uint256 public constant MINIMUM_STAKE = 100 * 1e6; // 100 USDC
    uint256 public constant FEE_RATE = 300; // 3%
    uint256 public constant COOLDOWN = 7 days;

    function setUp() public {
        // Deploy mock token
        address tokenImplementation = address(new UpgradeableCommunityToken());
        address[] memory minters = new address[](1);
        minters[0] = owner;
        bytes memory tokenData = abi.encodeCall(
            UpgradeableCommunityToken.initialize,
            (owner, minters, "Mock USDC", "mUSDC")
        );
        address tokenProxy = address(new ERC1967Proxy(tokenImplementation, tokenData));
        token = UpgradeableCommunityToken(tokenProxy);

        // Deploy StakingPool
        address implementation = address(new StakingPool());
        bytes memory data = abi.encodeCall(
            StakingPool.initialize,
            (owner, IERC20(address(token)), feeRecipient, COOLDOWN)
        );
        address proxy = address(new ERC1967Proxy(implementation, data));
        stakingPool = StakingPool(proxy);

        // Mint tokens to users
        vm.startPrank(owner);
        token.mint(user1, 10000 * 1e6);
        token.mint(user2, 10000 * 1e6);
        vm.stopPrank();

        // Approve staking pool
        vm.prank(user1);
        token.approve(address(stakingPool), type(uint256).max);
        vm.prank(user2);
        token.approve(address(stakingPool), type(uint256).max);
    }

    function test_Initialize() public view {
        assertEq(address(stakingPool.stakingToken()), address(token));
        assertEq(stakingPool.feeRecipient(), feeRecipient);
        assertEq(stakingPool.cooldownPeriod(), COOLDOWN);
        assertTrue(stakingPool.hasRole(stakingPool.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(stakingPool.hasRole(stakingPool.POOL_MANAGER_ROLE(), owner));
    }

    function test_CreatePool() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        (
            string memory name,
            uint256 minimumStake,
            uint256 totalStaked,
            uint256 totalShares,
            uint256 feeRate,
            uint256 cooldownPeriod,
            uint256 maturityDate,
            address eligibilityRegistry,
            bool active,
        ) = stakingPool.getPool(POOL_ID);

        assertEq(name, "Test Pool");
        assertEq(minimumStake, MINIMUM_STAKE);
        assertEq(totalStaked, 0);
        assertEq(totalShares, 0);
        assertEq(feeRate, FEE_RATE);
        assertEq(cooldownPeriod, COOLDOWN);
        assertEq(maturityDate, 0);
        assertEq(eligibilityRegistry, address(0));
        assertTrue(active);
    }

    function test_CreatePool_RevertIfNotManager() public {
        vm.prank(user1);
        vm.expectRevert();
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));
    }

    function test_Stake() public {
        // Create pool first
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        uint256 stakeAmount = 1000 * 1e6;
        uint256 expectedFee = (stakeAmount * FEE_RATE) / 10000;
        uint256 expectedNet = stakeAmount - expectedFee;

        uint256 user1BalanceBefore = token.balanceOf(user1);
        uint256 feeRecipientBalanceBefore = token.balanceOf(feeRecipient);

        vm.prank(user1);
        stakingPool.stake(POOL_ID, stakeAmount);

        // Check user stake
        (, uint256 amount, uint256 shares, , , , ) = stakingPool.getUserStake(POOL_ID, user1);
        assertEq(amount, expectedNet);
        assertEq(shares, expectedNet); // First staker gets 1:1 shares

        // Check balances
        assertEq(token.balanceOf(user1), user1BalanceBefore - stakeAmount);
        assertEq(token.balanceOf(feeRecipient), feeRecipientBalanceBefore + expectedFee);

        // Check pool stats
        (, , uint256 totalStaked, uint256 totalShares, , , , , , ) = stakingPool.getPool(POOL_ID);
        assertEq(totalStaked, expectedNet);
        assertEq(totalShares, expectedNet);
    }

    function test_Stake_RevertIfBelowMinimum() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        vm.expectRevert(StakingPool.BelowMinimumStake.selector);
        stakingPool.stake(POOL_ID, 50 * 1e6); // Below minimum
    }

    function test_Stake_RevertIfPoolNotActive() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        // Deactivate pool
        vm.prank(owner);
        stakingPool.updatePool(POOL_ID, MINIMUM_STAKE, FEE_RATE, false);

        vm.prank(user1);
        vm.expectRevert(StakingPool.PoolNotActive.selector);
        stakingPool.stake(POOL_ID, 1000 * 1e6);
    }

    function test_RequestUnstake() public {
        // Setup: create pool and stake
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        uint256 unstakeAmount = 500 * 1e6;

        vm.prank(user1);
        stakingPool.requestUnstake(POOL_ID, unstakeAmount);

        (, uint256 amount, , , uint256 pendingUnstake, uint256 canWithdrawAt, ) =
            stakingPool.getUserStake(POOL_ID, user1);

        assertGt(amount, 0);
        assertEq(pendingUnstake, unstakeAmount);
        assertEq(canWithdrawAt, block.timestamp + COOLDOWN);
    }

    function test_RequestUnstake_RevertIfBelowMinimum() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        vm.prank(user1);
        vm.expectRevert(StakingPool.BelowMinimumUnstake.selector);
        stakingPool.requestUnstake(POOL_ID, 0.5e6);
    }

    function test_RequestUnstake_RevertIfPoolNotFound() public {
        bytes32 nonExistentPool = keccak256("NONEXISTENT");

        vm.prank(user1);
        vm.expectRevert(StakingPool.PoolNotFound.selector);
        stakingPool.requestUnstake(nonExistentPool, 100 * 1e6);
    }

    function test_CompleteUnstake() public {
        // Setup: create pool and stake
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        (, uint256 stakedAmount, , , , , ) = stakingPool.getUserStake(POOL_ID, user1);

        // Request unstake
        vm.prank(user1);
        stakingPool.requestUnstake(POOL_ID, stakedAmount);

        // Try to unstake before cooldown - should fail
        vm.prank(user1);
        vm.expectRevert(StakingPool.CooldownNotComplete.selector);
        stakingPool.completeUnstake(POOL_ID);

        // Advance time past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 user1BalanceBefore = token.balanceOf(user1);

        // Complete unstake
        vm.prank(user1);
        stakingPool.completeUnstake(POOL_ID);

        // Check user received tokens
        assertEq(token.balanceOf(user1), user1BalanceBefore + stakedAmount);

        // Check stake is cleared
        (, uint256 amount, uint256 shares, , uint256 pendingUnstake, , ) =
            stakingPool.getUserStake(POOL_ID, user1);
        assertEq(amount, 0);
        assertEq(shares, 0);
        assertEq(pendingUnstake, 0);
    }

    function test_CancelUnstake() public {
        // Setup: create pool and stake
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        (, uint256 stakedAmount, , , , , ) = stakingPool.getUserStake(POOL_ID, user1);

        // Request unstake
        vm.prank(user1);
        stakingPool.requestUnstake(POOL_ID, stakedAmount);

        // Cancel unstake
        vm.prank(user1);
        stakingPool.cancelUnstake(POOL_ID);

        // Check pending unstake is cleared
        (, , , , uint256 pendingUnstake, uint256 canWithdrawAt, ) =
            stakingPool.getUserStake(POOL_ID, user1);
        assertEq(pendingUnstake, 0);
        assertEq(canWithdrawAt, 0);
    }

    function test_DistributeYield() public {
        // Setup: create pool and stake from two users
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        vm.prank(user2);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        // Get initial stake values
        uint256 user1ValueBefore = stakingPool.getStakeValue(POOL_ID, user1);
        uint256 user2ValueBefore = stakingPool.getStakeValue(POOL_ID, user2);

        // Distribute yield
        uint256 yieldAmount = 100 * 1e6;
        vm.startPrank(owner);
        token.mint(owner, yieldAmount);
        token.approve(address(stakingPool), yieldAmount);
        stakingPool.distributeYield(POOL_ID, yieldAmount);
        vm.stopPrank();

        // Check stake values increased
        uint256 user1ValueAfter = stakingPool.getStakeValue(POOL_ID, user1);
        uint256 user2ValueAfter = stakingPool.getStakeValue(POOL_ID, user2);

        assertGt(user1ValueAfter, user1ValueBefore);
        assertGt(user2ValueAfter, user2ValueBefore);

        // Each user should have roughly half the yield (proportional to shares)
        uint256 user1Gain = user1ValueAfter - user1ValueBefore;
        uint256 user2Gain = user2ValueAfter - user2ValueBefore;

        // Allow for small rounding differences
        assertApproxEqAbs(user1Gain, yieldAmount / 2, 1);
        assertApproxEqAbs(user2Gain, yieldAmount / 2, 1);
    }

    function test_Pause() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(owner);
        stakingPool.pause();

        vm.prank(user1);
        vm.expectRevert();
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        vm.prank(owner);
        stakingPool.unpause();

        // Should work now
        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);
    }

    function test_GetAllPoolIds() public {
        bytes32 pool1 = keccak256("POOL1");
        bytes32 pool2 = keccak256("POOL2");

        vm.startPrank(owner);
        stakingPool.createPool(pool1, "Pool 1", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));
        stakingPool.createPool(pool2, "Pool 2", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));
        vm.stopPrank();

        bytes32[] memory poolIds = stakingPool.getAllPoolIds();
        assertEq(poolIds.length, 2);
        assertEq(poolIds[0], pool1);
        assertEq(poolIds[1], pool2);
    }

    function test_CooldownPeriodLocked() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        (, uint256 stakedAmount, , , , , ) = stakingPool.getUserStake(POOL_ID, user1);

        vm.prank(user1);
        stakingPool.requestUnstake(POOL_ID, stakedAmount);

        (, , , , , uint256 canWithdrawAtBefore, ) = stakingPool.getUserStake(POOL_ID, user1);

        vm.prank(owner);
        stakingPool.setCooldownPeriod(30 days);

        (, , , , , uint256 canWithdrawAtAfter, ) = stakingPool.getUserStake(POOL_ID, user1);

        assertEq(canWithdrawAtBefore, canWithdrawAtAfter);
    }

    function test_UnstakePrecisionLoss_RevertOnZeroShares() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        (, uint256 stakedAmount, , , , , ) = stakingPool.getUserStake(POOL_ID, user1);

        vm.prank(user1);
        stakingPool.requestUnstake(POOL_ID, 1e6);

        vm.warp(block.timestamp + COOLDOWN + 1);

        (, , uint256 sharesBefore, , , , ) = stakingPool.getUserStake(POOL_ID, user1);
        uint256 sharesToBurn = (1e6 * sharesBefore) / stakedAmount;

        if (sharesToBurn == 0) {
            vm.prank(user1);
            vm.expectRevert(StakingPool.InsufficientShares.selector);
            stakingPool.completeUnstake(POOL_ID);
        } else {
            vm.prank(user1);
            stakingPool.completeUnstake(POOL_ID);
        }
    }

    function test_RecoverToken() public {
        UpgradeableCommunityToken otherToken = new UpgradeableCommunityToken();
        address otherTokenImpl = address(otherToken);
        address[] memory minters = new address[](1);
        minters[0] = owner;
        bytes memory data = abi.encodeCall(
            UpgradeableCommunityToken.initialize,
            (owner, minters, "Other Token", "OTHER")
        );
        address otherTokenProxy = address(new ERC1967Proxy(otherTokenImpl, data));
        UpgradeableCommunityToken otherTokenContract = UpgradeableCommunityToken(otherTokenProxy);

        vm.startPrank(owner);
        otherTokenContract.mint(address(stakingPool), 1000 * 1e6);

        stakingPool.recoverToken(IERC20(address(otherTokenContract)), 1000 * 1e6, owner);
        vm.stopPrank();

        assertEq(otherTokenContract.balanceOf(owner), 1000 * 1e6);
    }

    function test_RecoverToken_RevertIfStakingToken() public {
        vm.prank(owner);
        vm.expectRevert(StakingPool.InvalidAddress.selector);
        stakingPool.recoverToken(IERC20(address(token)), 1000 * 1e6, owner);
    }

    function test_GetStakeValue_RevertIfPoolNotFound() public {
        bytes32 nonExistentPool = keccak256("NONEXISTENT");

        vm.expectRevert(StakingPool.PoolNotFound.selector);
        stakingPool.getStakeValue(nonExistentPool, user1);
    }

    function test_TransferToLoanPool() public {
        // Setup: create pool and stake
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        uint256 poolBalanceBefore = token.balanceOf(address(stakingPool));
        address mockLoanPool = address(100);
        uint256 transferAmount = 500 * 1e6;

        // Transfer to loan pool
        vm.prank(owner);
        stakingPool.transferToLoanPool(transferAmount, mockLoanPool);

        // Check balances
        assertEq(token.balanceOf(address(stakingPool)), poolBalanceBefore - transferAmount);
        assertEq(token.balanceOf(mockLoanPool), transferAmount);

        // Check tracking
        assertEq(stakingPool.totalTransferredToLoanPool(), transferAmount);
    }

    function test_TransferToLoanPool_RevertIfNotManager() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        vm.prank(user1);
        vm.expectRevert();
        stakingPool.transferToLoanPool(500 * 1e6, address(100));
    }

    function test_TransferToLoanPool_RevertIfZeroAmount() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        vm.prank(owner);
        vm.expectRevert(StakingPool.ZeroAmount.selector);
        stakingPool.transferToLoanPool(0, address(100));
    }

    function test_TransferToLoanPool_RevertIfInsufficientBalance() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        uint256 poolBalance = token.balanceOf(address(stakingPool));

        vm.prank(owner);
        vm.expectRevert("Insufficient pool balance");
        stakingPool.transferToLoanPool(poolBalance + 1, address(100));
    }

    function test_TransferToLoanPool_RevertIfInvalidAddress() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        vm.prank(owner);
        vm.expectRevert(StakingPool.InvalidAddress.selector);
        stakingPool.transferToLoanPool(500 * 1e6, address(0));
    }

    ///////////////////////////////////////////////////////////
    // 506(b) COMPLIANCE - ELIGIBILITY REGISTRY INTEGRATION
    ///////////////////////////////////////////////////////////

    function _deployEligibilityRegistry() internal returns (EligibilityRegistry) {
        address registryImpl = address(new EligibilityRegistry());
        bytes memory data = abi.encodeCall(
            EligibilityRegistry.initialize,
            (owner, 35) // 35 non-accredited investor limit
        );
        address proxy = address(new ERC1967Proxy(registryImpl, data));
        EligibilityRegistry registry = EligibilityRegistry(proxy);

        // Get role before pranking (to avoid prank consumption)
        bytes32 poolRole = registry.POOL_ROLE();

        // Grant POOL_ROLE to staking pool
        vm.prank(owner);
        registry.grantRole(poolRole, address(stakingPool));

        return registry;
    }

    function test_CreatePoolWithEligibilityRegistry() public {
        EligibilityRegistry registry = _deployEligibilityRegistry();

        bytes32 regDPoolId = keccak256("REG_D_POOL");

        vm.prank(owner);
        stakingPool.createPool(
            regDPoolId,
            "Reg D 506(b) Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            COOLDOWN,
            0,
            address(registry)
        );

        (, , , , , , , address poolRegistry, , ) = stakingPool.getPool(regDPoolId);
        assertEq(poolRegistry, address(registry));
    }

    function test_StakeWithEligibilityRegistry_AccreditedInvestor() public {
        EligibilityRegistry registry = _deployEligibilityRegistry();

        bytes32 regDPoolId = keccak256("REG_D_POOL");

        // Create pool with eligibility registry
        vm.prank(owner);
        stakingPool.createPool(
            regDPoolId,
            "Reg D 506(b) Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            COOLDOWN,
            0,
            address(registry)
        );

        // Set user1 as accredited investor
        vm.prank(owner);
        registry.setInvestorStatus(user1, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        // User1 should be able to stake
        vm.prank(user1);
        stakingPool.stake(regDPoolId, 1000 * 1e6);

        (, uint256 amount, , , , , ) = stakingPool.getUserStake(regDPoolId, user1);
        assertGt(amount, 0);

        // Verify marked as invested
        assertTrue(registry.hasInvested(user1));
    }

    function test_StakeWithEligibilityRegistry_NonAccreditedInvestor() public {
        EligibilityRegistry registry = _deployEligibilityRegistry();

        bytes32 regDPoolId = keccak256("REG_D_POOL");

        vm.prank(owner);
        stakingPool.createPool(
            regDPoolId,
            "Reg D 506(b) Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            COOLDOWN,
            0,
            address(registry)
        );

        // Set user1 as non-accredited investor
        vm.prank(owner);
        registry.setInvestorStatus(user1, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

        // User1 should be able to stake (within 35 limit)
        vm.prank(user1);
        stakingPool.stake(regDPoolId, 1000 * 1e6);

        (, uint256 amount, , , , , ) = stakingPool.getUserStake(regDPoolId, user1);
        assertGt(amount, 0);

        // Verify count increased
        assertEq(registry.getNonAccreditedInvestorCount(), 1);
    }

    function test_StakeWithEligibilityRegistry_RevertIfIneligible() public {
        EligibilityRegistry registry = _deployEligibilityRegistry();

        bytes32 regDPoolId = keccak256("REG_D_POOL");

        vm.prank(owner);
        stakingPool.createPool(
            regDPoolId,
            "Reg D 506(b) Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            COOLDOWN,
            0,
            address(registry)
        );

        // user1 is not verified (default INELIGIBLE status)
        vm.prank(user1);
        vm.expectRevert(StakingPool.InvestorNotEligible.selector);
        stakingPool.stake(regDPoolId, 1000 * 1e6);
    }

    function test_StakeWithEligibilityRegistry_35NonAccreditedLimit() public {
        EligibilityRegistry registry = _deployEligibilityRegistry();

        bytes32 regDPoolId = keccak256("REG_D_POOL");

        vm.prank(owner);
        stakingPool.createPool(
            regDPoolId,
            "Reg D 506(b) Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            COOLDOWN,
            0,
            address(registry)
        );

        // Fill up 35 non-accredited investors
        for (uint256 i = 0; i < 35; i++) {
            address investor = address(uint160(100 + i));

            // Mint and approve tokens
            vm.prank(owner);
            token.mint(investor, 1000 * 1e6);
            vm.prank(investor);
            token.approve(address(stakingPool), type(uint256).max);

            // Set as non-accredited
            vm.prank(owner);
            registry.setInvestorStatus(investor, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

            // Stake
            vm.prank(investor);
            stakingPool.stake(regDPoolId, MINIMUM_STAKE);
        }

        // 36th non-accredited investor should fail
        address investor36 = address(uint160(200));
        vm.prank(owner);
        token.mint(investor36, 1000 * 1e6);
        vm.prank(investor36);
        token.approve(address(stakingPool), type(uint256).max);

        vm.prank(owner);
        registry.setInvestorStatus(investor36, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

        vm.prank(investor36);
        vm.expectRevert(StakingPool.InvestorNotEligible.selector);
        stakingPool.stake(regDPoolId, MINIMUM_STAKE);
    }

    function test_StakeWithEligibilityRegistry_AccreditedBypassesLimit() public {
        EligibilityRegistry registry = _deployEligibilityRegistry();

        bytes32 regDPoolId = keccak256("REG_D_POOL");

        vm.prank(owner);
        stakingPool.createPool(
            regDPoolId,
            "Reg D 506(b) Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            COOLDOWN,
            0,
            address(registry)
        );

        // Fill up 35 non-accredited investors
        for (uint256 i = 0; i < 35; i++) {
            address investor = address(uint160(100 + i));

            vm.prank(owner);
            token.mint(investor, 1000 * 1e6);
            vm.prank(investor);
            token.approve(address(stakingPool), type(uint256).max);

            vm.prank(owner);
            registry.setInvestorStatus(investor, IEligibilityRegistry.InvestorStatus.NON_ACCREDITED);

            vm.prank(investor);
            stakingPool.stake(regDPoolId, MINIMUM_STAKE);
        }

        // Accredited investor should still be able to invest
        address accreditedInvestor = address(uint160(300));
        vm.prank(owner);
        token.mint(accreditedInvestor, 1000 * 1e6);
        vm.prank(accreditedInvestor);
        token.approve(address(stakingPool), type(uint256).max);

        vm.prank(owner);
        registry.setInvestorStatus(accreditedInvestor, IEligibilityRegistry.InvestorStatus.ACCREDITED);

        vm.prank(accreditedInvestor);
        stakingPool.stake(regDPoolId, MINIMUM_STAKE);

        (, uint256 amount, , , , , ) = stakingPool.getUserStake(regDPoolId, accreditedInvestor);
        assertGt(amount, 0);
    }

    ///////////////////////////////////////////////////////////
    // 506(b) COMPLIANCE - MATURITY DATE & YIELD CLAIMING
    ///////////////////////////////////////////////////////////

    function test_CreatePoolWithMaturityDate() public {
        bytes32 maturityPoolId = keccak256("MATURITY_POOL");
        uint256 maturityDate = block.timestamp + 365 days;

        vm.prank(owner);
        stakingPool.createPool(
            maturityPoolId,
            "1 Year Maturity Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            365 days, // Long cooldown for loan term matching
            maturityDate,
            address(0)
        );

        (, , , , , , uint256 poolMaturityDate, , , ) = stakingPool.getPool(maturityPoolId);
        assertEq(poolMaturityDate, maturityDate);
    }

    function test_RequestUnstake_RevertIfPoolHasMaturityDate() public {
        bytes32 maturityPoolId = keccak256("MATURITY_POOL");
        uint256 maturityDate = block.timestamp + 365 days;

        vm.prank(owner);
        stakingPool.createPool(
            maturityPoolId,
            "1 Year Maturity Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            365 days,
            maturityDate,
            address(0)
        );

        vm.prank(user1);
        stakingPool.stake(maturityPoolId, 1000 * 1e6);

        // Regular unstake should fail on pools with maturity dates
        vm.prank(user1);
        vm.expectRevert(StakingPool.PoolNotMatured.selector);
        stakingPool.requestUnstake(maturityPoolId, 500 * 1e6);
    }

    function test_ClaimYield() public {
        bytes32 maturityPoolId = keccak256("MATURITY_POOL");
        uint256 maturityDate = block.timestamp + 365 days;

        vm.prank(owner);
        stakingPool.createPool(
            maturityPoolId,
            "1 Year Maturity Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            365 days,
            maturityDate,
            address(0)
        );

        vm.prank(user1);
        stakingPool.stake(maturityPoolId, 1000 * 1e6);

        // Distribute some yield
        uint256 yieldAmount = 50 * 1e6;
        vm.startPrank(owner);
        token.mint(owner, yieldAmount);
        token.approve(address(stakingPool), yieldAmount);
        stakingPool.distributeYield(maturityPoolId, yieldAmount);
        vm.stopPrank();

        // Check available yield
        uint256 availableYield = stakingPool.getAvailableYield(maturityPoolId, user1);
        assertGt(availableYield, 0);

        uint256 user1BalanceBefore = token.balanceOf(user1);

        // Claim yield (should work even before maturity)
        vm.prank(user1);
        stakingPool.claimYield(maturityPoolId);

        // Verify yield was received
        uint256 user1BalanceAfter = token.balanceOf(user1);
        assertGt(user1BalanceAfter, user1BalanceBefore);
    }

    function test_ClaimYield_RevertIfNoYield() public {
        bytes32 maturityPoolId = keccak256("MATURITY_POOL");

        vm.prank(owner);
        stakingPool.createPool(
            maturityPoolId,
            "1 Year Maturity Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            365 days,
            block.timestamp + 365 days,
            address(0)
        );

        vm.prank(user1);
        stakingPool.stake(maturityPoolId, 1000 * 1e6);

        // No yield distributed yet
        vm.prank(user1);
        vm.expectRevert(StakingPool.NoYieldToClaim.selector);
        stakingPool.claimYield(maturityPoolId);
    }

    function test_UnstakeAtMaturity() public {
        bytes32 maturityPoolId = keccak256("MATURITY_POOL");
        uint256 maturityDate = block.timestamp + 365 days;

        vm.prank(owner);
        stakingPool.createPool(
            maturityPoolId,
            "1 Year Maturity Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            365 days,
            maturityDate,
            address(0)
        );

        vm.prank(user1);
        stakingPool.stake(maturityPoolId, 1000 * 1e6);

        (, uint256 stakedAmount, , , , , ) = stakingPool.getUserStake(maturityPoolId, user1);

        // Try to unstake before maturity - should fail
        vm.prank(user1);
        vm.expectRevert(StakingPool.PoolNotMatured.selector);
        stakingPool.unstakeAtMaturity(maturityPoolId);

        // Advance time past maturity
        vm.warp(maturityDate + 1);

        uint256 user1BalanceBefore = token.balanceOf(user1);

        // Now should work
        vm.prank(user1);
        stakingPool.unstakeAtMaturity(maturityPoolId);

        // Verify received tokens
        uint256 user1BalanceAfter = token.balanceOf(user1);
        assertEq(user1BalanceAfter, user1BalanceBefore + stakedAmount);

        // Verify stake is cleared
        (, uint256 amount, uint256 shares, , , , ) = stakingPool.getUserStake(maturityPoolId, user1);
        assertEq(amount, 0);
        assertEq(shares, 0);
    }

    function test_UnstakeAtMaturity_WithYieldDistributed() public {
        bytes32 maturityPoolId = keccak256("MATURITY_POOL");
        uint256 maturityDate = block.timestamp + 365 days;

        vm.prank(owner);
        stakingPool.createPool(
            maturityPoolId,
            "1 Year Maturity Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            365 days,
            maturityDate,
            address(0)
        );

        vm.prank(user1);
        stakingPool.stake(maturityPoolId, 1000 * 1e6);

        // Distribute yield
        uint256 yieldAmount = 100 * 1e6;
        vm.startPrank(owner);
        token.mint(owner, yieldAmount);
        token.approve(address(stakingPool), yieldAmount);
        stakingPool.distributeYield(maturityPoolId, yieldAmount);
        vm.stopPrank();

        // Get total stake value (principal + yield)
        uint256 stakeValue = stakingPool.getStakeValue(maturityPoolId, user1);

        // Advance time past maturity
        vm.warp(maturityDate + 1);

        uint256 user1BalanceBefore = token.balanceOf(user1);

        // Unstake at maturity (should get principal + yield)
        vm.prank(user1);
        stakingPool.unstakeAtMaturity(maturityPoolId);

        uint256 user1BalanceAfter = token.balanceOf(user1);

        // Should receive full stake value (principal + yield)
        assertApproxEqAbs(user1BalanceAfter - user1BalanceBefore, stakeValue, 1);
    }

    function test_UnstakeAtMaturity_RevertIfNoMaturityDate() public {
        // Create pool without maturity date
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE, COOLDOWN, 0, address(0));

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        // Should fail - no maturity date set
        vm.prank(user1);
        vm.expectRevert(StakingPool.PoolNotMatured.selector);
        stakingPool.unstakeAtMaturity(POOL_ID);
    }

    function test_CreatePool_RevertIfInvalidMaturityDate() public {
        bytes32 invalidPoolId = keccak256("INVALID_MATURITY");

        // Warp to a reasonable timestamp (Foundry starts at 1)
        vm.warp(1000000);

        // Maturity date in the past should fail
        vm.prank(owner);
        vm.expectRevert(StakingPool.InvalidMaturityDate.selector);
        stakingPool.createPool(
            invalidPoolId,
            "Invalid Maturity Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            COOLDOWN,
            block.timestamp - 1, // Past maturity date
            address(0)
        );
    }

    function test_PoolCooldown_UpTo2Years() public {
        bytes32 longTermPoolId = keccak256("LONG_TERM_POOL");

        // 2 year cooldown should work (for loan term matching)
        vm.prank(owner);
        stakingPool.createPool(
            longTermPoolId,
            "2 Year Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            730 days, // 2 years
            0,
            address(0)
        );

        (, , , , , uint256 poolCooldown, , , , ) = stakingPool.getPool(longTermPoolId);
        assertEq(poolCooldown, 730 days);
    }

    function test_CreatePool_RevertIfCooldownTooLong() public {
        bytes32 invalidPoolId = keccak256("INVALID_COOLDOWN");

        // More than 2 years should fail
        vm.prank(owner);
        vm.expectRevert(StakingPool.InvalidCooldownPeriod.selector);
        stakingPool.createPool(
            invalidPoolId,
            "Invalid Cooldown Pool",
            MINIMUM_STAKE,
            FEE_RATE,
            731 days, // More than 2 years
            0,
            address(0)
        );
    }
}
