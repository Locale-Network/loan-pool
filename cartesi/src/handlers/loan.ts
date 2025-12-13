import { AdvanceHandler, InspectHandler, InspectQuery, AdvanceRequestData } from '../router';
import {
  createLoan,
  getLoanById,
  getLoansByBorrower,
  updateLoanStatus,
  updateLoanDscr,
  getBorrowerByAddress,
  createBorrower,
  Loan,
} from '../db';

export const MAX_LOAN_AMOUNT = BigInt('1000000000000000000'); // 1 quintillion (1e18)
export const MIN_LOAN_AMOUNT = BigInt(1);

/**
 * Payload for creating a loan.
 */
interface CreateLoanPayload {
  action: 'create_loan';
  loan_id: string;
  borrower_address: string;
  amount: string | number;
  term_months?: number;
}

/**
 * Payload for updating loan status.
 */
interface UpdateLoanStatusPayload {
  action: 'update_loan_status';
  loan_id: string;
  status: string;
}

/**
 * Valid loan statuses.
 */
const VALID_STATUSES = ['pending', 'approved', 'rejected', 'active', 'completed', 'defaulted', 'disbursed'];

/**
 * Payload for approving a loan.
 */
interface ApproveLoanPayload {
  action: 'approve_loan';
  loan_id: string;
  approved_by?: string;
  approved_at?: number;
}

/**
 * Payload for disbursing a loan.
 */
interface DisburseLoanPayload {
  action: 'disburse_loan';
  loan_id: string;
  disbursed_at?: number;
  amount?: string;
  borrower_address?: string;
}

/**
 * Handle loan creation.
 */
export const handleCreateLoan: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const { loan_id, borrower_address, amount, term_months } = payload as CreateLoanPayload;

  // Validate loan ID
  if (!loan_id || typeof loan_id !== 'string') {
    throw new Error('Valid loan_id is required');
  }

  // Validate borrower address
  if (!borrower_address || typeof borrower_address !== 'string') {
    throw new Error('Valid borrower_address is required');
  }

  if (!/^0x[a-fA-F0-9]{40}$/.test(borrower_address)) {
    throw new Error('Invalid borrower address format');
  }

  // Validate amount
  if (!amount) {
    throw new Error('Loan amount is required');
  }

  let loanAmountBigInt: bigint;
  try {
    loanAmountBigInt = BigInt(amount);
  } catch (e) {
    throw new Error('Invalid loan amount format');
  }

  if (loanAmountBigInt <= MIN_LOAN_AMOUNT) {
    throw new Error('Loan amount must be greater than 0');
  }
  if (loanAmountBigInt >= MAX_LOAN_AMOUNT) {
    throw new Error(`Loan amount exceeds maximum allowed (${MAX_LOAN_AMOUNT})`);
  }

  // Validate term
  const termMonths = term_months || 24;
  if (termMonths < 1 || termMonths > 360) {
    throw new Error('Term must be between 1 and 360 months');
  }

  // Check if loan already exists
  const existingLoan = getLoanById(loan_id);
  if (existingLoan) {
    throw new Error(`Loan with ID ${loan_id} already exists`);
  }

  // Get or create borrower
  let borrower = getBorrowerByAddress(borrower_address);
  if (!borrower) {
    borrower = createBorrower(borrower_address);
  }

  // Create loan
  const loan = createLoan(
    loan_id,
    borrower.id,
    borrower_address,
    Number(loanAmountBigInt),
    termMonths
  );

  console.log(`Loan created: ${loan_id} for ${borrower_address}`);

  return {
    status: 'accept',
    response: {
      action: 'create_loan',
      success: true,
      loan: {
        id: loan.id,
        borrower_address: loan.borrower_address,
        amount: loan.amount.toString(),
        term_months: loan.term_months,
        status: loan.status,
        created_at: loan.created_at,
      },
    },
  };
};

/**
 * Handle loan status update.
 */
