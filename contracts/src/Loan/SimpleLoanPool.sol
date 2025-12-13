// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IProofVerifier} from "../Verification/IProofVerifier.sol";

/// @title SimpleLoanPool
/// @notice A contract for managing simple loans with interest
/// @dev Implements upgradeable pattern with access control and optional proof verification
contract SimpleLoanPool is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    ////////////////////////////////////////////////
    // ROLES
    ////////////////////////////////////////////////
    bytes32 public constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 public constant SYSTEM_ROLE = keccak256("SYSTEM_ROLE");
    bytes32 public constant APPROVER_ROLE = keccak256("APPROVER_ROLE");

    // Custom errors
    error MustHaveApproverRole(address account);
    error DscrNotVerified(bytes32 loanId);
    error ProofVerifierNotSet();

	////////////////////////////////////////////////
	// EVENTS
	////////////////////////////////////////////////
	event LoanCreated(bytes32 loanId, address borrower, uint256 amount, uint256 interestRate, uint256 repaymentRemainingMonths);
	event LoanActivated(bytes32 loanId, address borrower, uint256 amount);
	event LoanInterestRateUpdated(bytes32 loanId, uint256 interestRate);
	event LoanRepaymentRemainingMonthsUpdated(bytes32 loanId, uint256 repaymentRemainingMonths);
	event LoanRepaymentMade(bytes32 loanId, address borrower, uint256 repaymentAmount, uint256 interestAmount);
	event ProofVerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
	event LoanCreatedWithVerifiedDscr(bytes32 loanId, address borrower, uint256 amount, uint256 dscrValue, uint256 interestRate);
    event RelayServiceUpdated(address indexed oldRelay, address indexed newRelay);

    // zkFetch + Cartesi DSCR verification events
    event DscrVerifiedZkFetch(
        bytes32 indexed loanId,
        address indexed borrower,
        uint256 dscrValue,
        uint256 interestRate,
        bytes32 proofHash,
        uint256 timestamp
    );

    ////////////////////////////////////////////////
    // STATE
    ////////////////////////////////////////////////
    ERC20Upgradeable public token;
    IProofVerifier public proofVerifier;

    mapping(bytes32 => bool) public loanIdToActive;
    mapping(bytes32 => address) public loanIdToBorrower;
    mapping(bytes32 => uint256) public loanIdToAmount;
	mapping(bytes32 => uint256) public loanIdToInterestAmount;
    mapping(bytes32 => uint256) public loanIdToInterestRate;
    mapping(bytes32 => uint256) public loanIdToRepaymentAmount;
	mapping(bytes32 => uint256) public loanIdToInterestRepaymentAmount;
    mapping(bytes32 => uint256) public loanIdToRepaymentRemainingMonths;

    mapping(address => uint256) public loanAmounts;

    uint256 public totalLentAmount;

    // Relay service for Cartesi notice handling
    address public relayService;

    // zkFetch + Cartesi DSCR verification state
    struct ZkFetchDscrResult {
        uint256 dscrValue;           // DSCR value (scaled by 1000, e.g., 1500 = 1.5)
        uint256 interestRate;        // Interest rate in basis points (e.g., 500 = 5%)
        bytes32 proofHash;           // Hash of the zkFetch proof
        uint256 verifiedAt;          // Timestamp of verification
        bool isValid;                // Whether the result is still valid
    }
    mapping(bytes32 => ZkFetchDscrResult) public zkFetchDscrResults;  // loanId => result
    mapping(address => bytes32) public borrowerLatestLoanId;          // borrower => latest verified loanId

    ////////////////////////////////////////////////
    // CONSTRUCTOR
    ////////////////////////////////////////////////
    /// @notice Initializes the contract with owner, approvers and token
    /// @param _owner Address of the contract owner
    /// @param approvers Array of initial approver addresses
    /// @param _token Address of the ERC20 token used for loans
    function initialize(
        address _owner,
        address[] memory approvers,
        ERC20Upgradeable _token
    ) public initializer {
        __Ownable_init(_owner);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);

        _setRoleAdmin(POOL_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(POOL_MANAGER_ROLE, _owner);

        _setRoleAdmin(APPROVER_ROLE, DEFAULT_ADMIN_ROLE);

        for (uint256 i = 0; i < approvers.length; i++) {
            _grantRole(APPROVER_ROLE, approvers[i]);
        }

        token = _token;
    }

    ////////////////////////////////////////////////
    // MODIFIERS
    ////////////////////////////////////////////////
    modifier onlySystemOrPoolManager() {
        require(
            hasRole(SYSTEM_ROLE, msg.sender) ||
                hasRole(POOL_MANAGER_ROLE, msg.sender),
            "Must have system or pool manager role"
        );
        _;
    }

    modifier onlyApprover() {
        require(hasRole(APPROVER_ROLE, msg.sender), "Must have approver role");
        _;
    }

    modifier loanExists(bytes32 _loanId) {
        require(loanIdToBorrower[_loanId] != address(0), "Loan does not exist");
        _;
    }

	modifier loanNotExists(bytes32 _loanId) {
		require(loanIdToBorrower[_loanId] == address(0), "Loan already exists");
		_;
	}
	
	modifier onlyActiveLoan(bytes32 _loanId) {
		require(loanIdToActive[_loanId], "Loan is not active");
		_;
	}

    modifier onlyUnpaidLoan(bytes32 _loanId) {
        require(loanIdToRepaymentAmount[_loanId] < loanIdToAmount[_loanId], "Loan is fully paid");
        _;
    }

	modifier onlyInactiveLoan(bytes32 _loanId) {
		require(!loanIdToActive[_loanId], "Loan already created");
		_;
	}

    modifier poolHasFunds(uint256 _amount) {
        require(
            token.balanceOf(address(this)) >= _amount,
            "Pool does not have enough funds"
        );
        _;
    }

    modifier requireVerifiedDscr(bytes32 _loanId) {
        if (address(proofVerifier) == address(0)) {
            revert ProofVerifierNotSet();
        }
        if (!proofVerifier.isDscrVerified(_loanId)) {
            revert DscrNotVerified(_loanId);
        }
        _;
    }

    modifier requireVerifiedBorrower(address _borrower) {
        if (address(proofVerifier) == address(0)) {
            revert ProofVerifierNotSet();
        }
        require(
            proofVerifier.hasVerifiedIdentity(_borrower),
            "Borrower identity not verified"
        );
        _;
    }

    ////////////////////////////////////////////////
    // FUNCTIONS
    ////////////////////////////////////////////////

    /// @notice Transfers tokens from the pool to a specified address
    /// @param to The recipient address
    /// @param amount The amount of tokens to transfer
    /// @return success Whether the transfer was successful
    function transferFunds(
        address to,
        uint256 amount
    ) external onlyOwner returns (bool success) {
        return token.transfer(to, amount);
    }

    /// @notice Creates a new loan record
    /// @param _loanId Unique identifier for the loan
    /// @param _borrower Address of the borrower
    /// @param _amount Loan amount
    /// @param _interestRate Interest rate for the loan
    /// @param _repaymentRemainingMonths Number of months for repayment
    function createLoan(
        bytes32 _loanId,
        address _borrower,
        uint256 _amount,
        uint256 _interestRate,
        uint256 _repaymentRemainingMonths
    ) external whenNotPaused onlySystemOrPoolManager loanNotExists(_loanId) {
        loanIdToBorrower[_loanId] = _borrower;
        loanIdToAmount[_loanId] = _amount;
        // Updated formula: multiply by 100 in denominator to account for basis points
        loanIdToInterestAmount[_loanId] = (_amount * _interestRate * _repaymentRemainingMonths) / (12 * 10000);
        loanIdToInterestRate[_loanId] = _interestRate;
        loanIdToRepaymentAmount[_loanId] = 0;
        loanIdToRepaymentRemainingMonths[_loanId] = _repaymentRemainingMonths;
		
		emit LoanCreated(_loanId, _borrower, _amount, _interestRate, _repaymentRemainingMonths);
    }

	/// @notice Activates a created loan and transfers funds to borrower
	/// @param _loanId Unique identifier for the loan
	function activateLoan(bytes32 _loanId) external whenNotPaused nonReentrant onlySystemOrPoolManager loanExists(_loanId) onlyInactiveLoan(_loanId) {
		loanIdToActive[_loanId] = true;

		uint256 amount = loanIdToAmount[_loanId];

        totalLentAmount += amount;
		token.transfer(loanIdToBorrower[_loanId], amount);

		emit LoanActivated(_loanId, loanIdToBorrower[_loanId], amount);
	}

	/// @notice Calculates the next repayment amount for a loan
	/// @param _loanId Unique identifier for the loan
	/// @return The calculated repayment amount
	function getNextRepayment(bytes32 _loanId) public view returns (uint256, uint256) {
		uint256 amount = loanIdToAmount[_loanId];
		uint256 interestAmount = loanIdToInterestAmount[_loanId];

		uint256 repaidAmount = loanIdToRepaymentAmount[_loanId];
		uint256 remainingAmount = amount + interestAmount - repaidAmount;
		uint256 interestRate = loanIdToInterestRate[_loanId];
		uint256 repaymentRemainingMonths = loanIdToRepaymentRemainingMonths[_loanId];
		
		// Updated formula: multiply by 100 in denominator to account for basis points
		return (remainingAmount, (remainingAmount * interestRate) / (12 * 10000 * repaymentRemainingMonths));
	}

    /// @notice Updates the interest rate for an active loan
    /// @param _loanId Unique identifier for the loan
    /// @param _interestRate New interest rate to set
    function updateLoanInterestRate(
        bytes32 _loanId,
        uint256 _interestRate
    ) external onlySystemOrPoolManager loanExists(_loanId) onlyUnpaidLoan(_loanId) {
        loanIdToInterestRate[_loanId] = _interestRate;

		uint256 amount = loanIdToAmount[_loanId];
		uint256 repaidAmount = loanIdToRepaymentAmount[_loanId];
		uint256 remainingAmount = amount - repaidAmount;
		// Updated formula: multiply by 100 in denominator to account for basis points
		loanIdToInterestAmount[_loanId] = (remainingAmount * _interestRate * loanIdToRepaymentRemainingMonths[_loanId]) / (12 * 10000);

		emit LoanInterestRateUpdated(_loanId, _interestRate);
    }

    /// @notice Updates the remaining months for loan repayment
    /// @param _loanId Unique identifier for the loan
    /// @param _repaymentRemainingMonths New number of remaining months
    function updateLoanRepaymentRemainingMonths(
        bytes32 _loanId,
        uint256 _repaymentRemainingMonths
    ) external onlySystemOrPoolManager loanExists(_loanId) onlyUnpaidLoan(_loanId) {
        loanIdToRepaymentRemainingMonths[_loanId] = _repaymentRemainingMonths;

		uint256 amount = loanIdToAmount[_loanId];
		uint256 repaidAmount = loanIdToRepaymentAmount[_loanId];
		uint256 remainingAmount = amount - repaidAmount;
		// Updated formula: multiply by 100 in denominator to account for basis points
		loanIdToInterestAmount[_loanId] = (remainingAmount * loanIdToInterestRate[_loanId] * _repaymentRemainingMonths) / (12 * 10000);

		emit LoanRepaymentRemainingMonthsUpdated(_loanId, _repaymentRemainingMonths);
    }

    /// @notice Allows a borrower to make a repayment on their loan
    /// @param _loanId Unique identifier for the loan
    function makeRepayment(
        bytes32 _loanId
    ) external whenNotPaused nonReentrant loanExists(_loanId) onlyActiveLoan(_loanId) {
        // Verify the sender is the borrower
        require(msg.sender == loanIdToBorrower[_loanId], "Only borrower can make repayments");

        // Get interest for this payment period from getNextRepayment
        // Note: First return value (remainingTotal) is not used here as we calculate principal separately
        (, uint256 interestForPayment) = getNextRepayment(_loanId);

        // Calculate remaining principal balance (excludes interest)
        uint256 remainingPrincipal = loanIdToAmount[_loanId] - loanIdToRepaymentAmount[_loanId];
        require(remainingPrincipal > 0, "Loan is already fully repaid");

        // Calculate how much principal to pay this period
        // Since this is a single full repayment, we pay all remaining principal
        uint256 principalPayment = remainingPrincipal;
        uint256 totalPayment = principalPayment + interestForPayment;

        require(totalPayment > 0, "Amount must be greater than 0");

        // Update totalLentAmount with only the principal portion (not interest)
        totalLentAmount -= principalPayment;

        // Transfer tokens from sender to pool
        require(token.transferFrom(msg.sender, address(this), totalPayment), "Transfer failed");

        // Update repayment tracking
        loanIdToRepaymentAmount[_loanId] += principalPayment;
        loanIdToInterestRepaymentAmount[_loanId] += interestForPayment;

        // If loan is fully repaid, mark it as inactive
        if (loanIdToRepaymentAmount[_loanId] >= loanIdToAmount[_loanId]) {
            loanIdToActive[_loanId] = false;
        }

        emit LoanRepaymentMade(_loanId, msg.sender, principalPayment, interestForPayment);
    }

    ////////////////////////////////////////////////
    // PROOF VERIFICATION FUNCTIONS
    ////////////////////////////////////////////////

    /// @notice Sets the proof verifier contract address
    /// @param _proofVerifier Address of the ProofVerifier contract
    function setProofVerifier(address _proofVerifier) external onlyOwner {
        address oldVerifier = address(proofVerifier);
        proofVerifier = IProofVerifier(_proofVerifier);
        emit ProofVerifierUpdated(oldVerifier, _proofVerifier);
    }

    /// @notice Creates a loan using verified DSCR from Cartesi proofs
    /// @dev Uses the interest rate determined by verified DSCR calculation
    /// @param _loanId Unique identifier for the loan (must match Cartesi proof)
    /// @param _borrower Address of the borrower
    /// @param _amount Loan amount
    /// @param _repaymentRemainingMonths Number of months for repayment
    function createLoanWithVerifiedDscr(
        bytes32 _loanId,
        address _borrower,
        uint256 _amount,
        uint256 _repaymentRemainingMonths
    ) external whenNotPaused onlySystemOrPoolManager loanNotExists(_loanId) requireVerifiedDscr(_loanId) requireVerifiedBorrower(_borrower) {
        // Get verified DSCR result from proof verifier
        IProofVerifier.DscrResult memory dscrResult = proofVerifier.getVerifiedDscr(_loanId);

        // Use the verified interest rate from Cartesi computation
        uint256 verifiedInterestRate = dscrResult.interestRate;

        // Create the loan with verified parameters
        loanIdToBorrower[_loanId] = _borrower;
        loanIdToAmount[_loanId] = _amount;
        // Calculate interest amount using verified rate
        loanIdToInterestAmount[_loanId] = (_amount * verifiedInterestRate * _repaymentRemainingMonths) / (12 * 10000);
        loanIdToInterestRate[_loanId] = verifiedInterestRate;
        loanIdToRepaymentAmount[_loanId] = 0;
        loanIdToRepaymentRemainingMonths[_loanId] = _repaymentRemainingMonths;

        emit LoanCreatedWithVerifiedDscr(_loanId, _borrower, _amount, dscrResult.dscrValue, verifiedInterestRate);
    }

    /// @notice Checks if a loan has verified DSCR
    /// @param _loanId Unique identifier for the loan
    /// @return Whether the loan has a verified DSCR calculation
    function hasVerifiedDscr(bytes32 _loanId) external view returns (bool) {
        if (address(proofVerifier) == address(0)) {
            return false;
        }
        return proofVerifier.isDscrVerified(_loanId);
    }

    /// @notice Gets the verified DSCR result for a loan
    /// @param _loanId Unique identifier for the loan
    /// @return The verified DSCR result
    function getVerifiedDscrResult(bytes32 _loanId) external view returns (IProofVerifier.DscrResult memory) {
        require(address(proofVerifier) != address(0), "ProofVerifier not set");
        return proofVerifier.getVerifiedDscr(_loanId);
    }

    /// @notice Checks if a borrower has verified identity
    /// @param _borrower Address of the borrower
    /// @return Whether the borrower has verified identity
    function isBorrowerVerified(address _borrower) external view returns (bool) {
        if (address(proofVerifier) == address(0)) {
            return false;
        }
        return proofVerifier.hasVerifiedIdentity(_borrower);
    }

    /// @notice Checks if a borrower has verified transaction data
    /// @param _borrower Address of the borrower
    /// @return Whether the borrower has verified transactions
    function hasBorrowerTransactions(address _borrower) external view returns (bool) {
        if (address(proofVerifier) == address(0)) {
            return false;
        }
        return proofVerifier.hasVerifiedTransactions(_borrower);
    }

    ////////////////////////////////////////////////
    // CARTESI NOTICE HANDLERS (zkFetch + Cartesi)
    ////////////////////////////////////////////////

    /// @notice Sets the relay service address that can submit Cartesi notices
    /// @param _relayService Address of the relay service
    function setRelayService(address _relayService) external onlyOwner {
        address oldRelay = relayService;
        relayService = _relayService;
        emit RelayServiceUpdated(oldRelay, _relayService);
    }

    /// @notice Modifier to restrict functions to the relay service
    modifier onlyRelayService() {
        require(msg.sender == relayService, "Only relay service can call this");
        _;
    }

    /// @notice Handles a notice from Cartesi (via relay service)
    /// @dev This is called by the relay service to process Cartesi outputs
    /// @param noticeType Type of notice (dscr_verified_zkfetch)
    /// @param borrower Address of the borrower
    /// @param data Encoded notice data
    function handleNotice(
        string calldata noticeType,
        address borrower,
        bytes calldata data
    ) external onlyRelayService {
        bytes32 typeHash = keccak256(bytes(noticeType));

        if (typeHash == keccak256("dscr_verified_zkfetch")) {
            _handleDscrVerifiedZkFetch(borrower, data);
        } else {
            revert("Unknown notice type");
        }
    }

    /// @notice Internal handler for dscr_verified_zkfetch notice
    /// @dev Stores verified DSCR result from zkFetch + Cartesi verification
    function _handleDscrVerifiedZkFetch(address borrower, bytes calldata data) internal {
        (bytes32 loanId, uint256 dscrValue, uint256 interestRate, bytes32 proofHash) =
            abi.decode(data, (bytes32, uint256, uint256, bytes32));

        // Store the verified DSCR result
        zkFetchDscrResults[loanId] = ZkFetchDscrResult({
            dscrValue: dscrValue,
            interestRate: interestRate,
            proofHash: proofHash,
            verifiedAt: block.timestamp,
            isValid: true
        });

        // Track latest loan for this borrower
        borrowerLatestLoanId[borrower] = loanId;

        emit DscrVerifiedZkFetch(loanId, borrower, dscrValue, interestRate, proofHash, block.timestamp);
    }

    ////////////////////////////////////////////////
    // ZKFETCH DSCR GETTERS
    ////////////////////////////////////////////////

    /// @notice Checks if a loan has verified DSCR via zkFetch
    /// @param _loanId Unique identifier for the loan
    /// @return Whether the loan has a verified DSCR from zkFetch
    function hasZkFetchVerifiedDscr(bytes32 _loanId) external view returns (bool) {
        return zkFetchDscrResults[_loanId].isValid && zkFetchDscrResults[_loanId].verifiedAt > 0;
    }

    /// @notice Gets the zkFetch verified DSCR result for a loan
    /// @param _loanId Unique identifier for the loan
    /// @return dscrValue The DSCR value (scaled by 1000)
    /// @return interestRate The interest rate in basis points
    /// @return proofHash The hash of the zkFetch proof
    /// @return verifiedAt The timestamp of verification
    function getZkFetchDscrResult(bytes32 _loanId) external view returns (
        uint256 dscrValue,
        uint256 interestRate,
        bytes32 proofHash,
        uint256 verifiedAt
    ) {
        ZkFetchDscrResult memory result = zkFetchDscrResults[_loanId];
        require(result.verifiedAt > 0, "No verified DSCR for this loan");
        return (result.dscrValue, result.interestRate, result.proofHash, result.verifiedAt);
    }

    /// @notice Gets the latest verified loan ID for a borrower
    /// @param _borrower Address of the borrower
    /// @return The latest loan ID with verified DSCR
    function getBorrowerLatestVerifiedLoan(address _borrower) external view returns (bytes32) {
        return borrowerLatestLoanId[_borrower];
    }

    /// @notice Creates a loan using zkFetch verified DSCR from Cartesi
    /// @dev Uses the interest rate from the zkFetch verification
    /// @param _loanId Unique identifier for the loan (must have zkFetch verified DSCR)
    /// @param _borrower Address of the borrower
    /// @param _amount Loan amount
    /// @param _repaymentRemainingMonths Number of months for repayment
    function createLoanWithZkFetchDscr(
        bytes32 _loanId,
        address _borrower,
        uint256 _amount,
        uint256 _repaymentRemainingMonths
    ) external whenNotPaused onlySystemOrPoolManager loanNotExists(_loanId) {
        // Get zkFetch verified DSCR result
        ZkFetchDscrResult memory dscrResult = zkFetchDscrResults[_loanId];
        require(dscrResult.isValid && dscrResult.verifiedAt > 0, "No valid zkFetch DSCR for this loan");

        // Use the verified interest rate from zkFetch/Cartesi
        uint256 verifiedInterestRate = dscrResult.interestRate;

        // Create the loan with verified parameters
        loanIdToBorrower[_loanId] = _borrower;
        loanIdToAmount[_loanId] = _amount;
        // Calculate interest amount using verified rate
        loanIdToInterestAmount[_loanId] = (_amount * verifiedInterestRate * _repaymentRemainingMonths) / (12 * 10000);
        loanIdToInterestRate[_loanId] = verifiedInterestRate;
        loanIdToRepaymentAmount[_loanId] = 0;
        loanIdToRepaymentRemainingMonths[_loanId] = _repaymentRemainingMonths;

        emit LoanCreatedWithVerifiedDscr(_loanId, _borrower, _amount, dscrResult.dscrValue, verifiedInterestRate);
    }

    ////////////////////////////////////////////////
    // EMERGENCY CONTROLS
    ////////////////////////////////////////////////

    /// @notice Pauses all critical contract functions
    /// @dev Only callable by owner in case of emergency
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses all critical contract functions
    /// @dev Only callable by owner after emergency is resolved
    function unpause() external onlyOwner {
        _unpause();
    }

    ////////////////////////////////////////////////
    // UPGRADE
    ////////////////////////////////////////////////
    /// @notice Authorizes an upgrade to a new implementation
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
