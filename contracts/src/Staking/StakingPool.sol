// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StakingPool
/// @notice A contract for managing investor stakes in lending pools
/// @dev Implements upgradeable pattern with access control and cooldown periods
/// @custom:security-contact security@locale-lending.com
contract StakingPool is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////
    // ROLES
    ////////////////////////////////////////////////
    bytes32 public constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    ////////////////////////////////////////////////
    // STRUCTS
    ////////////////////////////////////////////////
    struct Pool {
        bytes32 poolId;
        string name;
        uint256 minimumStake;
        uint256 totalStaked;
        uint256 totalShares;
        uint256 feeRate; // Basis points (e.g., 300 = 3%)
        uint256 cooldownPeriod; // Per-pool cooldown (can be up to loan term)
        uint256 maturityDate; // When investors can withdraw principal
        address eligibilityRegistry; // For Reg D 506(b) compliance (0x0 if not required)
        bool active;
        bool cooldownWaived; // When true, investors can unstake immediately (e.g., after loan repayment)
    }

    struct UserStake {
        uint256 principal; // Original deposit (locked until maturity)
        uint256 amount; // Current value including yield
        uint256 shares;
        uint256 stakedAt;
        uint256 unstakeRequestTime;
        uint256 pendingUnstakeAmount;
        uint256 lockedCooldownPeriod;
        uint256 claimedYield; // Track yield already claimed
    }

    ////////////////////////////////////////////////
    // STATE VARIABLES
    ////////////////////////////////////////////////

    /// @notice The staking token (e.g., USDC)
    IERC20 public stakingToken;

    /// @notice Cooldown period before unstaked funds can be withdrawn
    uint256 public cooldownPeriod;

    /// @notice Minimum unstake amount to prevent precision loss attacks
    uint256 public minimumUnstakeAmount;

    /// @notice Fee recipient address
    address public feeRecipient;

    /// @notice Mapping of pool ID to Pool data
    mapping(bytes32 => Pool) public pools;

    /// @notice Mapping of pool ID => user address => stake data
    mapping(bytes32 => mapping(address => UserStake)) public userStakes;

    /// @notice Array of all pool IDs
    bytes32[] public poolIds;

    ////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////
    event PoolCreated(bytes32 indexed poolId, string name, uint256 minimumStake, uint256 feeRate, uint256 cooldownPeriod, uint256 maturityDate);
    event PoolUpdated(bytes32 indexed poolId, uint256 minimumStake, uint256 feeRate, bool active);
    event Staked(bytes32 indexed poolId, address indexed user, uint256 amount, uint256 shares, uint256 fee);
    event UnstakeRequested(bytes32 indexed poolId, address indexed user, uint256 amount, uint256 unlockTime);
    event Unstaked(bytes32 indexed poolId, address indexed user, uint256 amount);
    event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event YieldDistributed(bytes32 indexed poolId, uint256 amount);
    event YieldClaimed(bytes32 indexed poolId, address indexed user, uint256 amount);
    event UnstakedAtMaturity(bytes32 indexed poolId, address indexed user, uint256 amount);
    event PoolCooldownWaived(bytes32 indexed poolId, bool waived);

    ////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////
    error PoolAlreadyExists();
    error PoolNotFound();
    error PoolNotActive();
    error BelowMinimumStake();
    error NoActiveStake();
    error InsufficientStake();
    error CooldownNotComplete();
    error NoPendingUnstake();
    error InvalidFeeRate();
    error InvalidCooldownPeriod();
    error InvalidAddress();
    error ZeroAmount();
    error InsufficientShares();
    error BelowMinimumUnstake();
    error PoolNotMatured();
    error NoYieldToClaim();
    error InvestorNotEligible();
    error InvalidMaturityDate();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    ////////////////////////////////////////////////
    // INITIALIZATION
    ////////////////////////////////////////////////

    /// @notice Initializes the staking pool contract
    /// @param _owner Address of the contract owner
    /// @param _stakingToken Address of the staking token (e.g., USDC)
    /// @param _feeRecipient Address to receive fees
    /// @param _cooldownPeriod Cooldown period in seconds (e.g., 7 days = 604800)
    function initialize(
        address _owner,
        IERC20 _stakingToken,
        address _feeRecipient,
        uint256 _cooldownPeriod
    ) public initializer {
        if (_owner == address(0)) revert InvalidAddress();
        if (address(_stakingToken) == address(0)) revert InvalidAddress();
        if (_feeRecipient == address(0)) revert InvalidAddress();
        if (_cooldownPeriod > 30 days) revert InvalidCooldownPeriod();

        __Ownable_init(_owner);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        stakingToken = _stakingToken;
        feeRecipient = _feeRecipient;
        cooldownPeriod = _cooldownPeriod;
        minimumUnstakeAmount = 1e6; // 1 USDC (6 decimals)

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(POOL_MANAGER_ROLE, _owner);
        _grantRole(UPGRADER_ROLE, _owner);
    }

    ////////////////////////////////////////////////
    // POOL MANAGEMENT
    ////////////////////////////////////////////////

    /// @notice Creates a new staking pool
    /// @param _poolId Unique identifier for the pool
    /// @param _name Human-readable name for the pool
    /// @param _minimumStake Minimum stake amount
    /// @param _feeRate Fee rate in basis points (e.g., 300 = 3%)
    /// @param _cooldownPeriod Per-pool cooldown period in seconds (can be up to 2 years for loan term matching)
    /// @param _maturityDate Unix timestamp when principal can be withdrawn (0 for no maturity)
    /// @param _eligibilityRegistry Address of eligibility registry for Reg D 506(b) (0x0 if not required)
    function createPool(
        bytes32 _poolId,
        string calldata _name,
        uint256 _minimumStake,
        uint256 _feeRate,
        uint256 _cooldownPeriod,
        uint256 _maturityDate,
        address _eligibilityRegistry
    ) external onlyRole(POOL_MANAGER_ROLE) {
        if (pools[_poolId].poolId != bytes32(0)) revert PoolAlreadyExists();
        if (_feeRate > 1000) revert InvalidFeeRate(); // Max 10%
        if (_cooldownPeriod > 730 days) revert InvalidCooldownPeriod(); // Max 2 years
        if (_maturityDate != 0 && _maturityDate <= block.timestamp) revert InvalidMaturityDate();

        pools[_poolId] = Pool({
            poolId: _poolId,
            name: _name,
            minimumStake: _minimumStake,
            totalStaked: 0,
            totalShares: 0,
            feeRate: _feeRate,
            cooldownPeriod: _cooldownPeriod,
            maturityDate: _maturityDate,
            eligibilityRegistry: _eligibilityRegistry,
            active: true,
            cooldownWaived: false
        });

        poolIds.push(_poolId);
        emit PoolCreated(_poolId, _name, _minimumStake, _feeRate, _cooldownPeriod, _maturityDate);
    }

    /// @notice Updates pool configuration
    /// @param _poolId Pool identifier
    /// @param _minimumStake New minimum stake
    /// @param _feeRate New fee rate in basis points
    /// @param _active Whether the pool is active
    function updatePool(
        bytes32 _poolId,
        uint256 _minimumStake,
        uint256 _feeRate,
        bool _active
    ) external onlyRole(POOL_MANAGER_ROLE) {
        if (pools[_poolId].poolId == bytes32(0)) revert PoolNotFound();
        if (_feeRate > 1000) revert InvalidFeeRate();

        Pool storage pool = pools[_poolId];
        pool.minimumStake = _minimumStake;
        pool.feeRate = _feeRate;
        pool.active = _active;

        emit PoolUpdated(_poolId, _minimumStake, _feeRate, _active);
    }

    ////////////////////////////////////////////////
    // STAKING FUNCTIONS
    ////////////////////////////////////////////////

    /// @notice Stakes tokens into a pool
    /// @param _poolId Pool identifier
    /// @param _amount Amount of tokens to stake
    function stake(bytes32 _poolId, uint256 _amount) external whenNotPaused nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        Pool storage pool = pools[_poolId];
        if (pool.poolId == bytes32(0)) revert PoolNotFound();
        if (!pool.active) revert PoolNotActive();

        // Check eligibility if registry is set (Reg D 506(b) compliance)
        if (pool.eligibilityRegistry != address(0)) {
            // Call the eligibility registry to verify investor
            (bool success, bytes memory data) = pool.eligibilityRegistry.staticcall(
                abi.encodeWithSignature("canInvest(address)", msg.sender)
            );
            if (!success) revert InvestorNotEligible();
            (bool canInvest,) = abi.decode(data, (bool, string));
            if (!canInvest) revert InvestorNotEligible();
        }

        UserStake storage userStake = userStakes[_poolId][msg.sender];
        uint256 totalStakeAfter = userStake.amount + _amount;
        if (totalStakeAfter < pool.minimumStake) revert BelowMinimumStake();

        // Calculate fee
        uint256 fee = (_amount * pool.feeRate) / 10000;
        uint256 netAmount = _amount - fee;

        // Calculate shares (simple 1:1 for now, can be enhanced for yield)
        uint256 shares;
        if (pool.totalShares == 0) {
            shares = netAmount;
        } else {
            shares = (netAmount * pool.totalShares) / pool.totalStaked;
            if (shares == 0) revert InsufficientShares();
        }

        // Transfer tokens from user
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Transfer fee to recipient
        if (fee > 0) {
            stakingToken.safeTransfer(feeRecipient, fee);
        }

        // Update state
        userStake.principal += netAmount; // Track original deposit
        userStake.amount += netAmount;
        userStake.shares += shares;
        if (userStake.stakedAt == 0) {
            userStake.stakedAt = block.timestamp;
        }

        pool.totalStaked += netAmount;
        pool.totalShares += shares;

        // Mark as invested in eligibility registry if set
        if (pool.eligibilityRegistry != address(0)) {
            (bool success,) = pool.eligibilityRegistry.call(
                abi.encodeWithSignature("markAsInvested(address)", msg.sender)
            );
            // Don't revert if this fails - just log
            if (!success) {
                // Silently continue - marking is optional
            }
        }

        emit Staked(_poolId, msg.sender, netAmount, shares, fee);
    }

    /// @notice Requests to unstake tokens (starts cooldown)
    /// @dev Uses pool-specific cooldown period. For pools with maturity dates, use unstakeAtMaturity() instead.
    /// @param _poolId Pool identifier
    /// @param _amount Amount to unstake
    function requestUnstake(bytes32 _poolId, uint256 _amount) external whenNotPaused nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_amount < minimumUnstakeAmount) revert BelowMinimumUnstake();

        Pool storage pool = pools[_poolId];
        if (pool.poolId == bytes32(0)) revert PoolNotFound();

        // If pool has maturity date, regular unstake is disabled - use unstakeAtMaturity()
        if (pool.maturityDate != 0) {
            revert PoolNotMatured();
        }

        UserStake storage userStake = userStakes[_poolId][msg.sender];
        if (userStake.amount == 0) revert NoActiveStake();
        if (_amount > userStake.amount) revert InsufficientStake();

        // Use pool-specific cooldown period (falls back to global if pool cooldown is 0)
        // If cooldown is waived (e.g., after loan repayment), use 0
        uint256 effectiveCooldown = pool.cooldownWaived
            ? 0
            : (pool.cooldownPeriod > 0 ? pool.cooldownPeriod : cooldownPeriod);

        userStake.unstakeRequestTime = block.timestamp;
        userStake.pendingUnstakeAmount = _amount;
        userStake.lockedCooldownPeriod = effectiveCooldown;

        uint256 unlockTime = block.timestamp + effectiveCooldown;
        emit UnstakeRequested(_poolId, msg.sender, _amount, unlockTime);
    }

    /// @notice Completes unstaking after cooldown period
    /// @dev If pool cooldown is waived, skips the cooldown check even for existing pending unstakes
    /// @param _poolId Pool identifier
    function completeUnstake(bytes32 _poolId) external whenNotPaused nonReentrant {
        UserStake storage userStake = userStakes[_poolId][msg.sender];
        if (userStake.pendingUnstakeAmount == 0) revert NoPendingUnstake();

        Pool storage pool = pools[_poolId];
        // Skip cooldown check if pool cooldown has been waived (e.g., after loan repayment)
        if (!pool.cooldownWaived) {
            if (block.timestamp < userStake.unstakeRequestTime + userStake.lockedCooldownPeriod) {
                revert CooldownNotComplete();
            }
        }

        uint256 amount = userStake.pendingUnstakeAmount;

        // Calculate shares to burn
        uint256 sharesToBurn = (amount * userStake.shares) / userStake.amount;
        if (sharesToBurn == 0) revert InsufficientShares();

        // Update state
        userStake.amount -= amount;
        userStake.shares -= sharesToBurn;
        userStake.pendingUnstakeAmount = 0;
        userStake.unstakeRequestTime = 0;
        userStake.lockedCooldownPeriod = 0;

        pool.totalStaked -= amount;
        pool.totalShares -= sharesToBurn;

        // Transfer tokens to user
        stakingToken.safeTransfer(msg.sender, amount);

        emit Unstaked(_poolId, msg.sender, amount);
    }

    /// @notice Cancels a pending unstake request
    /// @param _poolId Pool identifier
    function cancelUnstake(bytes32 _poolId) external nonReentrant {
        UserStake storage userStake = userStakes[_poolId][msg.sender];
        if (userStake.pendingUnstakeAmount == 0) revert NoPendingUnstake();

        userStake.pendingUnstakeAmount = 0;
        userStake.unstakeRequestTime = 0;
        userStake.lockedCooldownPeriod = 0;
    }

    ////////////////////////////////////////////////
    // YIELD DISTRIBUTION
    ////////////////////////////////////////////////

    /// @notice Distributes yield to a pool (increases share value)
    /// @param _poolId Pool identifier
    /// @param _amount Amount of yield to distribute
    function distributeYield(bytes32 _poolId, uint256 _amount) external onlyRole(POOL_MANAGER_ROLE) {
        if (_amount == 0) revert ZeroAmount();

        Pool storage pool = pools[_poolId];
        if (pool.poolId == bytes32(0)) revert PoolNotFound();

        // Transfer yield to contract
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Add to total staked (increases share price)
        pool.totalStaked += _amount;

        emit YieldDistributed(_poolId, _amount);
    }

    /// @notice Claims accrued yield without touching principal (available anytime)
    /// @dev Yield is the difference between current stake value and principal minus already claimed
    /// @param _poolId Pool identifier
    function claimYield(bytes32 _poolId) external whenNotPaused nonReentrant {
        Pool storage pool = pools[_poolId];
        if (pool.poolId == bytes32(0)) revert PoolNotFound();

        UserStake storage userStake = userStakes[_poolId][msg.sender];
        if (userStake.shares == 0) revert NoActiveStake();

        // Calculate current value of user's shares
        uint256 currentValue = (userStake.shares * pool.totalStaked) / pool.totalShares;

        // Yield = current value - principal - already claimed
        uint256 availableYield = 0;
        if (currentValue > userStake.principal + userStake.claimedYield) {
            availableYield = currentValue - userStake.principal - userStake.claimedYield;
        }

        if (availableYield == 0) revert NoYieldToClaim();

        // Update claimed yield tracking
        userStake.claimedYield += availableYield;

        // Calculate shares to burn for this yield withdrawal
        uint256 sharesToBurn = (availableYield * pool.totalShares) / pool.totalStaked;
        if (sharesToBurn > userStake.shares) {
            sharesToBurn = userStake.shares;
        }

        // Update pool state
        userStake.shares -= sharesToBurn;
        pool.totalShares -= sharesToBurn;
        pool.totalStaked -= availableYield;

        // Transfer yield to user
        stakingToken.safeTransfer(msg.sender, availableYield);

        emit YieldClaimed(_poolId, msg.sender, availableYield);
    }

    /// @notice Unstakes principal + any remaining yield (only available after pool maturity)
    /// @dev For pools with maturityDate set, principal is locked until that date
    /// @param _poolId Pool identifier
    function unstakeAtMaturity(bytes32 _poolId) external whenNotPaused nonReentrant {
        Pool storage pool = pools[_poolId];
        if (pool.poolId == bytes32(0)) revert PoolNotFound();

        // Pool must have a maturity date and it must have passed
        if (pool.maturityDate == 0 || block.timestamp < pool.maturityDate) {
            revert PoolNotMatured();
        }

        UserStake storage userStake = userStakes[_poolId][msg.sender];
        if (userStake.shares == 0) revert NoActiveStake();

        // Calculate total value of user's shares
        uint256 totalValue = (userStake.shares * pool.totalStaked) / pool.totalShares;

        // Amount to withdraw = total value - already claimed yield
        uint256 withdrawAmount = totalValue > userStake.claimedYield
            ? totalValue - userStake.claimedYield
            : 0;

        if (withdrawAmount == 0) revert ZeroAmount();

        // Store shares to burn before clearing
        uint256 sharesToBurn = userStake.shares;

        // Update pool state
        pool.totalShares -= sharesToBurn;
        pool.totalStaked -= withdrawAmount;

        // Clear user stake
        userStake.principal = 0;
        userStake.amount = 0;
        userStake.shares = 0;
        userStake.claimedYield = 0;
        userStake.stakedAt = 0;

        // Transfer remaining value to user
        stakingToken.safeTransfer(msg.sender, withdrawAmount);

        emit UnstakedAtMaturity(_poolId, msg.sender, withdrawAmount);
    }

    ////////////////////////////////////////////////
    // ADMIN FUNCTIONS
    ////////////////////////////////////////////////

    /// @notice Updates the cooldown period
    /// @param _newPeriod New cooldown period in seconds
    function setCooldownPeriod(uint256 _newPeriod) external onlyRole(POOL_MANAGER_ROLE) {
        if (_newPeriod > 30 days) revert InvalidCooldownPeriod();
        uint256 oldPeriod = cooldownPeriod;
        cooldownPeriod = _newPeriod;
        emit CooldownPeriodUpdated(oldPeriod, _newPeriod);
    }

    /// @notice Updates the fee recipient
    /// @param _newRecipient New fee recipient address
    function setFeeRecipient(address _newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newRecipient == address(0)) revert InvalidAddress();
        address oldRecipient = feeRecipient;
        feeRecipient = _newRecipient;
        emit FeeRecipientUpdated(oldRecipient, _newRecipient);
    }

    /// @notice Waives or restores the cooldown period for a pool
    /// @dev Call after loan repayment to let investors unstake immediately
    /// @param _poolId Pool identifier
    /// @param _waived True to waive cooldown, false to restore it
    function setPoolCooldownWaived(bytes32 _poolId, bool _waived) external onlyRole(POOL_MANAGER_ROLE) {
        Pool storage pool = pools[_poolId];
        if (pool.poolId == bytes32(0)) revert PoolNotFound();
        pool.cooldownWaived = _waived;
        emit PoolCooldownWaived(_poolId, _waived);
    }

    /// @notice Updates the minimum unstake amount
    /// @param _newMinimum New minimum unstake amount
    function setMinimumUnstakeAmount(uint256 _newMinimum) external onlyRole(POOL_MANAGER_ROLE) {
        minimumUnstakeAmount = _newMinimum;
    }

    /// @notice Recovers accidentally sent tokens (not staking token)
    /// @param _token Token to recover
    /// @param _amount Amount to recover
    /// @param _recipient Recipient address
    function recoverToken(
        IERC20 _token,
        uint256 _amount,
        address _recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_recipient == address(0)) revert InvalidAddress();
        if (address(_token) == address(stakingToken)) revert InvalidAddress();
        _token.safeTransfer(_recipient, _amount);
    }

    ////////////////////////////////////////////////
    // LOAN POOL INTEGRATION
    ////////////////////////////////////////////////

    /// @notice Total amount transferred to SimpleLoanPool for lending
    uint256 public totalTransferredToLoanPool;

    /// @notice Event emitted when funds are transferred to loan pool
    event FundsTransferredToLoanPool(address indexed destination, uint256 amount);

    /// @notice Transfers staking token funds to SimpleLoanPool for loan disbursement
    /// @dev Uses OpenZeppelin's audited SafeERC20 for secure transfers
    /// @param _amount Amount to transfer
    /// @param _destination SimpleLoanPool contract address
    function transferToLoanPool(
        uint256 _amount,
        address _destination
    ) external onlyRole(POOL_MANAGER_ROLE) {
        if (_destination == address(0)) revert InvalidAddress();
        if (_amount == 0) revert ZeroAmount();

        uint256 availableBalance = stakingToken.balanceOf(address(this));
        require(availableBalance >= _amount, "Insufficient pool balance");

        // Track transferred amount for accounting
        totalTransferredToLoanPool += _amount;

        // Use audited SafeERC20 for secure transfer
        stakingToken.safeTransfer(_destination, _amount);

        emit FundsTransferredToLoanPool(_destination, _amount);
    }

    /// @notice Pauses all staking operations
    function pause() external onlyRole(POOL_MANAGER_ROLE) {
        _pause();
    }

    /// @notice Unpauses all staking operations
    function unpause() external onlyRole(POOL_MANAGER_ROLE) {
        _unpause();
    }

    ////////////////////////////////////////////////
    // VIEW FUNCTIONS
    ////////////////////////////////////////////////

    /// @notice Gets user stake details
    /// @param _poolId Pool identifier
    /// @param _user User address
    /// @return principal Original deposit amount (locked until maturity)
    /// @return amount Current staked amount
    /// @return shares User shares
    /// @return stakedAt Timestamp when first staked
    /// @return pendingUnstake Amount pending unstake
    /// @return canWithdrawAt When user can withdraw (0 if no pending unstake)
    /// @return claimedYield Total yield already claimed
    function getUserStake(bytes32 _poolId, address _user)
        external
        view
        returns (
            uint256 principal,
            uint256 amount,
            uint256 shares,
            uint256 stakedAt,
            uint256 pendingUnstake,
            uint256 canWithdrawAt,
            uint256 claimedYield
        )
    {
        UserStake storage userStake = userStakes[_poolId][_user];
        principal = userStake.principal;
        amount = userStake.amount;
        shares = userStake.shares;
        stakedAt = userStake.stakedAt;
        pendingUnstake = userStake.pendingUnstakeAmount;
        canWithdrawAt = userStake.unstakeRequestTime > 0
            ? userStake.unstakeRequestTime + userStake.lockedCooldownPeriod
            : 0;
        claimedYield = userStake.claimedYield;
    }

    /// @notice Gets pool details
    /// @param _poolId Pool identifier
    function getPool(bytes32 _poolId)
        external
        view
        returns (
            string memory name,
            uint256 minimumStake,
            uint256 totalStaked,
            uint256 totalShares,
            uint256 feeRate,
            uint256 poolCooldownPeriod,
            uint256 maturityDate,
            address eligibilityRegistry,
            bool active,
            bool cooldownWaived
        )
    {
        Pool storage pool = pools[_poolId];
        return (
            pool.name,
            pool.minimumStake,
            pool.totalStaked,
            pool.totalShares,
            pool.feeRate,
            pool.cooldownPeriod,
            pool.maturityDate,
            pool.eligibilityRegistry,
            pool.active,
            pool.cooldownWaived
        );
    }

    /// @notice Gets the current value of a user's stake
    /// @param _poolId Pool identifier
    /// @param _user User address
    /// @return Current value of stake
    function getStakeValue(bytes32 _poolId, address _user) external view returns (uint256) {
        Pool storage pool = pools[_poolId];
        if (pool.poolId == bytes32(0)) revert PoolNotFound();

        UserStake storage userStake = userStakes[_poolId][_user];

        if (pool.totalShares == 0 || userStake.shares == 0) return 0;

        return (userStake.shares * pool.totalStaked) / pool.totalShares;
    }

    /// @notice Gets the available yield that can be claimed
    /// @param _poolId Pool identifier
    /// @param _user User address
    /// @return Available yield amount
    function getAvailableYield(bytes32 _poolId, address _user) external view returns (uint256) {
        Pool storage pool = pools[_poolId];
        if (pool.poolId == bytes32(0)) return 0;

        UserStake storage userStake = userStakes[_poolId][_user];
        if (pool.totalShares == 0 || userStake.shares == 0) return 0;

        // Calculate current value of user's shares
        uint256 currentValue = (userStake.shares * pool.totalStaked) / pool.totalShares;

        // Yield = current value - principal - already claimed
        if (currentValue > userStake.principal + userStake.claimedYield) {
            return currentValue - userStake.principal - userStake.claimedYield;
        }

        return 0;
    }

    /// @notice Gets all pool IDs
    function getAllPoolIds() external view returns (bytes32[] memory) {
        return poolIds;
    }

    /// @notice Gets the number of pools
    function getPoolCount() external view returns (uint256) {
        return poolIds.length;
    }

    ////////////////////////////////////////////////
    // UPGRADE
    ////////////////////////////////////////////////

    /// @notice Authorizes an upgrade to a new implementation
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}
}