export const handleUpdateLoanStatus: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const { loan_id, status } = payload as UpdateLoanStatusPayload;

  if (!loan_id || typeof loan_id !== 'string') {
    throw new Error('Valid loan_id is required');
  }

  if (!status || !VALID_STATUSES.includes(status)) {
    throw new Error(`Valid status required. Must be one of: ${VALID_STATUSES.join(', ')}`);
  }

  const loan = getLoanById(loan_id);
  if (!loan) {
    throw new Error(`Loan not found: ${loan_id}`);
  }

  updateLoanStatus(loan_id, status);

  console.log(`Loan ${loan_id} status updated to ${status}`);

  return {
    status: 'accept',
    response: {
      action: 'update_loan_status',
      success: true,
      loan_id,
      status,
    },
  };
};

/**
 * Handle inspect query for loan data.
 */
export const handleInspectLoan: InspectHandler = async (query: InspectQuery) => {
  const { params } = query;

  // Get loan by ID
  if (params.id) {
    const loan = getLoanById(params.id);
    if (!loan) {
      return { error: 'Loan not found', id: params.id };
    }
    return {
      loan: {
        id: loan.id,
        borrower_address: loan.borrower_address,
        amount: loan.amount.toString(),
        interest_rate: loan.interest_rate,
        term_months: loan.term_months,
        status: loan.status,
        dscr: loan.dscr,
        created_at: loan.created_at,
        updated_at: loan.updated_at,
      },
    };
  }

  // Get loans by borrower address
  if (params.borrower) {
    const borrower = getBorrowerByAddress(params.borrower);
    if (!borrower) {
      return { error: 'Borrower not found', address: params.borrower };
    }

    const loans = getLoansByBorrower(borrower.id);
    return {
      borrower_address: params.borrower,
      loans: loans.map(loan => ({
        id: loan.id,
        amount: loan.amount.toString(),
        interest_rate: loan.interest_rate,
        term_months: loan.term_months,
        status: loan.status,
        dscr: loan.dscr,
        created_at: loan.created_at,
      })),
    };
  }

  return { error: 'Loan ID or borrower address required' };
};

/**
 * Handle loan approval.
 * Updates loan status to 'approved' with approval metadata.
 */
export const handleApproveLoan: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const { loan_id, approved_by, approved_at } = payload as ApproveLoanPayload;

  if (!loan_id || typeof loan_id !== 'string') {
    throw new Error('Valid loan_id is required');
  }

  const loan = getLoanById(loan_id);
  if (!loan) {
    throw new Error(`Loan not found: ${loan_id}`);
  }

  // Only pending loans can be approved
  if (loan.status !== 'pending') {
    throw new Error(`Cannot approve loan with status: ${loan.status}. Must be pending.`);
  }

  updateLoanStatus(loan_id, 'approved');

  console.log(`Loan ${loan_id} approved by ${approved_by || 'admin'} at ${approved_at || Date.now()}`);

  return {
    status: 'accept',
    response: {
      action: 'approve_loan',
      success: true,
      loan_id,
      approved_by: approved_by || 'admin',
      approved_at: approved_at || Math.floor(Date.now() / 1000),
    },
  };
};

/**
 * Handle loan disbursement.
 * Updates loan status to 'disbursed' after on-chain fund transfer.
 */
export const handleDisburseLoan: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const { loan_id, disbursed_at, amount, borrower_address } = payload as DisburseLoanPayload;

  if (!loan_id || typeof loan_id !== 'string') {
    throw new Error('Valid loan_id is required');
  }

  const loan = getLoanById(loan_id);
  if (!loan) {
    throw new Error(`Loan not found: ${loan_id}`);
  }

  // Only approved loans can be disbursed
  if (loan.status !== 'approved') {
    throw new Error(`Cannot disburse loan with status: ${loan.status}. Must be approved.`);
  }

  updateLoanStatus(loan_id, 'disbursed');

  console.log(`Loan ${loan_id} disbursed: amount=${amount || loan.amount}, borrower=${borrower_address || loan.borrower_address}`);

  return {
    status: 'accept',
    response: {
      action: 'disburse_loan',
      success: true,
      loan_id,
      disbursed_at: disbursed_at || Math.floor(Date.now() / 1000),
      amount: amount || loan.amount.toString(),
      borrower_address: borrower_address || loan.borrower_address,
    },
  };
};
