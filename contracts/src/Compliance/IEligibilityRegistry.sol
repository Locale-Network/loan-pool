// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IEligibilityRegistry
/// @notice Interface for investor eligibility verification (Reg D 506(b) compliance)
/// @dev Implementations must track accreditation status and non-accredited investor limits
interface IEligibilityRegistry {
    /// @notice Investor eligibility status
    enum InvestorStatus {
        INELIGIBLE,      // Cannot invest
        ACCREDITED,      // Accredited investor (no limit on count)
        NON_ACCREDITED   // Non-accredited investor (limited to 35 per pool)
    }

    /// @notice Checks if an investor can invest in the pool
    /// @param investor Address of the investor
    /// @return canInvest Whether the investor can invest
    /// @return reason Human-readable reason if cannot invest
    function canInvest(address investor) external view returns (bool canInvest, string memory reason);

    /// @notice Gets the eligibility status of an investor
    /// @param investor Address of the investor
    /// @return status The investor's eligibility status
    function getInvestorStatus(address investor) external view returns (InvestorStatus status);

    /// @notice Checks if an investor has already invested
    /// @param investor Address of the investor
    /// @return Whether the investor has invested
    function hasInvested(address investor) external view returns (bool);

    /// @notice Marks an investor as having invested (called by StakingPool)
    /// @dev Can only be called by authorized pool contracts
    /// @param investor Address of the investor
    function markAsInvested(address investor) external;

    /// @notice Sets the eligibility status for an investor
    /// @dev Can only be called by verifiers
    /// @param investor Address of the investor
    /// @param status New eligibility status
    function setInvestorStatus(address investor, InvestorStatus status) external;

    /// @notice Gets the current count of non-accredited investors who have invested
    /// @return Current count of non-accredited investors
    function getNonAccreditedInvestorCount() external view returns (uint256);

    /// @notice Gets the maximum allowed non-accredited investors
    /// @return Maximum allowed non-accredited investors (typically 35)
    function getMaxNonAccreditedInvestors() external view returns (uint256);

    /// @notice Checks if contract upgrades are locked (after first investment)
    /// @return Whether upgrades are locked
    function areUpgradesLocked() external view returns (bool);

    /// @notice Emitted when investor status is updated
    event InvestorStatusUpdated(address indexed investor, InvestorStatus oldStatus, InvestorStatus newStatus);

    /// @notice Emitted when an investor is marked as having invested
    event InvestorMarkedAsInvested(address indexed investor, InvestorStatus status);

    /// @notice Emitted when upgrades are locked
    event UpgradesLocked();
}
