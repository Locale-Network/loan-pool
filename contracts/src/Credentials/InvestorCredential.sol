// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title InvestorCredential
/// @notice Soulbound Token (SBT) representing investor accreditation credentials
/// @dev Non-transferable ERC-721 token issued upon successful Plaid KYC/AML verification
/// @custom:security-contact security@locale-lending.com
contract InvestorCredential is
    Initializable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    ////////////////////////////////////////////////
    // ROLES
    ////////////////////////////////////////////////
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant REVOKER_ROLE = keccak256("REVOKER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    ////////////////////////////////////////////////
    // STATE VARIABLES
    ////////////////////////////////////////////////

    /// @notice Counter for token IDs
    uint256 private _nextTokenId;

    /// @notice Accreditation levels
    /// 0 = None (retail investor)
    /// 1 = Accredited investor ($200k income or $1M net worth)
    /// 2 = Qualified purchaser ($5M+ in investments)
    /// 3 = Institutional investor

    /// @notice Credential data structure
    struct Credential {
        uint256 accreditationLevel; // Accreditation status
        uint256 issuedAt;          // Timestamp when issued
        uint256 expiresAt;         // Expiration timestamp
        bool revoked;              // Revocation status
        string plaidVerificationId; // Plaid identity verification ID
        uint256 investmentLimit;   // Maximum investment allowed (0 = unlimited)
    }

    /// @notice Mapping from token ID to credential data
    mapping(uint256 => Credential) public credentials;

    /// @notice Mapping from address to token ID (one credential per address)
    mapping(address => uint256) public addressToTokenId;

    ////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////
    event CredentialIssued(
        address indexed to,
        uint256 indexed tokenId,
        uint256 accreditationLevel,
        uint256 expiresAt,
        uint256 investmentLimit,
        string plaidVerificationId
    );
    event CredentialRevoked(uint256 indexed tokenId, string reason);
    event CredentialRenewed(uint256 indexed tokenId, uint256 newExpiresAt);
    event AccreditationUpgraded(uint256 indexed tokenId, uint256 oldLevel, uint256 newLevel);
    event InvestmentLimitUpdated(uint256 indexed tokenId, uint256 oldLimit, uint256 newLimit);

    ////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////
    error TokenIsSoulbound();
    error CredentialExpired();
    error CredentialIsRevoked();
    error CredentialAlreadyExists();
    error InvalidAccreditationLevel();
    error InvalidValidity();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    ////////////////////////////////////////////////
    // INITIALIZATION
    ////////////////////////////////////////////////

    /// @notice Initializes the contract
    /// @param _admin Address of the admin
    function initialize(address _admin) public initializer {
        __ERC721_init("Locale Investor Credential", "LIC");
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ISSUER_ROLE, _admin);
        _grantRole(REVOKER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        _nextTokenId = 1; // Start from 1
    }

    ////////////////////////////////////////////////
    // CREDENTIAL ISSUANCE
    ////////////////////////////////////////////////

    /// @notice Issues a new investor credential
    /// @param to Address to receive the credential
    /// @param accreditationLevel Accreditation level (0-3)
    /// @param validityPeriod Validity period in seconds
    /// @param investmentLimit Maximum investment allowed (0 = unlimited)
    /// @param plaidVerificationId Plaid identity verification ID
    /// @return tokenId The ID of the newly minted credential
    function issueCredential(
        address to,
        uint256 accreditationLevel,
        uint256 validityPeriod,
        uint256 investmentLimit,
        string memory plaidVerificationId
    ) external onlyRole(ISSUER_ROLE) whenNotPaused returns (uint256) {
        if (accreditationLevel > 3) revert InvalidAccreditationLevel();
        if (validityPeriod == 0) revert InvalidValidity();
        if (addressToTokenId[to] != 0) revert CredentialAlreadyExists();

        uint256 tokenId = _nextTokenId++;
        uint256 expiresAt = block.timestamp + validityPeriod;

        _safeMint(to, tokenId);

        credentials[tokenId] = Credential({
            accreditationLevel: accreditationLevel,
            issuedAt: block.timestamp,
            expiresAt: expiresAt,
            revoked: false,
            plaidVerificationId: plaidVerificationId,
            investmentLimit: investmentLimit
        });

        addressToTokenId[to] = tokenId;

        emit CredentialIssued(
            to,
            tokenId,
            accreditationLevel,
            expiresAt,
            investmentLimit,
            plaidVerificationId
        );

        return tokenId;
    }

    /// @notice Renews an existing credential
    /// @param tokenId ID of the credential to renew
    /// @param additionalValidity Additional validity period in seconds
    function renewCredential(
        uint256 tokenId,
        uint256 additionalValidity
    ) external onlyRole(ISSUER_ROLE) whenNotPaused {
        if (additionalValidity == 0) revert InvalidValidity();

        Credential storage credential = credentials[tokenId];
        if (credential.revoked) revert CredentialIsRevoked();

        credential.expiresAt += additionalValidity;

        emit CredentialRenewed(tokenId, credential.expiresAt);
    }

    /// @notice Upgrades accreditation level
    /// @param tokenId ID of the credential
    /// @param newLevel New accreditation level
    function upgradeAccreditation(
        uint256 tokenId,
        uint256 newLevel
    ) external onlyRole(ISSUER_ROLE) whenNotPaused {
        if (newLevel > 3) revert InvalidAccreditationLevel();

        Credential storage credential = credentials[tokenId];
        if (credential.revoked) revert CredentialIsRevoked();

        uint256 oldLevel = credential.accreditationLevel;
        credential.accreditationLevel = newLevel;

        emit AccreditationUpgraded(tokenId, oldLevel, newLevel);
    }

    /// @notice Updates investment limit
    /// @param tokenId ID of the credential
    /// @param newLimit New investment limit (0 = unlimited)
    function updateInvestmentLimit(
        uint256 tokenId,
        uint256 newLimit
    ) external onlyRole(ISSUER_ROLE) whenNotPaused {
        Credential storage credential = credentials[tokenId];
        if (credential.revoked) revert CredentialIsRevoked();

        uint256 oldLimit = credential.investmentLimit;
        credential.investmentLimit = newLimit;

        emit InvestmentLimitUpdated(tokenId, oldLimit, newLimit);
    }

    /// @notice Revokes a credential
    /// @param tokenId ID of the credential to revoke
    /// @param reason Reason for revocation
    function revokeCredential(
        uint256 tokenId,
        string memory reason
    ) external onlyRole(REVOKER_ROLE) {
        Credential storage credential = credentials[tokenId];
        credential.revoked = true;

        emit CredentialRevoked(tokenId, reason);
    }

    ////////////////////////////////////////////////
    // VIEW FUNCTIONS
    ////////////////////////////////////////////////

    /// @notice Checks if a credential is valid
    /// @param tokenId ID of the credential
    /// @return bool True if valid, false otherwise
    function isCredentialValid(uint256 tokenId) public view returns (bool) {
        Credential memory credential = credentials[tokenId];

        if (credential.revoked) return false;
        if (block.timestamp > credential.expiresAt) return false;

        return true;
    }

    /// @notice Checks if an address has a valid credential
    /// @param account Address to check
    /// @return bool True if has valid credential, false otherwise
    function hasValidCredential(address account) public view returns (bool) {
        uint256 tokenId = addressToTokenId[account];
        if (tokenId == 0) return false;

        return isCredentialValid(tokenId);
    }

    /// @notice Gets the accreditation level of an address
    /// @param account Address to check
    /// @return uint256 Accreditation level (returns 0 if no valid credential)
    function getAccreditationLevel(address account) public view returns (uint256) {
        uint256 tokenId = addressToTokenId[account];
        if (tokenId == 0 || !isCredentialValid(tokenId)) {
            return 0;
        }

        return credentials[tokenId].accreditationLevel;
    }

    /// @notice Gets the investment limit for an address
    /// @param account Address to check
    /// @return uint256 Investment limit (0 = unlimited or no credential)
    function getInvestmentLimit(address account) public view returns (uint256) {
        uint256 tokenId = addressToTokenId[account];
        if (tokenId == 0 || !isCredentialValid(tokenId)) {
            return 0;
        }

        return credentials[tokenId].investmentLimit;
    }

    /// @notice Checks if an address is an accredited investor
    /// @param account Address to check
    /// @return bool True if accredited (level >= 1), false otherwise
    function isAccredited(address account) public view returns (bool) {
        return getAccreditationLevel(account) >= 1;
    }

    ////////////////////////////////////////////////
    // SOULBOUND ENFORCEMENT
    ////////////////////////////////////////////////

    /// @notice Prevents token transfers (soulbound)
    /// @dev Overrides ERC721 transfer functions to make tokens non-transferable
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Allow minting (from == address(0))
        // Allow burning (to == address(0))
        // Block all transfers
        if (from != address(0) && to != address(0)) {
            revert TokenIsSoulbound();
        }

        return super._update(to, tokenId, auth);
    }

    /// @notice Prevents approvals (soulbound)
    function approve(address, uint256) public pure override {
        revert TokenIsSoulbound();
    }

    /// @notice Prevents operator approvals (soulbound)
    function setApprovalForAll(address, bool) public pure override {
        revert TokenIsSoulbound();
    }

    ////////////////////////////////////////////////
    // EMERGENCY CONTROLS
    ////////////////////////////////////////////////

    /// @notice Pauses credential issuance
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses credential issuance
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    ////////////////////////////////////////////////
    // UPGRADE
    ////////////////////////////////////////////////

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of new implementation
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    ////////////////////////////////////////////////
    // REQUIRED OVERRIDES
    ////////////////////////////////////////////////

    /// @notice Checks if contract supports an interface
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
