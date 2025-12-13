import Decimal from 'decimal.js';
import { AdvanceHandler, InspectHandler, InspectQuery, AdvanceRequestData } from '../router';
import {
  getLoanById,
  updateLoanDscr,
  getBorrowerByAddress,
  getTransactionsForDscr,
  saveDscrCalculation,
  getDscrHistory,
  TransactionRecord,
  createPendingRateChange,
  getPendingRateChanges,
  approveRateChange,
  rejectRateChange,
} from '../db';
import { calculateRequiredInterestRate, Transaction } from '../debt';
import { createHash } from 'crypto';
import { requireRateApproval, getDefaultDscrTarget } from '../config';

/**
 * Payload for calculating DSCR.
 */
interface CalculateDscrPayload {
  action: 'calculate_dscr';
  loan_id: string;
  dscr_target?: number;
  term_months?: number;
}

/**
 * Payload for approving/rejecting rate changes.
 */
interface RateChangeApprovalPayload {
  action: 'approve_rate_change' | 'reject_rate_change';
  change_id: number;
  approved_by: string;
}

/**
 * Convert database transactions to DSCR calculation format.
 */
function convertTransactions(records: TransactionRecord[]): Transaction[] {
  return records.map(tx => ({
    amount: tx.amount,
    date: new Date(tx.date),
  }));
}

/**
 * Create hash of transaction inputs for verification.
 */
function hashTransactionInputs(transactions: Transaction[], loanAmount: number): string {
  const data = JSON.stringify({
    transactions: transactions.map(t => ({ amount: t.amount, date: t.date.toISOString() })),
    loanAmount,
  });
  return createHash('sha256').update(data).digest('hex');
}

/**
 * Calculate monthly payment for a given interest rate.
 */
function calculateMonthlyPayment(
  principal: number,
  annualRate: number,
  termMonths: number
): number {
  if (annualRate === 0) {
    return principal / termMonths;
  }
  const monthlyRate = annualRate / 100 / 12;
  const rateFactorPow = Math.pow(1 + monthlyRate, termMonths);
  return (principal * monthlyRate * rateFactorPow) / (rateFactorPow - 1);
}

/**
 * Handle DSCR calculation request.
 */
export const handleCalculateDscr: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const { loan_id, dscr_target, term_months } = payload as CalculateDscrPayload;

  // Validate loan ID
  if (!loan_id || typeof loan_id !== 'string') {
    throw new Error('Valid loan_id is required');
  }

  const loan = getLoanById(loan_id);
  if (!loan) {
    throw new Error(`Loan not found: ${loan_id}`);
  }

  // Get borrower transactions
  const borrower = getBorrowerByAddress(loan.borrower_address);
  if (!borrower) {
    throw new Error('Borrower not found');
  }

  const transactionRecords = getTransactionsForDscr(borrower.id);
  if (transactionRecords.length === 0) {
    throw new Error('No transactions available for DSCR calculation');
  }

  // Convert to calculation format
  const transactions = convertTransactions(transactionRecords);
  const loanAmount = loan.amount;
  const targetDscr = dscr_target || getDefaultDscrTarget();
  const loanTerm = term_months || loan.term_months || 24;

  // Calculate required interest rate
  const interestRate = calculateRequiredInterestRate(
    transactions,
    loanAmount,
    loanTerm,
    targetDscr
  );

  // Calculate resulting monthly payment and NOI
  const monthlyPayment = calculateMonthlyPayment(loanAmount, interestRate, loanTerm);

  // Calculate average monthly NOI from transactions
  const noiByMonth: Record<string, number> = {};
  for (const tx of transactions) {
    const monthKey = `${tx.date.getFullYear()}-${String(tx.date.getMonth() + 1).padStart(2, '0')}`;
    noiByMonth[monthKey] = (noiByMonth[monthKey] || 0) + tx.amount;
  }

  const months = Object.keys(noiByMonth);
  const totalNoi = Object.values(noiByMonth).reduce((sum, noi) => sum + noi, 0);
  const avgMonthlyNoi = months.length > 0 ? totalNoi / months.length : 0;

  // Calculate actual DSCR
  const actualDscr = monthlyPayment > 0 ? avgMonthlyNoi / monthlyPayment : 0;

  // Create input hash for verification
  const inputHash = hashTransactionInputs(transactions, loanAmount);

  // Save DSCR calculation
  saveDscrCalculation(
    loan_id,
    borrower.id,
    actualDscr,
    avgMonthlyNoi,
    monthlyPayment,
    inputHash
  );

  // Determine if rate change requires approval
  const needsApproval = requireRateApproval();
  const currentRate = loan.interest_rate;
  const rateChanged = currentRate !== interestRate;
  let pendingChangeId: number | null = null;

  if (needsApproval && rateChanged) {
    // Create pending rate change instead of applying immediately
    const pendingChange = createPendingRateChange(
      loan_id,
      currentRate,
      interestRate,
      actualDscr,
      `DSCR calculation: ${actualDscr.toFixed(4)}`,
      'system'
    );
    pendingChangeId = pendingChange.id;

    // Update loan DSCR but keep current rate
    const newStatus = actualDscr >= targetDscr ? 'pending_rate_approval' : 'pending';
    updateLoanDscr(loan_id, currentRate || 0, actualDscr, newStatus);

    console.log(
      `DSCR calculated for loan ${loan_id}: ${actualDscr.toFixed(4)}, rate change pending approval: ${interestRate.toFixed(4)}%`
    );
  } else {
    // Apply rate change immediately (approval not required or rate unchanged)
    const newStatus = actualDscr >= targetDscr ? 'approved' : 'pending';
    updateLoanDscr(loan_id, interestRate, actualDscr, newStatus);

    console.log(
      `DSCR calculated for loan ${loan_id}: ${actualDscr.toFixed(4)}, rate: ${interestRate.toFixed(4)}%`
    );
  }

  return {
    status: 'accept',
    response: {
      action: 'calculate_dscr',
      success: true,
      loan_id,
      dscr: new Decimal(actualDscr).toFixed(4),
      interest_rate: new Decimal(interestRate).toFixed(6),
      monthly_noi: new Decimal(avgMonthlyNoi).toFixed(2),
      monthly_payment: new Decimal(monthlyPayment).toFixed(2),
      target_dscr: targetDscr,
      meets_target: actualDscr >= targetDscr,
      loan_status: needsApproval && rateChanged ? 'pending_rate_approval' : (actualDscr >= targetDscr ? 'approved' : 'pending'),
      transactions_used: transactions.length,
      input_hash: inputHash,
      rate_change_pending: needsApproval && rateChanged,
      pending_change_id: pendingChangeId,
    },
  };
};

