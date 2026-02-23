// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IEligibilityRegistry} from "./IEligibilityRegistry.sol";

/// @title EligibilityRegistry
/// @notice Manages investor eligibility for Reg D 506(b) compliant pools
/// @dev Tracks accreditation status and enforces the 35 non-accredited investor limit
/// @custom:security-contact security@locale-lending.com
contract EligibilityRegistry is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IEligibilityRegistry
{
    ////////////////////////////////////////////////
    // ROLES
    ////////////////////////////////////////////////

    /// @notice Role for verifying investor accreditation
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    /// @notice Role for authorized pool contracts to mark investments
    bytes32 public constant POOL_ROLE = keccak256("POOL_ROLE");

    /// @notice Role for upgrading the contract
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    ////////////////////////////////////////////////
    // STATE VARIABLES
    ////////////////////////////////////////////////

    /// @notice Maximum number of non-accredited investors allowed (Reg D 506(b) limit)
    uint256 public maxNonAccreditedInvestors;

    /// @notice Current count of non-accredited investors who have invested
    uint256 public nonAccreditedInvestorCount;

    /// @notice Whether upgrades are locked (after first investment)
    bool public upgradesLocked;

    /// @notice Mapping of investor address to their eligibility status
    mapping(address => InvestorStatus) public investorStatus;

    /// @notice Mapping of investor address to whether they have invested
    mapping(address => bool) public investorHasInvested;

    ////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////

    error InvestorAlreadyInvested();
    error MaxNonAccreditedReached();
    error InvalidStatus();
    error UpgradesAreLocked();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    ////////////////////////////////////////////////
    // INITIALIZATION
    ////////////////////////////////////////////////

    /// @notice Initializes the eligibility registry
    /// @param _admin Address of the admin (receives DEFAULT_ADMIN_ROLE)
    /// @param _maxNonAccredited Maximum non-accredited investors (typically 35)
    function initialize(
        address _admin,
        uint256 _maxNonAccredited
    ) public initializer {
        if (_admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();

        maxNonAccreditedInvestors = _maxNonAccredited;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(VERIFIER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    ////////////////////////////////////////////////
    // ELIGIBILITY MANAGEMENT
    ////////////////////////////////////////////////

    /// @inheritdoc IEligibilityRegistry
    function setInvestorStatus(
        address investor,
        InvestorStatus status
    ) external onlyRole(VERIFIER_ROLE) {
        if (investor == address(0)) revert ZeroAddress();

        // Cannot change status after investment (immutable once invested)
        if (investorHasInvested[investor]) revert InvestorAlreadyInvested();

        InvestorStatus oldStatus = investorStatus[investor];
        investorStatus[investor] = status;

        emit InvestorStatusUpdated(investor, oldStatus, status);
    }

    /// @inheritdoc IEligibilityRegistry
    function markAsInvested(address investor) external onlyRole(POOL_ROLE) {
        if (investor == address(0)) revert ZeroAddress();
        if (investorHasInvested[investor]) return; // Already marked, no-op

        InvestorStatus status = investorStatus[investor];

        // Enforce non-accredited limit
        if (status == InvestorStatus.NON_ACCREDITED) {
            if (nonAccreditedInvestorCount >= maxNonAccreditedInvestors) {
                revert MaxNonAccreditedReached();
            }
            nonAccreditedInvestorCount++;
        }

        investorHasInvested[investor] = true;

        // Lock upgrades after first investment for regulatory compliance
        if (!upgradesLocked) {
            upgradesLocked = true;
            emit UpgradesLocked();
        }

        emit InvestorMarkedAsInvested(investor, status);
    }

    ////////////////////////////////////////////////
    // VIEW FUNCTIONS
    ////////////////////////////////////////////////

    /// @inheritdoc IEligibilityRegistry
    function canInvest(address investor) external view returns (bool, string memory) {
        if (investor == address(0)) {
            return (false, "Invalid address");
        }

        InvestorStatus status = investorStatus[investor];

        if (status == InvestorStatus.INELIGIBLE) {
            return (false, "Investor not verified");
        }

        if (status == InvestorStatus.ACCREDITED) {
            return (true, "");
        }

        if (status == InvestorStatus.NON_ACCREDITED) {
            // Check if already invested (allowed to add more to existing position)
            if (investorHasInvested[investor]) {
                return (true, "");
            }

            // Check if limit reached for new non-accredited investors
            if (nonAccreditedInvestorCount >= maxNonAccreditedInvestors) {
                return (false, "Non-accredited investor limit reached");
            }

            return (true, "");
        }

        return (false, "Unknown status");
    }

    /// @inheritdoc IEligibilityRegistry
    function getInvestorStatus(address investor) external view returns (InvestorStatus) {
        return investorStatus[investor];
    }

    /// @inheritdoc IEligibilityRegistry
    function hasInvested(address investor) external view returns (bool) {
        return investorHasInvested[investor];
    }

    /// @inheritdoc IEligibilityRegistry
    function getNonAccreditedInvestorCount() external view returns (uint256) {
        return nonAccreditedInvestorCount;
    }

    /// @inheritdoc IEligibilityRegistry
    function getMaxNonAccreditedInvestors() external view returns (uint256) {
        return maxNonAccreditedInvestors;
    }

    /// @inheritdoc IEligibilityRegistry
    function areUpgradesLocked() external view returns (bool) {
        return upgradesLocked;
    }

    ////////////////////////////////////////////////
    // ADMIN FUNCTIONS
    ////////////////////////////////////////////////

    /// @notice Updates the maximum non-accredited investors limit
    /// @dev Can only be called before first investment
    /// @param _newMax New maximum limit
    function setMaxNonAccreditedInvestors(uint256 _newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (upgradesLocked) revert UpgradesAreLocked();
        maxNonAccreditedInvestors = _newMax;
    }

    ////////////////////////////////////////////////
    // UPGRADE
    ////////////////////////////////////////////////

    /// @notice Authorizes contract upgrades
    /// @dev Blocked after first investment for regulatory compliance
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {
        if (upgradesLocked) revert UpgradesAreLocked();
    }
}
