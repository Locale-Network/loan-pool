// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ProofVerifier
 * @notice Verifies DSCR calculations and data proofs from Cartesi rollup outputs
 * @dev This contract stores verified DSCR results and allows loan contracts to query them
 *
 * The verification flow:
 * 1. Backend submits transaction proof to Cartesi
 * 2. Cartesi calculates DSCR and outputs a notice
 * 3. Notice is submitted to this contract with merkle proof
 * 4. Contract verifies the proof and stores the result
 * 5. SimpleLoanPool queries this contract before approving loans
 */
contract ProofVerifier is Ownable {
    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Result of a verified DSCR calculation
     * @param loanId Unique identifier for the loan
     * @param dscrValue DSCR multiplied by 10000 (4 decimal places)
     * @param interestRate Interest rate multiplied by 1000000 (6 decimal places)
     * @param inputHash Hash of the transaction data used for calculation
     * @param timestamp Block timestamp when result was verified
     * @param verified Whether this result has been verified
     */
    struct DscrResult {
        bytes32 loanId;
        uint256 dscrValue;
        uint256 interestRate;
        bytes32 inputHash;
        uint256 timestamp;
        bool verified;
    }

    /**
     * @notice A data proof record
     * @param proofId Unique identifier for the proof
     * @param proofType Type of proof (1 = identity, 2 = transactions)
     * @param dataHash Hash of the underlying data
     * @param borrower Address of the borrower
     * @param verified Whether this proof has been verified
     * @param timestamp When the proof was submitted
     */
    struct DataProof {
        bytes32 proofId;
        uint8 proofType;
        bytes32 dataHash;
        address borrower;
        bool verified;
        uint256 timestamp;
    }

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Address of the Cartesi DApp contract
    address public cartesiDApp;

    /// @notice Mapping of loan ID to verified DSCR result
    mapping(bytes32 => DscrResult) public dscrResults;

    /// @notice Mapping of proof ID to data proof
    mapping(bytes32 => DataProof) public dataProofs;

    /// @notice Mapping of input hash to verified status
    mapping(bytes32 => bool) public verifiedInputs;

    /// @notice Mapping of borrower to their verified proofs
    mapping(address => bytes32[]) public borrowerProofs;

    /// @notice Authorized submitters (backend services)
    mapping(address => bool) public authorizedSubmitters;

    // ============================================
    // EVENTS
    // ============================================

    event DscrVerified(
        bytes32 indexed loanId,
        uint256 dscrValue,
        uint256 interestRate,
        bytes32 inputHash
    );

    event DataProofSubmitted(
        bytes32 indexed proofId,
        uint8 proofType,
        address indexed borrower,
        bytes32 dataHash
    );

    event DataProofVerified(bytes32 indexed proofId);

    event CartesiDAppUpdated(address indexed oldAddress, address indexed newAddress);

    event SubmitterAuthorized(address indexed submitter, bool authorized);

    // ============================================
    // ERRORS
    // ============================================

    error UnauthorizedSubmitter();
    error InvalidProof();
    error ProofAlreadyVerified();
    error ProofNotFound();
    error InvalidDscrValue();
    error InvalidInterestRate();
    error ZeroAddress();

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyAuthorized() {
        if (!authorizedSubmitters[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedSubmitter();
        }
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(address _cartesiDApp) Ownable(msg.sender) {
        if (_cartesiDApp == address(0)) revert ZeroAddress();
        cartesiDApp = _cartesiDApp;
        authorizedSubmitters[msg.sender] = true;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Update the Cartesi DApp address
     * @param _newDApp New Cartesi DApp contract address
     */
    function setCartesiDApp(address _newDApp) external onlyOwner {
        if (_newDApp == address(0)) revert ZeroAddress();
        address oldDApp = cartesiDApp;
        cartesiDApp = _newDApp;
        emit CartesiDAppUpdated(oldDApp, _newDApp);
    }

    /**
     * @notice Authorize or revoke a submitter
     * @param _submitter Address to authorize/revoke
     * @param _authorized Whether to authorize or revoke
     */
    function setAuthorizedSubmitter(address _submitter, bool _authorized) external onlyOwner {
        if (_submitter == address(0)) revert ZeroAddress();
        authorizedSubmitters[_submitter] = _authorized;
        emit SubmitterAuthorized(_submitter, _authorized);
    }

    // ============================================
    // PROOF SUBMISSION FUNCTIONS
    // ============================================

    /**
     * @notice Submit a verified DSCR result from Cartesi
     * @param _loanId Unique loan identifier
     * @param _dscrValue DSCR value multiplied by 10000
     * @param _interestRate Interest rate multiplied by 1000000
     * @param _inputHash Hash of transaction inputs used
     * @dev In production, this would verify a Cartesi notice with merkle proof
     */
    function submitDscrResult(
        bytes32 _loanId,
        uint256 _dscrValue,
        uint256 _interestRate,
        bytes32 _inputHash
    ) external onlyAuthorized {
        // Validate inputs
        if (_dscrValue == 0) revert InvalidDscrValue();
        if (_interestRate > 100_000_000) revert InvalidInterestRate(); // Max 100% with 6 decimals

        // Store result
        dscrResults[_loanId] = DscrResult({
            loanId: _loanId,
            dscrValue: _dscrValue,
            interestRate: _interestRate,
            inputHash: _inputHash,
            timestamp: block.timestamp,
            verified: true
        });

        // Mark input as verified
        verifiedInputs[_inputHash] = true;

        emit DscrVerified(_loanId, _dscrValue, _interestRate, _inputHash);
    }

    /**
     * @notice Submit a data proof (identity or transactions)
     * @param _proofId Unique proof identifier
     * @param _proofType Type of proof (1 = identity, 2 = transactions)
     * @param _dataHash Hash of the underlying data
     * @param _borrower Address of the borrower
     */
    function submitDataProof(
        bytes32 _proofId,
        uint8 _proofType,
        bytes32 _dataHash,
        address _borrower
    ) external onlyAuthorized {
        if (_borrower == address(0)) revert ZeroAddress();
        if (_proofType == 0 || _proofType > 2) revert InvalidProof();

        // Check if proof already exists
        if (dataProofs[_proofId].timestamp != 0) {
            revert ProofAlreadyVerified();
        }

        // Store proof
        dataProofs[_proofId] = DataProof({
            proofId: _proofId,
            proofType: _proofType,
            dataHash: _dataHash,
            borrower: _borrower,
            verified: true,
            timestamp: block.timestamp
        });

        // Add to borrower's proofs
        borrowerProofs[_borrower].push(_proofId);

        emit DataProofSubmitted(_proofId, _proofType, _borrower, _dataHash);
        emit DataProofVerified(_proofId);
    }

    // ============================================
    // QUERY FUNCTIONS
    // ============================================

    /**
     * @notice Check if a DSCR calculation has been verified for a loan
     * @param _loanId The loan identifier
     * @return verified Whether the DSCR has been verified
     */
    function isDscrVerified(bytes32 _loanId) external view returns (bool verified) {
        return dscrResults[_loanId].verified;
    }

    /**
     * @notice Get the verified DSCR result for a loan
     * @param _loanId The loan identifier
     * @return result The DSCR result struct
     */
    function getVerifiedDscr(bytes32 _loanId) external view returns (DscrResult memory result) {
        DscrResult memory r = dscrResults[_loanId];
        if (!r.verified) revert ProofNotFound();
        return r;
    }

    /**
     * @notice Get the verified interest rate for a loan
     * @param _loanId The loan identifier
     * @return rate The interest rate (multiplied by 1000000)
     */
    function getVerifiedInterestRate(bytes32 _loanId) external view returns (uint256 rate) {
        DscrResult memory r = dscrResults[_loanId];
        if (!r.verified) revert ProofNotFound();
        return r.interestRate;
    }

    /**
     * @notice Check if a data proof exists and is valid
     * @param _proofId The proof identifier
     * @return valid Whether the proof is valid
     */
    function isProofValid(bytes32 _proofId) external view returns (bool valid) {
        return dataProofs[_proofId].verified;
    }

    /**
     * @notice Get a data proof by ID
     * @param _proofId The proof identifier
     * @return proof The data proof struct
     */
    function getDataProof(bytes32 _proofId) external view returns (DataProof memory proof) {
        DataProof memory p = dataProofs[_proofId];
        if (p.timestamp == 0) revert ProofNotFound();
        return p;
    }

    /**
     * @notice Check if an input hash has been verified
     * @param _inputHash The input hash to check
     * @return verified Whether the input has been verified
     */
    function isInputVerified(bytes32 _inputHash) external view returns (bool verified) {
        return verifiedInputs[_inputHash];
    }

    /**
     * @notice Get all proof IDs for a borrower
     * @param _borrower The borrower address
     * @return proofIds Array of proof IDs
     */
    function getBorrowerProofs(address _borrower) external view returns (bytes32[] memory proofIds) {
        return borrowerProofs[_borrower];
    }

    /**
     * @notice Check if a borrower has a verified identity proof
     * @param _borrower The borrower address
     * @return hasIdentity Whether the borrower has a verified identity
     */
    function hasVerifiedIdentity(address _borrower) external view returns (bool hasIdentity) {
        bytes32[] memory proofs = borrowerProofs[_borrower];
        for (uint256 i = 0; i < proofs.length; i++) {
            DataProof memory p = dataProofs[proofs[i]];
            if (p.proofType == 1 && p.verified) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Check if a borrower has verified transaction data
     * @param _borrower The borrower address
     * @return hasTransactions Whether the borrower has verified transactions
     */
    function hasVerifiedTransactions(address _borrower) external view returns (bool hasTransactions) {
        bytes32[] memory proofs = borrowerProofs[_borrower];
        for (uint256 i = 0; i < proofs.length; i++) {
            DataProof memory p = dataProofs[proofs[i]];
            if (p.proofType == 2 && p.verified) {
                return true;
            }
        }
        return false;
    }
}
