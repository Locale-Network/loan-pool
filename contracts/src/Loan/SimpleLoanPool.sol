// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/// @title SimpleLoanPool
/// @notice A contract for managing simple loans with interest
/// @dev Implements upgradeable pattern with access control
contract SimpleLoanPool is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
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

    ////////////////////////////////////////////////
    // STATE
    ////////////////////////////////////////////////
    ERC20Upgradeable public token;

    mapping(bytes32 => bool) public loanIdToActive;
    mapping(bytes32 => address) public loanIdToBorrower;
    mapping(bytes32 => uint256) public loanIdToAmount;
    mapping(bytes32 => uint256) public loanIdToInterestRate;
    mapping(bytes32 => uint256) public loanIdToRepaymentAmount;
    mapping(bytes32 => uint256) public loanIdToRepaymentRemainingMonths;

    mapping(address => uint256) public loanAmounts;

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
    ) external onlySystemOrPoolManager loanNotExists(_loanId) {
        loanIdToBorrower[_loanId] = _borrower;
        loanIdToAmount[_loanId] = _amount;
        loanIdToInterestRate[_loanId] = _interestRate;
		loanIdToRepaymentAmount[_loanId] = 0;
        loanIdToRepaymentRemainingMonths[_loanId] = _repaymentRemainingMonths;
    }

	/// @notice Activates a created loan and transfers funds to borrower
	/// @param _loanId Unique identifier for the loan
	function activateLoan(bytes32 _loanId) external onlySystemOrPoolManager loanExists(_loanId) onlyInactiveLoan(_loanId) {
		loanIdToActive[_loanId] = true;

		uint256 amount = loanIdToAmount[_loanId];
		token.transfer(loanIdToBorrower[_loanId], amount);
	}

	/// @notice Calculates the next repayment amount for a loan
	/// @param _loanId Unique identifier for the loan
	/// @return The calculated repayment amount
	function getNextRepayment(bytes32 _loanId) external view returns (uint256) {
		uint256 amount = loanIdToAmount[_loanId];
		uint256 repaidAmount = loanIdToRepaymentAmount[_loanId];
		uint256 remainingAmount = amount - repaidAmount;
		uint256 interestRate = loanIdToInterestRate[_loanId];
		uint256 repaymentRemainingMonths = loanIdToRepaymentRemainingMonths[_loanId];

		return remainingAmount + (remainingAmount * interestRate / 100) / repaymentRemainingMonths;
	}

    /// @notice Updates the interest rate for an active loan
    /// @param _loanId Unique identifier for the loan
    /// @param _interestRate New interest rate to set
    function updateLoanInterestRate(
        bytes32 _loanId,
        uint256 _interestRate
    ) external onlySystemOrPoolManager loanExists(_loanId) onlyActiveLoan(_loanId) {
        loanIdToInterestRate[_loanId] = _interestRate;
    }

    /// @notice Updates the remaining months for loan repayment
    /// @param _loanId Unique identifier for the loan
    /// @param _repaymentRemainingMonths New number of remaining months
    function updateLoanRepaymentRemainingMonths(
        bytes32 _loanId,
        uint256 _repaymentRemainingMonths
    ) external onlySystemOrPoolManager loanExists(_loanId) onlyActiveLoan(_loanId) {
        loanIdToRepaymentRemainingMonths[_loanId] = _repaymentRemainingMonths;
    }

    /// @notice Allows a borrower to make a repayment on their loan
    /// @param _loanId Unique identifier for the loan
    /// @param _amount Amount to repay
    function makeRepayment(
        bytes32 _loanId,
        uint256 _amount
    ) external loanExists(_loanId) onlyActiveLoan(_loanId) {
        // Verify the sender is the borrower
        require(msg.sender == loanIdToBorrower[_loanId], "Only borrower can make repayments");
        
        // Calculate remaining loan balance
        uint256 currentBalance = loanIdToAmount[_loanId] - loanIdToRepaymentAmount[_loanId];
        require(currentBalance > 0, "Loan is already fully repaid");
        require(_amount > 0, "Amount must be greater than 0");
        
        // Transfer tokens from sender to pool
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        // Update repayment amount
        loanIdToRepaymentAmount[_loanId] += _amount;
        
        // If loan is fully repaid, mark it as inactive
        if (loanIdToRepaymentAmount[_loanId] >= loanIdToAmount[_loanId]) {
            loanIdToActive[_loanId] = false;
        }
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
