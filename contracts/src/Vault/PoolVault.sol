// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title PoolVault
/// @notice ERC-4626 compliant vault for investor staking in loan pools
/// @dev Extends OpenZeppelin's audited ERC4626Upgradeable contract
/// @custom:security-contact security@locale-lending.com
contract PoolVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    ////////////////////////////////////////////////
    // ROLES
    ////////////////////////////////////////////////
    bytes32 public constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    ////////////////////////////////////////////////
    // STATE VARIABLES
    ////////////////////////////////////////////////

    /// @notice Minimum deposit amount to prevent donation attacks
    uint256 public constant MIN_INITIAL_DEPOSIT = 1e6; // 1 USDC (6 decimals)

    /// @notice Pool type identifier
    string public poolType;

    /// @notice Total yield distributed to vault
    uint256 public totalYieldDistributed;

    /// @notice Management fee rate in basis points (e.g., 200 = 2%)
    uint256 public managementFeeRate;

    /// @notice Performance fee rate in basis points (e.g., 2000 = 20%)
    uint256 public performanceFeeRate;

    /// @notice Fee recipient address
    address public feeRecipient;

    /// @notice Withdrawal delay in seconds (for security)
    uint256 public withdrawalDelay;

    /// @notice Mapping of pending withdrawals
    mapping(address => uint256) public withdrawalRequestTime;

    ////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////
    event YieldDistributed(uint256 amount, uint256 newTotalAssets);
    event ManagementFeeUpdated(uint256 oldFee, uint256 newFee);
    event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event WithdrawalRequested(address indexed user, uint256 shares, uint256 unlockTime);
    event WithdrawalDelayUpdated(uint256 oldDelay, uint256 newDelay);

    ////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////
    error InsufficientInitialDeposit();
    error WithdrawalDelayNotMet();
    error InvalidFeeRate();
    error InvalidFeeRecipient();
    error InvalidDelay();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    ////////////////////////////////////////////////
    // INITIALIZATION
    ////////////////////////////////////////////////

    /// @notice Initializes the vault with configuration
    /// @param _asset Address of the underlying asset (e.g., USDC)
    /// @param _name Name of the vault token (e.g., "Locale Small Business Pool")
    /// @param _symbol Symbol of the vault token (e.g., "LSB-POOL")
    /// @param _poolType Type of pool (e.g., "SMALL_BUSINESS", "REAL_ESTATE")
    /// @param _admin Address of the admin
    /// @param _feeRecipient Address to receive fees
    function initialize(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        string memory _poolType,
        address _admin,
        address _feeRecipient
    ) public initializer {
        __ERC4626_init(_asset);
        __ERC20_init(_name, _symbol);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        poolType = _poolType;
        managementFeeRate = 200; // 2% default
        performanceFeeRate = 2000; // 20% default
        withdrawalDelay = 7 days; // 7 day withdrawal delay

        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
        feeRecipient = _feeRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(POOL_MANAGER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        // Make initial deposit to prevent donation attack
        // This locks 1 USDC worth of shares forever
        _deposit(_admin, _admin, MIN_INITIAL_DEPOSIT, MIN_INITIAL_DEPOSIT);
    }

    ////////////////////////////////////////////////
    // DEPOSIT & WITHDRAWAL FUNCTIONS
    ////////////////////////////////////////////////

    /// @notice Deposits assets into the vault
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive vault shares
    /// @return shares Amount of shares minted
    function deposit(
        uint256 assets,
        address receiver
    ) public override whenNotPaused nonReentrant returns (uint256 shares) {
        return super.deposit(assets, receiver);
    }

    /// @notice Mints exact shares by depositing assets
    /// @param shares Amount of shares to mint
    /// @param receiver Address to receive vault shares
    /// @return assets Amount of assets deposited
    function mint(
        uint256 shares,
        address receiver
    ) public override whenNotPaused nonReentrant returns (uint256 assets) {
        return super.mint(shares, receiver);
    }

    /// @notice Requests a withdrawal (starts delay period)
    /// @param shares Amount of shares to withdraw
    function requestWithdrawal(uint256 shares) external whenNotPaused {
        require(balanceOf(msg.sender) >= shares, "Insufficient balance");
        withdrawalRequestTime[msg.sender] = block.timestamp;
        emit WithdrawalRequested(msg.sender, shares, block.timestamp + withdrawalDelay);
    }

    /// @notice Withdraws assets from the vault after delay period
    /// @param assets Amount of assets to withdraw
    /// @param receiver Address to receive assets
    /// @param owner Address of the share owner
    /// @return shares Amount of shares burned
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override whenNotPaused nonReentrant returns (uint256 shares) {
        // Check withdrawal delay
        if (owner != msg.sender) {
            if (block.timestamp < withdrawalRequestTime[owner] + withdrawalDelay) {
                revert WithdrawalDelayNotMet();
            }
        }

        // Reset withdrawal request
        delete withdrawalRequestTime[owner];

        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeems shares for assets after delay period
    /// @param shares Amount of shares to redeem
    /// @param receiver Address to receive assets
    /// @param owner Address of the share owner
    /// @return assets Amount of assets withdrawn
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override whenNotPaused nonReentrant returns (uint256 assets) {
        // Check withdrawal delay
        if (owner != msg.sender) {
            if (block.timestamp < withdrawalRequestTime[owner] + withdrawalDelay) {
                revert WithdrawalDelayNotMet();
            }
        }

        // Reset withdrawal request
        delete withdrawalRequestTime[owner];

        return super.redeem(shares, receiver, owner);
    }

    ////////////////////////////////////////////////
    // YIELD DISTRIBUTION
    ////////////////////////////////////////////////

    /// @notice Distributes yield to the vault (increases share price)
    /// @param amount Amount of yield to distribute
    /// @dev Only callable by pool manager when loans generate profits
    function distributeYield(uint256 amount) external onlyRole(POOL_MANAGER_ROLE) {
        require(amount > 0, "Amount must be greater than 0");

        // Calculate and deduct performance fee
        uint256 performanceFee = (amount * performanceFeeRate) / 10000;
        uint256 netYield = amount - performanceFee;

        // Transfer total amount to vault
        IERC20(asset()).transferFrom(msg.sender, address(this), amount);

        // Transfer performance fee to fee recipient
        if (performanceFee > 0) {
            IERC20(asset()).transfer(feeRecipient, performanceFee);
        }

        totalYieldDistributed += netYield;
        emit YieldDistributed(netYield, totalAssets());
    }

    ////////////////////////////////////////////////
    // FEE MANAGEMENT
    ////////////////////////////////////////////////

    /// @notice Updates the management fee rate
    /// @param newRate New fee rate in basis points
    function setManagementFeeRate(uint256 newRate) external onlyRole(POOL_MANAGER_ROLE) {
        if (newRate > 1000) revert InvalidFeeRate(); // Max 10%
        uint256 oldRate = managementFeeRate;
        managementFeeRate = newRate;
        emit ManagementFeeUpdated(oldRate, newRate);
    }

    /// @notice Updates the performance fee rate
    /// @param newRate New fee rate in basis points
    function setPerformanceFeeRate(uint256 newRate) external onlyRole(POOL_MANAGER_ROLE) {
        if (newRate > 3000) revert InvalidFeeRate(); // Max 30%
        uint256 oldRate = performanceFeeRate;
        performanceFeeRate = newRate;
        emit PerformanceFeeUpdated(oldRate, newRate);
    }

    /// @notice Updates the fee recipient address
    /// @param newRecipient New fee recipient address
    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert InvalidFeeRecipient();
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /// @notice Updates the withdrawal delay period
    /// @param newDelay New delay in seconds
    function setWithdrawalDelay(uint256 newDelay) external onlyRole(POOL_MANAGER_ROLE) {
        if (newDelay > 30 days) revert InvalidDelay(); // Max 30 days
        uint256 oldDelay = withdrawalDelay;
        withdrawalDelay = newDelay;
        emit WithdrawalDelayUpdated(oldDelay, newDelay);
    }

    ////////////////////////////////////////////////
    // EMERGENCY CONTROLS
    ////////////////////////////////////////////////

    /// @notice Pauses all vault operations
    function pause() external onlyRole(POOL_MANAGER_ROLE) {
        _pause();
    }

    /// @notice Unpauses all vault operations
    function unpause() external onlyRole(POOL_MANAGER_ROLE) {
        _unpause();
    }

    ////////////////////////////////////////////////
    // VIEW FUNCTIONS
    ////////////////////////////////////////////////

    /// @notice Returns the total assets controlled by the vault
    /// @dev Overrides ERC4626 to account for external loan assets
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Returns the maximum amount that can be deposited
    /// @param receiver Address receiving the shares
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxDeposit(receiver);
    }

    /// @notice Returns the maximum amount that can be minted
    /// @param receiver Address receiving the shares
    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxMint(receiver);
    }

    /// @notice Returns the maximum amount that can be withdrawn
    /// @param owner Address of the share owner
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        if (block.timestamp < withdrawalRequestTime[owner] + withdrawalDelay) return 0;
        return super.maxWithdraw(owner);
    }

    /// @notice Returns the maximum shares that can be redeemed
    /// @param owner Address of the share owner
    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        if (block.timestamp < withdrawalRequestTime[owner] + withdrawalDelay) return 0;
        return super.maxRedeem(owner);
    }

    ////////////////////////////////////////////////
    // UPGRADE
    ////////////////////////////////////////////////

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}
}