/**
 * Handle rate change approval.
 */
export const handleApproveRateChange: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const { change_id, approved_by } = payload as RateChangeApprovalPayload;

  if (!change_id || typeof change_id !== 'number') {
    throw new Error('Valid change_id is required');
  }

  if (!approved_by || typeof approved_by !== 'string') {
    throw new Error('approved_by is required');
  }

  const success = approveRateChange(change_id, approved_by);

  if (!success) {
    throw new Error(`Rate change ${change_id} not found or already resolved`);
  }

  console.log(`Rate change ${change_id} approved by ${approved_by}`);

  return {
    status: 'accept',
    response: {
      action: 'approve_rate_change',
      success: true,
      change_id,
      approved_by,
    },
  };
};

/**
 * Handle rate change rejection.
 */
export const handleRejectRateChange: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const { change_id, approved_by } = payload as RateChangeApprovalPayload;

  if (!change_id || typeof change_id !== 'number') {
    throw new Error('Valid change_id is required');
  }

  if (!approved_by || typeof approved_by !== 'string') {
    throw new Error('approved_by is required');
  }

  const success = rejectRateChange(change_id, approved_by);

  if (!success) {
    throw new Error(`Rate change ${change_id} not found or already resolved`);
  }

  console.log(`Rate change ${change_id} rejected by ${approved_by}`);

  return {
    status: 'accept',
    response: {
      action: 'reject_rate_change',
      success: true,
      change_id,
      rejected_by: approved_by,
    },
  };
};

/**
 * Handle inspect query for DSCR data.
 */
export const handleInspectDscr: InspectHandler = async (query: InspectQuery) => {
  const { params } = query;

  if (!params.loan_id) {
    return { error: 'loan_id parameter required' };
  }

  const loan = getLoanById(params.loan_id);
  if (!loan) {
    return { error: 'Loan not found', loan_id: params.loan_id };
  }

  // Get DSCR history
  const history = getDscrHistory(params.loan_id);

  return {
    loan_id: params.loan_id,
    current_dscr: loan.dscr,
    current_rate: loan.interest_rate,
    loan_status: loan.status,
    calculation_history: history.map(calc => ({
      dscr_value: new Decimal(calc.dscr_value).toFixed(4),
      monthly_noi: calc.monthly_noi ? new Decimal(calc.monthly_noi).toFixed(2) : null,
      monthly_debt_service: calc.monthly_debt_service
        ? new Decimal(calc.monthly_debt_service).toFixed(2)
        : null,
      calculation_date: calc.calculation_date,
      input_hash: calc.input_hash,
    })),
    history_count: history.length,
  };
};

/**
 * Handle inspect query for pending rate changes.
 */
export const handleInspectPendingRateChanges: InspectHandler = async (query: InspectQuery) => {
  const { params } = query;

  // Get pending rate changes, optionally filtered by loan_id
  const pendingChanges = getPendingRateChanges(params.loan_id);

  return {
    pending_rate_changes: pendingChanges.map(change => ({
      id: change.id,
      loan_id: change.loan_id,
      current_rate: change.current_rate ? new Decimal(change.current_rate).toFixed(6) : null,
      proposed_rate: new Decimal(change.proposed_rate).toFixed(6),
      dscr_value: new Decimal(change.dscr_value).toFixed(4),
      reason: change.reason,
      requested_by: change.requested_by,
      created_at: change.created_at,
    })),
    total_pending: pendingChanges.length,
    approval_required: requireRateApproval(),
  };
};
