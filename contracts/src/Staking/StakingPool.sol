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
        bool active;
    }

    struct UserStake {
        uint256 amount;
        uint256 shares;
        uint256 stakedAt;
        uint256 unstakeRequestTime;
        uint256 pendingUnstakeAmount;
        uint256 lockedCooldownPeriod;
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
    event PoolCreated(bytes32 indexed poolId, string name, uint256 minimumStake, uint256 feeRate);
    event PoolUpdated(bytes32 indexed poolId, uint256 minimumStake, uint256 feeRate, bool active);
    event Staked(bytes32 indexed poolId, address indexed user, uint256 amount, uint256 shares, uint256 fee);
    event UnstakeRequested(bytes32 indexed poolId, address indexed user, uint256 amount, uint256 unlockTime);
    event Unstaked(bytes32 indexed poolId, address indexed user, uint256 amount);
    event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event YieldDistributed(bytes32 indexed poolId, uint256 amount);

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
    function createPool(
        bytes32 _poolId,
        string calldata _name,
        uint256 _minimumStake,
        uint256 _feeRate
    ) external onlyRole(POOL_MANAGER_ROLE) {
        if (pools[_poolId].poolId != bytes32(0)) revert PoolAlreadyExists();
        if (_feeRate > 1000) revert InvalidFeeRate(); // Max 10%

        pools[_poolId] = Pool({
            poolId: _poolId,
            name: _name,
            minimumStake: _minimumStake,
            totalStaked: 0,
            totalShares: 0,
            feeRate: _feeRate,
            active: true
        });

        poolIds.push(_poolId);
        emit PoolCreated(_poolId, _name, _minimumStake, _feeRate);
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
        userStake.amount += netAmount;
        userStake.shares += shares;
        if (userStake.stakedAt == 0) {
            userStake.stakedAt = block.timestamp;
        }

        pool.totalStaked += netAmount;
        pool.totalShares += shares;

        emit Staked(_poolId, msg.sender, netAmount, shares, fee);
    }

    /// @notice Requests to unstake tokens (starts cooldown)
    /// @param _poolId Pool identifier
    /// @param _amount Amount to unstake
    function requestUnstake(bytes32 _poolId, uint256 _amount) external whenNotPaused nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_amount < minimumUnstakeAmount) revert BelowMinimumUnstake();

        Pool storage pool = pools[_poolId];
        if (pool.poolId == bytes32(0)) revert PoolNotFound();

        UserStake storage userStake = userStakes[_poolId][msg.sender];
        if (userStake.amount == 0) revert NoActiveStake();
        if (_amount > userStake.amount) revert InsufficientStake();

        userStake.unstakeRequestTime = block.timestamp;
        userStake.pendingUnstakeAmount = _amount;
        userStake.lockedCooldownPeriod = cooldownPeriod;

        uint256 unlockTime = block.timestamp + cooldownPeriod;
        emit UnstakeRequested(_poolId, msg.sender, _amount, unlockTime);
    }

    /// @notice Completes unstaking after cooldown period
    /// @param _poolId Pool identifier
    function completeUnstake(bytes32 _poolId) external whenNotPaused nonReentrant {
        UserStake storage userStake = userStakes[_poolId][msg.sender];
        if (userStake.pendingUnstakeAmount == 0) revert NoPendingUnstake();
        if (block.timestamp < userStake.unstakeRequestTime + userStake.lockedCooldownPeriod) {
            revert CooldownNotComplete();
        }

        Pool storage pool = pools[_poolId];
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
    /// @return amount Staked amount
    /// @return shares User shares
    /// @return stakedAt Timestamp when first staked
    /// @return pendingUnstake Amount pending unstake
    /// @return canWithdrawAt When user can withdraw (0 if no pending unstake)
    function getUserStake(bytes32 _poolId, address _user)
        external
        view
        returns (
            uint256 amount,
            uint256 shares,
            uint256 stakedAt,
            uint256 pendingUnstake,
            uint256 canWithdrawAt
        )
    {
        UserStake storage userStake = userStakes[_poolId][_user];
        amount = userStake.amount;
        shares = userStake.shares;
        stakedAt = userStake.stakedAt;
        pendingUnstake = userStake.pendingUnstakeAmount;
        canWithdrawAt = userStake.unstakeRequestTime > 0
            ? userStake.unstakeRequestTime + userStake.lockedCooldownPeriod
            : 0;
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
            bool active
        )
    {
        Pool storage pool = pools[_poolId];
        return (
            pool.name,
            pool.minimumStake,
            pool.totalStaked,
            pool.totalShares,
            pool.feeRate,
            pool.active
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
