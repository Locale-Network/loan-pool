import { AdvanceHandler, InspectHandler, InspectQuery, AdvanceRequestData } from '../router';
import {
  insertTransactions,
  getTransactionsByBorrower,
  getBorrowerByAddress,
  createBorrower,
  updatePlaidSyncCursor,
  getPlaidSyncCursor,
  TransactionRecord,
  TransactionInput,
} from '../db';

/**
 * Payload for syncing transactions.
 */
interface SyncTransactionsPayload {
  action: 'sync_transactions';
  borrower_address: string;
  transactions: TransactionInput[];
  cursor_hash?: string;
  loan_id?: string;
}

/**
 * Maximum transactions per sync to prevent spam.
 */
const MAX_TRANSACTIONS_PER_SYNC = 500;

/**
 * Sanitize transaction for public response.
 * Removes potentially sensitive merchant details.
 */
function sanitizeTransaction(tx: TransactionRecord): Partial<TransactionRecord> {
  return {
    id: tx.id,
    amount: tx.amount,
    date: tx.date,
    category: tx.category,
    pending: tx.pending,
    is_income: tx.is_income,
    // Include Plaid personal finance category (useful for DSCR analysis)
    personal_finance_category_primary: tx.personal_finance_category_primary,
    personal_finance_category_detailed: tx.personal_finance_category_detailed,
    category_confidence: tx.category_confidence,
    // Include recurring transaction metadata (useful for income stability analysis)
    is_recurring: tx.is_recurring,
    recurring_frequency: tx.recurring_frequency,
    // merchant_name omitted for privacy
    // plaid_transaction_id omitted for privacy
    // recurring_stream_id omitted for privacy
  };
}

/**
 * Handle transaction sync from Plaid.
 */
export const handleSyncTransactions: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const { borrower_address, transactions, cursor_hash, loan_id } =
    payload as SyncTransactionsPayload;

  // Validate borrower address
  if (!borrower_address || typeof borrower_address !== 'string') {
    throw new Error('Valid borrower_address is required');
  }

  if (!/^0x[a-fA-F0-9]{40}$/.test(borrower_address)) {
    throw new Error('Invalid borrower address format');
  }

  // Validate transactions array
  if (!Array.isArray(transactions)) {
    throw new Error('Transactions must be an array');
  }

  if (transactions.length === 0) {
    throw new Error('At least one transaction is required');
  }

  if (transactions.length > MAX_TRANSACTIONS_PER_SYNC) {
    throw new Error(`Maximum ${MAX_TRANSACTIONS_PER_SYNC} transactions per sync`);
  }

  // Validate each transaction
  const validatedTransactions: TransactionInput[] = [];
  for (let i = 0; i < transactions.length; i++) {
    const tx = transactions[i];

    // Ensure transaction exists (for TypeScript strict mode)
    if (!tx) {
      throw new Error(`Transaction ${i}: missing transaction data`);
    }

    if (typeof tx.amount !== 'number' || !isFinite(tx.amount)) {
      throw new Error(`Transaction ${i}: invalid amount`);
    }

    if (!tx.date || typeof tx.date !== 'string') {
      throw new Error(`Transaction ${i}: date is required`);
    }

    // Validate date format (YYYY-MM-DD)
    if (!/^\d{4}-\d{2}-\d{2}$/.test(tx.date)) {
      throw new Error(`Transaction ${i}: invalid date format (use YYYY-MM-DD)`);
    }

    validatedTransactions.push({
      plaid_transaction_id: tx.plaid_transaction_id,
      amount: tx.amount,
      date: tx.date,
      category: tx.category,
      merchant_name: tx.merchant_name,
      pending: tx.pending || false,
      is_income: tx.is_income || false,
      // Plaid personal finance category
      personal_finance_category_primary: tx.personal_finance_category_primary,
      personal_finance_category_detailed: tx.personal_finance_category_detailed,
      category_confidence: tx.category_confidence,
      // Recurring transaction metadata
      is_recurring: tx.is_recurring || false,
      recurring_stream_id: tx.recurring_stream_id,
      recurring_frequency: tx.recurring_frequency,
      recurring_is_active: tx.recurring_is_active,
    });
  }

  // Get or create borrower
  let borrower = getBorrowerByAddress(borrower_address);
  if (!borrower) {
    borrower = createBorrower(borrower_address);
  }

  // Insert transactions
  const insertedCount = insertTransactions(
    borrower.id,
    validatedTransactions.map(tx => ({
      ...tx,
      loan_id,
    }))
  );

  // Update sync cursor if provided
  if (cursor_hash) {
    updatePlaidSyncCursor(borrower.id, cursor_hash);
  }

  console.log(`Synced ${insertedCount} transactions for ${borrower_address}`);

  return {
    status: 'accept',
    response: {
      action: 'sync_transactions',
      success: true,
      borrower_address,
      transactions_synced: insertedCount,
      cursor_updated: !!cursor_hash,
    },
  };
};

/**
 * Handle inspect query for transaction data.
 */
export const handleInspectTransactions: InspectHandler = async (query: InspectQuery) => {
  const { params } = query;

  if (!params.borrower) {
    return { error: 'Borrower address required' };
  }

  const borrower = getBorrowerByAddress(params.borrower);
  if (!borrower) {
    return { error: 'Borrower not found', address: params.borrower };
  }

  // Get transactions with optional date filters
  const transactions = getTransactionsByBorrower(
    borrower.id,
    params.start_date,
    params.end_date
  );

  // Get current sync cursor
  const cursor = getPlaidSyncCursor(borrower.id);

  return {
    borrower_address: params.borrower,
    transaction_count: transactions.length,
    // Return sanitized transactions (no merchant names or plaid IDs)
    transactions: transactions.slice(0, 100).map(sanitizeTransaction), // Limit to 100 for response size
    has_more: transactions.length > 100,
    sync_cursor_exists: !!cursor,
  };
};
