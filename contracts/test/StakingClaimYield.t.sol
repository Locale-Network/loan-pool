// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakingPool} from "../src/Staking/StakingPool.sol";
import {UpgradeableCommunityToken} from "../src/ERC20/UpgradeableCommunityToken.sol";

/// Regression tests: claimYield() must not cause the claimed amount to be
/// deducted a second time (at unstakeAtMaturity or on later claims).
contract StakingClaimYieldTest is Test {
    UpgradeableCommunityToken token;
    StakingPool sp;
    address owner = address(0xA11CE);
    address alice = address(0xA1);
    address bob = address(0xB0);
    bytes32 constant POOL = keccak256("MATURITY_POOL");
    uint256 constant USDC = 1e6;
    uint256 maturity;

    function setUp() public {
        address[] memory minters = new address[](1);
        minters[0] = owner;
        token = UpgradeableCommunityToken(address(new ERC1967Proxy(
            address(new UpgradeableCommunityToken()),
            abi.encodeCall(UpgradeableCommunityToken.initialize, (owner, minters, "Mock USDC", "mUSDC"))
        )));
        sp = StakingPool(address(new ERC1967Proxy(
            address(new StakingPool()),
            abi.encodeCall(StakingPool.initialize, (owner, IERC20(address(token)), address(0xFEE), 7 days))
        )));
        maturity = block.timestamp + 30 days;
        vm.startPrank(owner);
        sp.createPool(POOL, "Maturity Pool", 1 * USDC, 0, 0, maturity, address(0));
        token.approve(address(sp), type(uint256).max);
        vm.stopPrank();
        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            vm.prank(owner);
            token.mint(u, 1_000_000 * USDC);
            vm.prank(u);
            token.approve(address(sp), type(uint256).max);
        }
    }

    function _stake(address u, uint256 amt) internal returns (uint256 balAfter) {
        vm.prank(u);
        sp.stake(POOL, amt);
        balAfter = token.balanceOf(u);
    }

    function _yield(uint256 amt) internal {
        vm.startPrank(owner);
        token.mint(owner, amt);
        sp.distributeYield(POOL, amt);
        vm.stopPrank();
    }

    function _claim(address u) internal returns (uint256 got) {
        uint256 b = token.balanceOf(u);
        vm.prank(u);
        sp.claimYield(POOL);
        got = token.balanceOf(u) - b;
    }

    function _unstake(address u) internal {
        vm.warp(maturity + 1);
        vm.prank(u);
        sp.unstakeAtMaturity(POOL);
    }

    /// Kenji's PoC scenario: claim then unstake must total principal + all yield.
    function test_claimThenUnstake_paysFullValue() public {
        uint256 start = _stake(alice, 1_000 * USDC);
        _yield(600 * USDC);
        assertApproxEqAbs(_claim(alice), 600 * USDC, 1, "claim pays the yield");
        _unstake(alice);
        assertApproxEqAbs(token.balanceOf(alice) - start, 1_600 * USDC, 2, "principal + yield, nothing forfeited");
        assertLe(token.balanceOf(address(sp)), 2, "nothing stranded in the pool");
    }

    function test_control_noClaim_paysFullValue() public {
        uint256 start = _stake(alice, 1_000 * USDC);
        _yield(600 * USDC);
        _unstake(alice);
        assertApproxEqAbs(token.balanceOf(alice) - start, 1_600 * USDC, 2);
    }

    /// Claimer and holder are each paid exactly their value-proportional share.
    /// After alice claims 300 her stake is worth 1000 vs bob's 1300, so the next
    /// 400 of yield splits 1000:1300 (bob's unclaimed 300 compounds). Nothing is lost.
    function test_claimerAndHolder_paidProportionally_noneStranded() public {
        uint256 a0 = _stake(alice, 1_000 * USDC);
        uint256 b0 = _stake(bob, 1_000 * USDC);
        _yield(600 * USDC);
        _claim(alice);
        _yield(400 * USDC);
        _unstake(alice);
        vm.prank(bob);
        sp.unstakeAtMaturity(POOL);
        uint256 aliceTotal = token.balanceOf(alice) - a0;
        uint256 bobTotal = token.balanceOf(bob) - b0;
        assertApproxEqAbs(aliceTotal, 1_300 * USDC + (400 * USDC * 1_000) / 2_300, 3, "alice share");
        assertApproxEqAbs(bobTotal, 1_300 * USDC + (400 * USDC * 1_300) / 2_300, 3, "bob share");
        assertApproxEqAbs(aliceTotal + bobTotal, 3_000 * USDC, 3, "all principal + all yield paid out");
        assertLe(token.balanceOf(address(sp)), 3, "nothing stranded in the pool");
    }

    /// Second claim after new yield must pay the new yield (old code paid 0 / reverted).
    function test_secondClaim_paysNewYield() public {
        _stake(alice, 1_000 * USDC);
        _yield(600 * USDC);
        _claim(alice);
        _yield(400 * USDC);
        assertApproxEqAbs(sp.getAvailableYield(POOL, alice), 400 * USDC, 1, "view shows new yield");
        assertApproxEqAbs(_claim(alice), 400 * USDC, 1, "second claim pays new yield");
    }

    function test_getAvailableYield_matchesClaim() public {
        _stake(alice, 1_000 * USDC);
        _yield(250 * USDC);
        uint256 shown = sp.getAvailableYield(POOL, alice);
        assertEq(_claim(alice), shown, "view == payout");
        assertEq(sp.getAvailableYield(POOL, alice), 0, "nothing left after claim");
    }

    function testFuzz_claimNeverLosesValue(uint64 p, uint64 y1, uint64 y2, bool claimMid) public {
        uint256 principal = bound(uint256(p), 1 * USDC, 1_000_000 * USDC);
        uint256 a = bound(uint256(y1), 1 * USDC, 500_000 * USDC);
        uint256 b = bound(uint256(y2), 0, 500_000 * USDC);
        uint256 start = _stake(alice, principal);
        _yield(a);
        _claim(alice);
        if (b > 0) {
            _yield(b);
            if (claimMid) _claim(alice);
        }
        _unstake(alice);
        assertApproxEqAbs(token.balanceOf(alice) - start, principal + a + b, 4, "lifetime total = principal + all yield");
        assertLe(token.balanceOf(address(sp)), 4, "nothing stranded");
    }
}
