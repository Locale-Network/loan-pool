// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IProofVerifier
 * @notice Interface for the ProofVerifier contract
 * @dev Used by SimpleLoanPool and other contracts to check verified DSCR results
 */
interface IProofVerifier {
    /**
     * @notice Result of a verified DSCR calculation
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
     */
    struct DataProof {
        bytes32 proofId;
        uint8 proofType;
        bytes32 dataHash;
        address borrower;
        bool verified;
        uint256 timestamp;
    }

    /**
     * @notice Check if a DSCR calculation has been verified for a loan
     * @param _loanId The loan identifier
     * @return verified Whether the DSCR has been verified
     */
    function isDscrVerified(bytes32 _loanId) external view returns (bool verified);

    /**
     * @notice Get the verified DSCR result for a loan
     * @param _loanId The loan identifier
     * @return result The DSCR result struct
     */
    function getVerifiedDscr(bytes32 _loanId) external view returns (DscrResult memory result);

    /**
     * @notice Get the verified interest rate for a loan
     * @param _loanId The loan identifier
     * @return rate The interest rate (multiplied by 1000000)
     */
    function getVerifiedInterestRate(bytes32 _loanId) external view returns (uint256 rate);

    /**
     * @notice Check if a data proof exists and is valid
     * @param _proofId The proof identifier
     * @return valid Whether the proof is valid
     */
    function isProofValid(bytes32 _proofId) external view returns (bool valid);

    /**
     * @notice Get a data proof by ID
     * @param _proofId The proof identifier
     * @return proof The data proof struct
     */
    function getDataProof(bytes32 _proofId) external view returns (DataProof memory proof);

    /**
     * @notice Check if an input hash has been verified
     * @param _inputHash The input hash to check
     * @return verified Whether the input has been verified
     */
    function isInputVerified(bytes32 _inputHash) external view returns (bool verified);

    /**
     * @notice Check if a borrower has a verified identity proof
     * @param _borrower The borrower address
     * @return hasIdentity Whether the borrower has a verified identity
     */
    function hasVerifiedIdentity(address _borrower) external view returns (bool hasIdentity);

    /**
     * @notice Check if a borrower has verified transaction data
     * @param _borrower The borrower address
     * @return hasTransactions Whether the borrower has verified transactions
     */
    function hasVerifiedTransactions(address _borrower) external view returns (bool hasTransactions);
}
