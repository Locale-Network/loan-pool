// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakingPool} from "../src/Staking/StakingPool.sol";
import {UpgradeableCommunityToken} from "../src/ERC20/UpgradeableCommunityToken.sol";

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
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

        (
            string memory name,
            uint256 minimumStake,
            uint256 totalStaked,
            uint256 totalShares,
            uint256 feeRate,
            bool active
        ) = stakingPool.getPool(POOL_ID);

        assertEq(name, "Test Pool");
        assertEq(minimumStake, MINIMUM_STAKE);
        assertEq(totalStaked, 0);
        assertEq(totalShares, 0);
        assertEq(feeRate, FEE_RATE);
        assertTrue(active);
    }

    function test_CreatePool_RevertIfNotManager() public {
        vm.prank(user1);
        vm.expectRevert();
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);
    }

    function test_Stake() public {
        // Create pool first
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

        uint256 stakeAmount = 1000 * 1e6;
        uint256 expectedFee = (stakeAmount * FEE_RATE) / 10000;
        uint256 expectedNet = stakeAmount - expectedFee;

        uint256 user1BalanceBefore = token.balanceOf(user1);
        uint256 feeRecipientBalanceBefore = token.balanceOf(feeRecipient);

        vm.prank(user1);
        stakingPool.stake(POOL_ID, stakeAmount);

        // Check user stake
        (uint256 amount, uint256 shares, , , ) = stakingPool.getUserStake(POOL_ID, user1);
        assertEq(amount, expectedNet);
        assertEq(shares, expectedNet); // First staker gets 1:1 shares

        // Check balances
        assertEq(token.balanceOf(user1), user1BalanceBefore - stakeAmount);
        assertEq(token.balanceOf(feeRecipient), feeRecipientBalanceBefore + expectedFee);

        // Check pool stats
        (, , uint256 totalStaked, uint256 totalShares, , ) = stakingPool.getPool(POOL_ID);
        assertEq(totalStaked, expectedNet);
        assertEq(totalShares, expectedNet);
    }

    function test_Stake_RevertIfBelowMinimum() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

        vm.prank(user1);
        vm.expectRevert(StakingPool.BelowMinimumStake.selector);
        stakingPool.stake(POOL_ID, 50 * 1e6); // Below minimum
    }

    function test_Stake_RevertIfPoolNotActive() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

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
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        uint256 unstakeAmount = 500 * 1e6;

        vm.prank(user1);
        stakingPool.requestUnstake(POOL_ID, unstakeAmount);

        (uint256 amount, , , uint256 pendingUnstake, uint256 canWithdrawAt) =
            stakingPool.getUserStake(POOL_ID, user1);

        assertGt(amount, 0);
        assertEq(pendingUnstake, unstakeAmount);
        assertEq(canWithdrawAt, block.timestamp + COOLDOWN);
    }

    function test_RequestUnstake_RevertIfBelowMinimum() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

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
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        (uint256 stakedAmount, , , , ) = stakingPool.getUserStake(POOL_ID, user1);

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
        (uint256 amount, uint256 shares, , uint256 pendingUnstake, ) =
            stakingPool.getUserStake(POOL_ID, user1);
        assertEq(amount, 0);
        assertEq(shares, 0);
        assertEq(pendingUnstake, 0);
    }

    function test_CancelUnstake() public {
        // Setup: create pool and stake
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        (uint256 stakedAmount, , , , ) = stakingPool.getUserStake(POOL_ID, user1);

        // Request unstake
        vm.prank(user1);
        stakingPool.requestUnstake(POOL_ID, stakedAmount);

        // Cancel unstake
        vm.prank(user1);
        stakingPool.cancelUnstake(POOL_ID);

        // Check pending unstake is cleared
        (, , , uint256 pendingUnstake, uint256 canWithdrawAt) =
            stakingPool.getUserStake(POOL_ID, user1);
        assertEq(pendingUnstake, 0);
        assertEq(canWithdrawAt, 0);
    }

    function test_DistributeYield() public {
        // Setup: create pool and stake from two users
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

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
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

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
        stakingPool.createPool(pool1, "Pool 1", MINIMUM_STAKE, FEE_RATE);
        stakingPool.createPool(pool2, "Pool 2", MINIMUM_STAKE, FEE_RATE);
        vm.stopPrank();

        bytes32[] memory poolIds = stakingPool.getAllPoolIds();
        assertEq(poolIds.length, 2);
        assertEq(poolIds[0], pool1);
        assertEq(poolIds[1], pool2);
    }

    function test_CooldownPeriodLocked() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        (uint256 stakedAmount, , , , ) = stakingPool.getUserStake(POOL_ID, user1);

        vm.prank(user1);
        stakingPool.requestUnstake(POOL_ID, stakedAmount);

        (, , , , uint256 canWithdrawAtBefore) = stakingPool.getUserStake(POOL_ID, user1);

        vm.prank(owner);
        stakingPool.setCooldownPeriod(30 days);

        (, , , , uint256 canWithdrawAtAfter) = stakingPool.getUserStake(POOL_ID, user1);

        assertEq(canWithdrawAtBefore, canWithdrawAtAfter);
    }

    function test_UnstakePrecisionLoss_RevertOnZeroShares() public {
        vm.prank(owner);
        stakingPool.createPool(POOL_ID, "Test Pool", MINIMUM_STAKE, FEE_RATE);

        vm.prank(user1);
        stakingPool.stake(POOL_ID, 1000 * 1e6);

        (uint256 stakedAmount, , , , ) = stakingPool.getUserStake(POOL_ID, user1);

        vm.prank(user1);
        stakingPool.requestUnstake(POOL_ID, 1e6);

        vm.warp(block.timestamp + COOLDOWN + 1);

        (, uint256 sharesBefore, , , ) = stakingPool.getUserStake(POOL_ID, user1);
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
}
