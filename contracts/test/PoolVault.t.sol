// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {PoolVault} from "../src/Vault/PoolVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PoolVaultTest is Test {
    PoolVault public vault;
    MockUSDC public usdc;

    address public admin;
    address public poolManager;
    address public feeRecipient;
    address public investor1;
    address public investor2;

    uint256 public constant MIN_INITIAL_DEPOSIT = 1e6; // 1 USDC

    function setUp() public {
        admin = address(this);
        poolManager = address(0x1);
        feeRecipient = address(0x2);
        investor1 = address(0x3);
        investor2 = address(0x4);

        // Deploy MockUSDC
        MockUSDC usdcImpl = new MockUSDC();
        ERC1967Proxy usdcProxy = new ERC1967Proxy(
            address(usdcImpl),
            abi.encodeWithSelector(MockUSDC.initialize.selector)
        );
        usdc = MockUSDC(address(usdcProxy));

        // Mint initial USDC for admin (for MIN_INITIAL_DEPOSIT)
        usdc.mint(admin, MIN_INITIAL_DEPOSIT * 10); // Extra for testing

        // Deploy PoolVault implementation first
        PoolVault vaultImpl = new PoolVault();

        // Predict the proxy address so we can pre-approve
        // The proxy will be deployed by this contract (address(this))
        // Using CREATE: address = keccak256(rlp([sender, nonce]))[12:]
        // Since we're deploying in the same context, we can just deploy and approve right away

        bytes memory initData = abi.encodeWithSelector(
            PoolVault.initialize.selector,
            IERC20(address(usdc)),
            "Small Business Pool",
            "sbPOOL",
            "small_business",
            admin,
            feeRecipient
        );

        // Calculate the proxy address before deployment
        // Using vm.computeCreateAddress for Foundry
        uint64 nonce = vm.getNonce(admin);
        address predictedProxy = vm.computeCreateAddress(admin, nonce);

        // Approve the predicted proxy address for MIN_INITIAL_DEPOSIT
        usdc.approve(predictedProxy, MIN_INITIAL_DEPOSIT);

        // Now deploy the proxy
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = PoolVault(address(vaultProxy));

        // Grant POOL_MANAGER_ROLE to poolManager
        vault.grantRole(vault.POOL_MANAGER_ROLE(), poolManager);

        // Mint USDC to investors
        usdc.mint(investor1, 100000 * 1e6); // 100k USDC
        usdc.mint(investor2, 100000 * 1e6); // 100k USDC
    }

    ///////////////////////////////////////////////////////////
    // Test 1: Initialization
    ///////////////////////////////////////////////////////////

    function testInitialization() public view {
        assertEq(vault.name(), "Small Business Pool");
        assertEq(vault.symbol(), "sbPOOL");
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.poolType(), "small_business");
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.managementFeeRate(), 200); // 2%
        assertEq(vault.performanceFeeRate(), 2000); // 20%
        assertEq(vault.withdrawalDelay(), 7 days);
    }

    ///////////////////////////////////////////////////////////
    // Test 2: Deposits
    ///////////////////////////////////////////////////////////

    function testDeposit() public {
        uint256 depositAmount = 1000 * 1e6; // 1000 USDC

        vm.startPrank(investor1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, investor1);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(investor1), shares, "Investor should own shares");
    }

    function testDepositMultipleInvestors() public {
        uint256 depositAmount = 1000 * 1e6;

        // Investor 1 deposits
        vm.startPrank(investor1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares1 = vault.deposit(depositAmount, investor1);
        vm.stopPrank();

        // Investor 2 deposits same amount
        vm.startPrank(investor2);
        usdc.approve(address(vault), depositAmount);
        uint256 shares2 = vault.deposit(depositAmount, investor2);
        vm.stopPrank();

        // Both should have equal shares (since no yield distributed yet)
        assertEq(shares1, shares2, "Equal deposits should get equal shares");
    }

    ///////////////////////////////////////////////////////////
    // Test 3: Withdrawal Delay
    ///////////////////////////////////////////////////////////

    function testWithdrawalDelay() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit
        vm.startPrank(investor1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, investor1);

        // Request withdrawal
        vault.requestWithdrawal(shares);

        // Try to withdraw immediately - should fail
        vm.expectRevert();
        vault.redeem(shares, investor1, investor1);

        vm.stopPrank();
    }

    function testWithdrawalAfterDelay() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit
        vm.startPrank(investor1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, investor1);

        // Request withdrawal
        vault.requestWithdrawal(shares);

        // Warp time past withdrawal delay
        vm.warp(block.timestamp + 7 days + 1);

        // Should be able to withdraw now
        uint256 balanceBefore = usdc.balanceOf(investor1);
        vault.redeem(shares, investor1, investor1);
        uint256 balanceAfter = usdc.balanceOf(investor1);

        vm.stopPrank();

        assertGt(balanceAfter, balanceBefore, "Should receive USDC back");
    }

    ///////////////////////////////////////////////////////////
    // Test 4: Fee Management
    ///////////////////////////////////////////////////////////

    function testSetManagementFeeRate() public {
        uint256 newFee = 300; // 3%

        vm.prank(poolManager);
        vault.setManagementFeeRate(newFee);

        assertEq(vault.managementFeeRate(), newFee);
    }

    function testSetManagementFeeRateTooHigh() public {
        uint256 newFee = 1001; // >10%

        vm.prank(poolManager);
        vm.expectRevert();
        vault.setManagementFeeRate(newFee);
    }

    function testSetPerformanceFeeRate() public {
        uint256 newFee = 2500; // 25%

        vm.prank(poolManager);
        vault.setPerformanceFeeRate(newFee);

        assertEq(vault.performanceFeeRate(), newFee);
    }

    function testSetPerformanceFeeRateTooHigh() public {
        uint256 newFee = 3001; // >30%

        vm.prank(poolManager);
        vm.expectRevert();
        vault.setPerformanceFeeRate(newFee);
    }

    ///////////////////////////////////////////////////////////
    // Test 5: Yield Distribution
    ///////////////////////////////////////////////////////////

    function testDistributeYield() public {
        uint256 depositAmount = 10000 * 1e6; // 10,000 USDC
        uint256 yieldAmount = 1000 * 1e6; // 1,000 USDC yield (10%)

        // Investor deposits
        vm.startPrank(investor1);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, investor1);
        vm.stopPrank();

        // Pool manager receives yield and distributes
        usdc.mint(poolManager, yieldAmount);

        vm.startPrank(poolManager);
        usdc.approve(address(vault), yieldAmount);
        vault.distributeYield(yieldAmount);
        vm.stopPrank();

        // Check fee recipient got performance fee (20% of 1000 = 200 USDC)
        uint256 expectedFee = (yieldAmount * 2000) / 10000; // 200 USDC
        assertEq(usdc.balanceOf(feeRecipient), expectedFee, "Fee recipient should receive 20% fee");

        // Check total yield distributed (net of fee)
        uint256 expectedNetYield = yieldAmount - expectedFee; // 800 USDC
        assertEq(vault.totalYieldDistributed(), expectedNetYield, "Net yield should be tracked");
    }

    function testDistributeYieldOnlyPoolManager() public {
        uint256 yieldAmount = 1000 * 1e6;

        usdc.mint(investor1, yieldAmount);

        vm.startPrank(investor1);
        usdc.approve(address(vault), yieldAmount);

        vm.expectRevert();
        vault.distributeYield(yieldAmount);

        vm.stopPrank();
    }

    ///////////////////////////////////////////////////////////
    // Test 6: Pause Functionality
    ///////////////////////////////////////////////////////////

    function testPauseBlocksDeposits() public {
        vault.pause();

        vm.startPrank(investor1);
        usdc.approve(address(vault), 1000 * 1e6);

        vm.expectRevert();
        vault.deposit(1000 * 1e6, investor1);

        vm.stopPrank();
    }

    function testPauseBlocksWithdrawals() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit first
        vm.startPrank(investor1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, investor1);
        vault.requestWithdrawal(shares);
        vm.stopPrank();

        // Warp past delay
        vm.warp(block.timestamp + 7 days + 1);

        // Pause
        vault.pause();

        // Try to withdraw - should fail
        vm.startPrank(investor1);
        vm.expectRevert();
        vault.redeem(shares, investor1, investor1);
        vm.stopPrank();
    }

    function testUnpauseAllowsOperations() public {
        vault.pause();
        vault.unpause();

        vm.startPrank(investor1);
        usdc.approve(address(vault), 1000 * 1e6);
        uint256 shares = vault.deposit(1000 * 1e6, investor1);
        vm.stopPrank();

        assertGt(shares, 0, "Should be able to deposit after unpause");
    }

    ///////////////////////////////////////////////////////////
    // Test 7: Access Control
    ///////////////////////////////////////////////////////////

    function testOnlyAdminCanPause() public {
        vm.prank(investor1);
        vm.expectRevert();
        vault.pause();
    }

    function testOnlyPoolManagerCanSetFees() public {
        vm.prank(investor1);
        vm.expectRevert();
        vault.setManagementFeeRate(300);

        vm.prank(investor1);
        vm.expectRevert();
        vault.setPerformanceFeeRate(2500);
    }

    ///////////////////////////////////////////////////////////
    // Test 8: Share Price Changes
    ///////////////////////////////////////////////////////////

    function testSharePriceIncreasesWithYield() public {
        uint256 depositAmount = 10000 * 1e6;
        uint256 yieldAmount = 1000 * 1e6;

        // Investor deposits
        vm.startPrank(investor1);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, investor1);
        vm.stopPrank();

        // Get initial share price
        uint256 initialSharePrice = vault.convertToAssets(1e6); // Price per 1 share

        // Distribute yield
        usdc.mint(poolManager, yieldAmount);
        vm.startPrank(poolManager);
        usdc.approve(address(vault), yieldAmount);
        vault.distributeYield(yieldAmount);
        vm.stopPrank();

        // Get new share price
        uint256 newSharePrice = vault.convertToAssets(1e6);

        assertGt(newSharePrice, initialSharePrice, "Share price should increase after yield");
    }

    ///////////////////////////////////////////////////////////
    // Test 9: Withdrawal Request Tracking
    ///////////////////////////////////////////////////////////

    function testMultipleWithdrawalRequests() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.startPrank(investor1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, investor1);

        // First request
        vault.requestWithdrawal(shares / 2);
        uint256 firstRequestTime = vault.withdrawalRequestTime(investor1);

        // Warp 3 days
        vm.warp(block.timestamp + 3 days);

        // Second request - should update timestamp
        vault.requestWithdrawal(shares / 2);
        uint256 secondRequestTime = vault.withdrawalRequestTime(investor1);

        vm.stopPrank();

        assertGt(secondRequestTime, firstRequestTime, "New request should update timestamp");
    }
}
