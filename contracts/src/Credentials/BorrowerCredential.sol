// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title BorrowerCredential
/// @notice Soulbound Token (SBT) representing borrower KYC credentials
/// @dev Non-transferable ERC-721 token issued upon successful Plaid KYC verification
/// @custom:security-contact security@locale-lending.com
contract BorrowerCredential is
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

    /// @notice Credential data structure
    struct Credential {
        uint256 kycLevel;        // 0 = None, 1 = Basic, 2 = Enhanced
        uint256 issuedAt;        // Timestamp when issued
        uint256 expiresAt;       // Expiration timestamp
        bool revoked;            // Revocation status
        string plaidVerificationId; // Plaid identity verification ID
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
        uint256 kycLevel,
        uint256 expiresAt,
        string plaidVerificationId
    );
    event CredentialRevoked(uint256 indexed tokenId, string reason);
    event CredentialRenewed(uint256 indexed tokenId, uint256 newExpiresAt);

    ////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////
    error TokenIsSoulbound();
    error CredentialExpired();
    error CredentialIsRevoked();
    error CredentialAlreadyExists();
    error InvalidKYCLevel();
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
        __ERC721_init("Locale Borrower Credential", "LBC");
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

    /// @notice Issues a new borrower credential
    /// @param to Address to receive the credential
    /// @param kycLevel KYC verification level (1 = Basic, 2 = Enhanced)
    /// @param validityPeriod Validity period in seconds
    /// @param plaidVerificationId Plaid identity verification ID
    /// @return tokenId The ID of the newly minted credential
    function issueCredential(
        address to,
        uint256 kycLevel,
        uint256 validityPeriod,
        string memory plaidVerificationId
    ) external onlyRole(ISSUER_ROLE) whenNotPaused returns (uint256) {
        if (kycLevel == 0 || kycLevel > 2) revert InvalidKYCLevel();
        if (validityPeriod == 0) revert InvalidValidity();
        if (addressToTokenId[to] != 0) revert CredentialAlreadyExists();

        uint256 tokenId = _nextTokenId++;
        uint256 expiresAt = block.timestamp + validityPeriod;

        _safeMint(to, tokenId);

        credentials[tokenId] = Credential({
            kycLevel: kycLevel,
            issuedAt: block.timestamp,
            expiresAt: expiresAt,
            revoked: false,
            plaidVerificationId: plaidVerificationId
        });

        addressToTokenId[to] = tokenId;

        emit CredentialIssued(to, tokenId, kycLevel, expiresAt, plaidVerificationId);

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

    /// @notice Gets the KYC level of an address
    /// @param account Address to check
    /// @return uint256 KYC level (0 if no valid credential)
    function getKYCLevel(address account) public view returns (uint256) {
        uint256 tokenId = addressToTokenId[account];
        if (tokenId == 0 || !isCredentialValid(tokenId)) {
            return 0;
        }

        return credentials[tokenId].kycLevel;
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
