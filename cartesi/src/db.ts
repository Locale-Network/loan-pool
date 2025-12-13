import initSqlJs, { Database, QueryExecResult } from 'sql.js';

let db: Database | null = null;

// Helper types for sql.js result rows
type SqlValue = string | number | Uint8Array | null;
type SqlRow = SqlValue[];

/**
 * Helper to safely get the first result set from a query
 */
function getFirstResult(result: QueryExecResult[]): QueryExecResult | undefined {
  return result[0];
}

/**
 * Helper to safely get rows from a result set
 */
function getRows(result: QueryExecResult | undefined): SqlRow[] {
  return result?.values ?? [];
}

/**
 * Helper to safely get the first row from a result set
 */
function getFirstRow(result: QueryExecResult | undefined): SqlRow | undefined {
  return result?.values[0];
}

/**
 * Helper to safely get a scalar value from a query result
 */
function getScalar<T>(result: QueryExecResult[], defaultValue: T): T {
  const firstResult = getFirstResult(result);
  const firstRow = getFirstRow(firstResult);
  if (firstRow && firstRow[0] !== undefined && firstRow[0] !== null) {
    return firstRow[0] as T;
  }
  return defaultValue;
}

/**
 * Initialize the SQLite database with schema.
 * Uses sql.js (SQLite compiled to WebAssembly) for deterministic in-rollup persistence.
 */
export async function initDatabase(): Promise<Database> {
  if (db) {
    return db;
  }

  const SQL = await initSqlJs();
  db = new SQL.Database();

  // Create schema
  db.run(`
    -- Borrowers table: stores wallet addresses and KYC status
    CREATE TABLE IF NOT EXISTS borrowers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      wallet_address TEXT UNIQUE NOT NULL,
      plaid_item_hash TEXT,
      kyc_level INTEGER DEFAULT 0,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    );

    -- Loans table: stores loan applications and their status
    CREATE TABLE IF NOT EXISTS loans (
      id TEXT PRIMARY KEY,
      borrower_id INTEGER NOT NULL,
      borrower_address TEXT NOT NULL,
      amount INTEGER NOT NULL,
      interest_rate REAL,
      term_months INTEGER DEFAULT 24,
      status TEXT DEFAULT 'pending',
      dscr REAL,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (borrower_id) REFERENCES borrowers(id)
    );

    -- Transactions table: stores Plaid transaction data for DSCR calculations
    CREATE TABLE IF NOT EXISTS transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      borrower_id INTEGER NOT NULL,
      loan_id TEXT,
      plaid_transaction_id TEXT UNIQUE,
      amount INTEGER NOT NULL,
      date TEXT NOT NULL,
      category TEXT,
      merchant_name TEXT,
      pending INTEGER DEFAULT 0,
      is_income INTEGER DEFAULT 0,
      -- Plaid personal finance category (detailed categorization)
      personal_finance_category_primary TEXT,
      personal_finance_category_detailed TEXT,
      -- Confidence level for category assignment (HIGH, MEDIUM, LOW, UNKNOWN)
      category_confidence TEXT,
      -- Recurring transaction metadata
      is_recurring INTEGER DEFAULT 0,
      recurring_stream_id TEXT,
      recurring_frequency TEXT,
      recurring_is_active INTEGER,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (borrower_id) REFERENCES borrowers(id),
      FOREIGN KEY (loan_id) REFERENCES loans(id)
    );

    -- DSCR calculations table: stores historical DSCR calculations
    CREATE TABLE IF NOT EXISTS dscr_calculations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      loan_id TEXT NOT NULL,
      borrower_id INTEGER NOT NULL,
      dscr_value REAL NOT NULL,
      monthly_noi REAL,
      monthly_debt_service REAL,
      calculation_date TEXT DEFAULT CURRENT_TIMESTAMP,
      input_hash TEXT,
      FOREIGN KEY (loan_id) REFERENCES loans(id),
      FOREIGN KEY (borrower_id) REFERENCES borrowers(id)
    );

    -- Plaid sync state: tracks incremental transaction sync
    CREATE TABLE IF NOT EXISTS plaid_sync_state (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      borrower_id INTEGER UNIQUE NOT NULL,
      cursor_hash TEXT,
      last_sync_at TEXT DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (borrower_id) REFERENCES borrowers(id)
    );

    -- Pending rate changes table: stores interest rate changes awaiting approval
    CREATE TABLE IF NOT EXISTS pending_rate_changes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      loan_id TEXT NOT NULL,
      current_rate REAL,
      proposed_rate REAL NOT NULL,
      dscr_value REAL NOT NULL,
      reason TEXT,
      status TEXT DEFAULT 'pending',
      requested_by TEXT,
      approved_by TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      resolved_at TEXT,
      FOREIGN KEY (loan_id) REFERENCES loans(id)
    );

    -- Data proofs table: stores verified zkProofs from Plaid data
    CREATE TABLE IF NOT EXISTS data_proofs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      proof_id TEXT UNIQUE NOT NULL,
      proof_type TEXT NOT NULL,
      borrower_id INTEGER NOT NULL,
      loan_id TEXT,
      data_hash TEXT NOT NULL,
      signature TEXT NOT NULL,
      -- Transaction summary data (for transaction proofs)
      transaction_count INTEGER,
      window_start TEXT,
      window_end TEXT,
      net_income REAL,
      avg_monthly_income REAL,
      -- Identity verification data (for identity proofs)
      kyc_level INTEGER,
      verification_status TEXT,
      -- Proof metadata
      verified INTEGER DEFAULT 0,
      verified_at TEXT,
      expires_at TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (borrower_id) REFERENCES borrowers(id),
      FOREIGN KEY (loan_id) REFERENCES loans(id)
    );

    -- Link DSCR calculations to their data proofs
    ALTER TABLE dscr_calculations ADD COLUMN data_proof_id INTEGER REFERENCES data_proofs(id);
    ALTER TABLE dscr_calculations ADD COLUMN proof_verified INTEGER DEFAULT 0;

    -- Create indexes for common queries
    CREATE INDEX IF NOT EXISTS idx_loans_borrower_id ON loans(borrower_id);
    CREATE INDEX IF NOT EXISTS idx_loans_status ON loans(status);
    CREATE INDEX IF NOT EXISTS idx_transactions_borrower_id ON transactions(borrower_id);
    CREATE INDEX IF NOT EXISTS idx_transactions_loan_id ON transactions(loan_id);
    CREATE INDEX IF NOT EXISTS idx_transactions_date ON transactions(date);
    CREATE INDEX IF NOT EXISTS idx_dscr_loan_id ON dscr_calculations(loan_id);
    CREATE INDEX IF NOT EXISTS idx_pending_rate_loan_id ON pending_rate_changes(loan_id);
    CREATE INDEX IF NOT EXISTS idx_pending_rate_status ON pending_rate_changes(status);
    CREATE INDEX IF NOT EXISTS idx_data_proofs_borrower ON data_proofs(borrower_id);
    CREATE INDEX IF NOT EXISTS idx_data_proofs_loan ON data_proofs(loan_id);
    CREATE INDEX IF NOT EXISTS idx_data_proofs_type ON data_proofs(proof_type);
  `);

  console.log('Database initialized successfully');
  return db;
}

/**
 * Get the database instance. Throws if not initialized.
 */
export function getDatabase(): Database {
  if (!db) {
    throw new Error('Database not initialized. Call initDatabase() first.');
  }
  return db;
}

/**
 * Close the database connection (for cleanup/testing).
 */
export function closeDatabase(): void {
  if (db) {
    db.close();
    db = null;
  }
}

/**
 * Export database as binary for state persistence/debugging.
 */
export function exportDatabase(): Uint8Array {
  if (!db) {
    throw new Error('Database not initialized');
  }
  return db.export();
}

/**
 * Import database from binary (for state restoration).
 */
export async function importDatabase(data: Uint8Array): Promise<Database> {
  const SQL = await initSqlJs();
  db = new SQL.Database(data);
  return db;
}

// ============= Borrower Operations =============

export interface Borrower {
  id: number;
  wallet_address: string;
  plaid_item_hash: string | null;
  kyc_level: number;
  created_at: string;
  updated_at: string;
}

export function createBorrower(walletAddress: string, plaidItemHash?: string): Borrower {
  const database = getDatabase();
  const now = new Date().toISOString();

  database.run(
    `INSERT INTO borrowers (wallet_address, plaid_item_hash, created_at, updated_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(wallet_address) DO UPDATE SET
       plaid_item_hash = COALESCE(excluded.plaid_item_hash, plaid_item_hash),
       updated_at = excluded.updated_at`,
    [walletAddress.toLowerCase(), plaidItemHash || null, now, now]
  );

  return getBorrowerByAddress(walletAddress)!;
}

export function getBorrowerByAddress(walletAddress: string): Borrower | null {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, wallet_address, plaid_item_hash, kyc_level, created_at, updated_at
     FROM borrowers WHERE wallet_address = ?`,
    [walletAddress.toLowerCase()]
  );

  const row = getFirstRow(getFirstResult(result));
  if (!row) {
    return null;
  }

  return {
    id: row[0] as number,
    wallet_address: row[1] as string,
    plaid_item_hash: row[2] as string | null,
    kyc_level: row[3] as number,
    created_at: row[4] as string,
    updated_at: row[5] as string,
  };
}

export function getBorrowerById(id: number): Borrower | null {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, wallet_address, plaid_item_hash, kyc_level, created_at, updated_at
     FROM borrowers WHERE id = ?`,
    [id]
  );

  const row = getFirstRow(getFirstResult(result));
  if (!row) {
    return null;
  }

  return {
    id: row[0] as number,
    wallet_address: row[1] as string,
    plaid_item_hash: row[2] as string | null,
    kyc_level: row[3] as number,
    created_at: row[4] as string,
    updated_at: row[5] as string,
  };
}

export function updateBorrowerKycLevel(walletAddress: string, kycLevel: number): void {
  const database = getDatabase();
  database.run(
    `UPDATE borrowers SET kyc_level = ?, updated_at = ? WHERE wallet_address = ?`,
    [kycLevel, new Date().toISOString(), walletAddress.toLowerCase()]
  );
}

// ============= Loan Operations =============

export interface Loan {
  id: string;
  borrower_id: number;
  borrower_address: string;
  amount: number;
  interest_rate: number | null;
  term_months: number;
  status: string;
  dscr: number | null;
  created_at: string;
  updated_at: string;
}

export function createLoan(
  loanId: string,
  borrowerId: number,
  borrowerAddress: string,
  amount: number,
  termMonths: number = 24
): Loan {
  const database = getDatabase();
  const now = new Date().toISOString();

  database.run(
    `INSERT INTO loans (id, borrower_id, borrower_address, amount, term_months, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [loanId, borrowerId, borrowerAddress.toLowerCase(), amount, termMonths, now, now]
  );

  return getLoanById(loanId)!;
}

export function getLoanById(loanId: string): Loan | null {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, borrower_id, borrower_address, amount, interest_rate, term_months, status, dscr, created_at, updated_at
     FROM loans WHERE id = ?`,
    [loanId]
  );

  const firstResult = result[0];
  if (!firstResult || firstResult.values.length === 0) {
    return null;
  }

  const row = firstResult.values[0];
  if (!row) {
    return null;
  }

  return {
    id: row[0] as string,
    borrower_id: row[1] as number,
    borrower_address: row[2] as string,
    amount: row[3] as number,
    interest_rate: row[4] as number | null,
    term_months: row[5] as number,
    status: row[6] as string,
    dscr: row[7] as number | null,
    created_at: row[8] as string,
    updated_at: row[9] as string,
  };
}

export function getLoansByBorrower(borrowerId: number): Loan[] {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, borrower_id, borrower_address, amount, interest_rate, term_months, status, dscr, created_at, updated_at
     FROM loans WHERE borrower_id = ? ORDER BY created_at DESC`,
    [borrowerId]
  );

  const firstResult = result[0];
  if (!firstResult) {
    return [];
  }

  return firstResult.values.map((row: unknown[]) => ({
    id: row[0] as string,
    borrower_id: row[1] as number,
    borrower_address: row[2] as string,
    amount: row[3] as number,
    interest_rate: row[4] as number | null,
    term_months: row[5] as number,
    status: row[6] as string,
    dscr: row[7] as number | null,
    created_at: row[8] as string,
    updated_at: row[9] as string,
  }));
}

export function updateLoanStatus(loanId: string, status: string): void {
  const database = getDatabase();
  database.run(`UPDATE loans SET status = ?, updated_at = ? WHERE id = ?`, [
    status,
    new Date().toISOString(),
    loanId,
  ]);
}

export function updateLoanDscr(
  loanId: string,
  interestRate: number,
  dscr: number,
  status: string
): void {
  const database = getDatabase();
  database.run(
    `UPDATE loans SET interest_rate = ?, dscr = ?, status = ?, updated_at = ? WHERE id = ?`,
    [interestRate, dscr, status, new Date().toISOString(), loanId]
  );
}

// ============= Transaction Operations =============

export interface TransactionRecord {
  id: number;
  borrower_id: number;
  loan_id: string | null;
  plaid_transaction_id: string | null;
  amount: number;
  date: string;
  category: string | null;
  merchant_name: string | null;
  pending: boolean;
  is_income: boolean;
  // Plaid personal finance category
  personal_finance_category_primary: string | null;
  personal_finance_category_detailed: string | null;
  category_confidence: string | null;
  // Recurring transaction metadata
  is_recurring: boolean;
  recurring_stream_id: string | null;
  recurring_frequency: string | null;
  recurring_is_active: boolean | null;
  created_at: string;
}

export interface TransactionInput {
  plaid_transaction_id?: string;
  amount: number;
  date: string;
  category?: string;
  merchant_name?: string;
  pending?: boolean;
  is_income?: boolean;
  loan_id?: string;
  // Plaid personal finance category
  personal_finance_category_primary?: string;
  personal_finance_category_detailed?: string;
  category_confidence?: string;
  // Recurring transaction metadata
  is_recurring?: boolean;
  recurring_stream_id?: string;
  recurring_frequency?: string;
  recurring_is_active?: boolean;
}

export function insertTransactions(
  borrowerId: number,
  transactions: TransactionInput[]
): number {
  const database = getDatabase();
  const now = new Date().toISOString();
  let insertedCount = 0;

  for (const tx of transactions) {
    try {
      database.run(
        `INSERT INTO transactions
         (borrower_id, loan_id, plaid_transaction_id, amount, date, category, merchant_name, pending, is_income,
          personal_finance_category_primary, personal_finance_category_detailed, category_confidence,
          is_recurring, recurring_stream_id, recurring_frequency, recurring_is_active, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(plaid_transaction_id) DO UPDATE SET
           amount = excluded.amount,
           pending = excluded.pending,
           personal_finance_category_primary = excluded.personal_finance_category_primary,
           personal_finance_category_detailed = excluded.personal_finance_category_detailed,
           category_confidence = excluded.category_confidence,
           is_recurring = excluded.is_recurring,
           recurring_stream_id = excluded.recurring_stream_id,
           recurring_frequency = excluded.recurring_frequency,
           recurring_is_active = excluded.recurring_is_active`,
        [
          borrowerId,
          tx.loan_id || null,
          tx.plaid_transaction_id || null,
          tx.amount,
          tx.date,
          tx.category || null,
          tx.merchant_name || null,
          tx.pending ? 1 : 0,
          tx.is_income ? 1 : 0,
          tx.personal_finance_category_primary || null,
          tx.personal_finance_category_detailed || null,
          tx.category_confidence || null,
          tx.is_recurring ? 1 : 0,
          tx.recurring_stream_id || null,
          tx.recurring_frequency || null,
          tx.recurring_is_active === undefined ? null : (tx.recurring_is_active ? 1 : 0),
          now,
        ]
      );
      insertedCount++;
    } catch (error) {
      console.error(`Failed to insert transaction: ${error}`);
    }
  }

  return insertedCount;
}

export function getTransactionsByBorrower(
  borrowerId: number,
  startDate?: string,
  endDate?: string
): TransactionRecord[] {
  const database = getDatabase();

  let query = `SELECT id, borrower_id, loan_id, plaid_transaction_id, amount, date, category, merchant_name,
               pending, is_income, personal_finance_category_primary, personal_finance_category_detailed,
               category_confidence, is_recurring, recurring_stream_id, recurring_frequency, recurring_is_active, created_at
               FROM transactions WHERE borrower_id = ?`;
  const params: (number | string)[] = [borrowerId];

  if (startDate) {
    query += ' AND date >= ?';
    params.push(startDate);
  }
  if (endDate) {
    query += ' AND date <= ?';
    params.push(endDate);
  }

  query += ' ORDER BY date DESC';

  const result = database.exec(query, params);

  const firstResult = result[0];
  if (!firstResult) {
    return [];
  }

  return firstResult.values.map((row: unknown[]) => ({
    id: row[0] as number,
    borrower_id: row[1] as number,
    loan_id: row[2] as string | null,
    plaid_transaction_id: row[3] as string | null,
    amount: row[4] as number,
    date: row[5] as string,
    category: row[6] as string | null,
    merchant_name: row[7] as string | null,
    pending: Boolean(row[8]),
    is_income: Boolean(row[9]),
    personal_finance_category_primary: row[10] as string | null,
    personal_finance_category_detailed: row[11] as string | null,
    category_confidence: row[12] as string | null,
    is_recurring: Boolean(row[13]),
    recurring_stream_id: row[14] as string | null,
    recurring_frequency: row[15] as string | null,
    recurring_is_active: row[16] === null ? null : Boolean(row[16]),
    created_at: row[17] as string,
  }));
}

export function getTransactionsForDscr(borrowerId: number, monthsBack: number = 12): TransactionRecord[] {
  const database = getDatabase();
  const startDate = new Date();
  startDate.setMonth(startDate.getMonth() - monthsBack);

  const dateStr = startDate.toISOString().split('T')[0] ?? '';
  const result = database.exec(
    `SELECT id, borrower_id, loan_id, plaid_transaction_id, amount, date, category, merchant_name,
     pending, is_income, personal_finance_category_primary, personal_finance_category_detailed,
     category_confidence, is_recurring, recurring_stream_id, recurring_frequency, recurring_is_active, created_at
     FROM transactions
     WHERE borrower_id = ? AND date >= ? AND pending = 0
     ORDER BY date ASC`,
    [borrowerId, dateStr]
  );

  const firstResult = result[0];
  if (!firstResult) {
    return [];
  }

  return firstResult.values.map((row: unknown[]) => ({
    id: row[0] as number,
    borrower_id: row[1] as number,
    loan_id: row[2] as string | null,
    plaid_transaction_id: row[3] as string | null,
    amount: row[4] as number,
    date: row[5] as string,
    category: row[6] as string | null,
    merchant_name: row[7] as string | null,
    pending: Boolean(row[8]),
    is_income: Boolean(row[9]),
    personal_finance_category_primary: row[10] as string | null,
    personal_finance_category_detailed: row[11] as string | null,
    category_confidence: row[12] as string | null,
    is_recurring: Boolean(row[13]),
    recurring_stream_id: row[14] as string | null,
    recurring_frequency: row[15] as string | null,
    recurring_is_active: row[16] === null ? null : Boolean(row[16]),
    created_at: row[17] as string,
  }));
}

// ============= DSCR Calculation Operations =============

export interface DscrCalculation {
  id: number;
  loan_id: string;
  borrower_id: number;
  dscr_value: number;
  monthly_noi: number | null;
  monthly_debt_service: number | null;
  calculation_date: string;
  input_hash: string | null;
}

export function saveDscrCalculation(
  loanId: string,
  borrowerId: number,
  dscrValue: number,
  monthlyNoi?: number,
  monthlyDebtService?: number,
  inputHash?: string
): DscrCalculation {
  const database = getDatabase();
  const now = new Date().toISOString();

  database.run(
    `INSERT INTO dscr_calculations (loan_id, borrower_id, dscr_value, monthly_noi, monthly_debt_service, calculation_date, input_hash)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [loanId, borrowerId, dscrValue, monthlyNoi || null, monthlyDebtService || null, now, inputHash || null]
  );

  const result = database.exec('SELECT last_insert_rowid()');
  const firstResult = result[0];
  const firstRow = firstResult?.values[0];
  const id = (firstRow?.[0] as number) ?? 0;

  return {
    id,
    loan_id: loanId,
    borrower_id: borrowerId,
    dscr_value: dscrValue,
    monthly_noi: monthlyNoi || null,
    monthly_debt_service: monthlyDebtService || null,
    calculation_date: now,
    input_hash: inputHash || null,
  };
}

export function getDscrHistory(loanId: string): DscrCalculation[] {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, loan_id, borrower_id, dscr_value, monthly_noi, monthly_debt_service, calculation_date, input_hash
     FROM dscr_calculations WHERE loan_id = ? ORDER BY calculation_date DESC`,
    [loanId]
  );

  const firstResult = result[0];
  if (!firstResult) {
    return [];
  }

  return firstResult.values.map((row: unknown[]) => ({
    id: row[0] as number,
    loan_id: row[1] as string,
    borrower_id: row[2] as number,
    dscr_value: row[3] as number,
    monthly_noi: row[4] as number | null,
    monthly_debt_service: row[5] as number | null,
    calculation_date: row[6] as string,
    input_hash: row[7] as string | null,
  }));
}

// ============= Plaid Sync State Operations =============

export function updatePlaidSyncCursor(borrowerId: number, cursorHash: string): void {
  const database = getDatabase();
  const now = new Date().toISOString();

  database.run(
    `INSERT INTO plaid_sync_state (borrower_id, cursor_hash, last_sync_at)
     VALUES (?, ?, ?)
     ON CONFLICT(borrower_id) DO UPDATE SET
       cursor_hash = excluded.cursor_hash,
       last_sync_at = excluded.last_sync_at`,
    [borrowerId, cursorHash, now]
  );
}

export function getPlaidSyncCursor(borrowerId: number): string | null {
  const database = getDatabase();
  const result = database.exec(
    `SELECT cursor_hash FROM plaid_sync_state WHERE borrower_id = ?`,
    [borrowerId]
  );

  const firstResult = result[0];
  if (!firstResult || firstResult.values.length === 0) {
    return null;
  }

  const firstRow = firstResult.values[0];
  return (firstRow?.[0] as string | null) ?? null;
}

// ============= Pending Rate Change Operations =============

export interface PendingRateChange {
  id: number;
  loan_id: string;
  current_rate: number | null;
  proposed_rate: number;
  dscr_value: number;
  reason: string | null;
  status: string;
  requested_by: string | null;
  approved_by: string | null;
  created_at: string;
  resolved_at: string | null;
}

export function createPendingRateChange(
  loanId: string,
  currentRate: number | null,
  proposedRate: number,
  dscrValue: number,
  reason?: string,
  requestedBy?: string
): PendingRateChange {
  const database = getDatabase();
  const now = new Date().toISOString();

  database.run(
    `INSERT INTO pending_rate_changes (loan_id, current_rate, proposed_rate, dscr_value, reason, requested_by, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [loanId, currentRate, proposedRate, dscrValue, reason || null, requestedBy || null, now]
  );

  const result = database.exec('SELECT last_insert_rowid()');
  const firstResult = result[0];
  const firstRow = firstResult?.values[0];
  const id = (firstRow?.[0] as number) ?? 0;

  return {
    id,
    loan_id: loanId,
    current_rate: currentRate,
    proposed_rate: proposedRate,
    dscr_value: dscrValue,
    reason: reason || null,
    status: 'pending',
    requested_by: requestedBy || null,
    approved_by: null,
    created_at: now,
    resolved_at: null,
  };
}

export function getPendingRateChanges(loanId?: string): PendingRateChange[] {
  const database = getDatabase();

  let query = `SELECT id, loan_id, current_rate, proposed_rate, dscr_value, reason, status,
               requested_by, approved_by, created_at, resolved_at
               FROM pending_rate_changes WHERE status = 'pending'`;
  const params: string[] = [];

  if (loanId) {
    query += ' AND loan_id = ?';
    params.push(loanId);
  }

  query += ' ORDER BY created_at DESC';

  const result = database.exec(query, params);
  const firstResult = result[0];

  if (!firstResult) {
    return [];
  }

  return firstResult.values.map((row: unknown[]) => ({
    id: row[0] as number,
    loan_id: row[1] as string,
    current_rate: row[2] as number | null,
    proposed_rate: row[3] as number,
    dscr_value: row[4] as number,
    reason: row[5] as string | null,
    status: row[6] as string,
    requested_by: row[7] as string | null,
    approved_by: row[8] as string | null,
    created_at: row[9] as string,
    resolved_at: row[10] as string | null,
  }));
}

export function getPendingRateChangeById(id: number): PendingRateChange | null {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, loan_id, current_rate, proposed_rate, dscr_value, reason, status,
     requested_by, approved_by, created_at, resolved_at
     FROM pending_rate_changes WHERE id = ?`,
    [id]
  );

  const firstResult = result[0];
  const firstRow = firstResult?.values[0];

  if (!firstRow) {
    return null;
  }

  return {
    id: firstRow[0] as number,
    loan_id: firstRow[1] as string,
    current_rate: firstRow[2] as number | null,
    proposed_rate: firstRow[3] as number,
    dscr_value: firstRow[4] as number,
    reason: firstRow[5] as string | null,
    status: firstRow[6] as string,
    requested_by: firstRow[7] as string | null,
    approved_by: firstRow[8] as string | null,
    created_at: firstRow[9] as string,
    resolved_at: firstRow[10] as string | null,
  };
}

export function approveRateChange(id: number, approvedBy: string): boolean {
  const database = getDatabase();
  const now = new Date().toISOString();

  // Get the pending change
  const pendingChange = getPendingRateChangeById(id);
  if (!pendingChange || pendingChange.status !== 'pending') {
    return false;
  }

  // Update the pending change status
  database.run(
    `UPDATE pending_rate_changes SET status = 'approved', approved_by = ?, resolved_at = ? WHERE id = ?`,
    [approvedBy, now, id]
  );

  // Apply the rate change to the loan
  database.run(
    `UPDATE loans SET interest_rate = ?, updated_at = ? WHERE id = ?`,
    [pendingChange.proposed_rate, now, pendingChange.loan_id]
  );

  return true;
}

export function rejectRateChange(id: number, approvedBy: string): boolean {
  const database = getDatabase();
  const now = new Date().toISOString();

  // Get the pending change
  const pendingChange = getPendingRateChangeById(id);
  if (!pendingChange || pendingChange.status !== 'pending') {
    return false;
  }

  // Update the pending change status to rejected
  database.run(
    `UPDATE pending_rate_changes SET status = 'rejected', approved_by = ?, resolved_at = ? WHERE id = ?`,
    [approvedBy, now, id]
  );

  return true;
}

// ============= Data Proof Operations =============

export interface DataProof {
  id: number;
  proof_id: string;
  proof_type: 'identity' | 'transactions' | 'assets' | 'income';
  borrower_id: number;
  loan_id: string | null;
  data_hash: string;
  signature: string;
  // Transaction summary data
  transaction_count: number | null;
  window_start: string | null;
  window_end: string | null;
  net_income: number | null;
  avg_monthly_income: number | null;
  // Identity verification data
  kyc_level: number | null;
  verification_status: string | null;
  // Metadata
  verified: boolean;
  verified_at: string | null;
  expires_at: string | null;
  created_at: string;
}

export interface TransactionProofInput {
  proof_id: string;
  borrower_id: number;
  loan_id?: string;
  data_hash: string;
  signature: string;
  transaction_count: number;
  window_start: string;
  window_end: string;
  net_income: number;
  avg_monthly_income: number;
  expires_at: string;
}

export interface IdentityProofInput {
  proof_id: string;
  borrower_id: number;
  data_hash: string;
  signature: string;
  kyc_level: number;
  verification_status: string;
  expires_at: string;
}

/**
 * Store a transaction proof in the database
 */
export function saveTransactionProof(input: TransactionProofInput): DataProof {
  const database = getDatabase();
  const now = new Date().toISOString();

  database.run(
    `INSERT INTO data_proofs
     (proof_id, proof_type, borrower_id, loan_id, data_hash, signature,
      transaction_count, window_start, window_end, net_income, avg_monthly_income,
      expires_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(proof_id) DO UPDATE SET
       data_hash = excluded.data_hash,
       signature = excluded.signature,
       transaction_count = excluded.transaction_count,
       window_start = excluded.window_start,
       window_end = excluded.window_end,
       net_income = excluded.net_income,
       avg_monthly_income = excluded.avg_monthly_income`,
    [
      input.proof_id,
      'transactions',
      input.borrower_id,
      input.loan_id || null,
      input.data_hash,
      input.signature,
      input.transaction_count,
      input.window_start,
      input.window_end,
      input.net_income,
      input.avg_monthly_income,
      input.expires_at,
      now,
    ]
  );

  return getDataProofById(input.proof_id)!;
}

/**
 * Store an identity proof in the database
 */
export function saveIdentityProof(input: IdentityProofInput): DataProof {
  const database = getDatabase();
  const now = new Date().toISOString();

  database.run(
    `INSERT INTO data_proofs
     (proof_id, proof_type, borrower_id, data_hash, signature,
      kyc_level, verification_status, expires_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(proof_id) DO UPDATE SET
       data_hash = excluded.data_hash,
       signature = excluded.signature,
       kyc_level = excluded.kyc_level,
       verification_status = excluded.verification_status`,
    [
      input.proof_id,
      'identity',
      input.borrower_id,
      input.data_hash,
      input.signature,
      input.kyc_level,
      input.verification_status,
      input.expires_at,
      now,
    ]
  );

  return getDataProofById(input.proof_id)!;
}

/**
 * Get a data proof by its unique proof ID
 */
export function getDataProofById(proofId: string): DataProof | null {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, proof_id, proof_type, borrower_id, loan_id, data_hash, signature,
     transaction_count, window_start, window_end, net_income, avg_monthly_income,
     kyc_level, verification_status, verified, verified_at, expires_at, created_at
     FROM data_proofs WHERE proof_id = ?`,
    [proofId]
  );

  const firstResult = result[0];
  const firstRow = firstResult?.values[0];

  if (!firstRow) {
    return null;
  }

  return {
    id: firstRow[0] as number,
    proof_id: firstRow[1] as string,
    proof_type: firstRow[2] as DataProof['proof_type'],
    borrower_id: firstRow[3] as number,
    loan_id: firstRow[4] as string | null,
    data_hash: firstRow[5] as string,
    signature: firstRow[6] as string,
    transaction_count: firstRow[7] as number | null,
    window_start: firstRow[8] as string | null,
    window_end: firstRow[9] as string | null,
    net_income: firstRow[10] as number | null,
    avg_monthly_income: firstRow[11] as number | null,
    kyc_level: firstRow[12] as number | null,
    verification_status: firstRow[13] as string | null,
    verified: Boolean(firstRow[14]),
    verified_at: firstRow[15] as string | null,
    expires_at: firstRow[16] as string | null,
    created_at: firstRow[17] as string,
  };
}

/**
 * Get all proofs for a borrower
 */
export function getProofsByBorrower(borrowerId: number): DataProof[] {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, proof_id, proof_type, borrower_id, loan_id, data_hash, signature,
     transaction_count, window_start, window_end, net_income, avg_monthly_income,
     kyc_level, verification_status, verified, verified_at, expires_at, created_at
     FROM data_proofs WHERE borrower_id = ? ORDER BY created_at DESC`,
    [borrowerId]
  );

  const firstResult = result[0];
  if (!firstResult) {
    return [];
  }

  return firstResult.values.map((row: unknown[]) => ({
    id: row[0] as number,
    proof_id: row[1] as string,
    proof_type: row[2] as DataProof['proof_type'],
    borrower_id: row[3] as number,
    loan_id: row[4] as string | null,
    data_hash: row[5] as string,
    signature: row[6] as string,
    transaction_count: row[7] as number | null,
    window_start: row[8] as string | null,
    window_end: row[9] as string | null,
    net_income: row[10] as number | null,
    avg_monthly_income: row[11] as number | null,
    kyc_level: row[12] as number | null,
    verification_status: row[13] as string | null,
    verified: Boolean(row[14]),
    verified_at: row[15] as string | null,
    expires_at: row[16] as string | null,
    created_at: row[17] as string,
  }));
}

/**
 * Get the latest transaction proof for a loan
 */
export function getLatestTransactionProof(loanId: string): DataProof | null {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, proof_id, proof_type, borrower_id, loan_id, data_hash, signature,
     transaction_count, window_start, window_end, net_income, avg_monthly_income,
     kyc_level, verification_status, verified, verified_at, expires_at, created_at
     FROM data_proofs
     WHERE loan_id = ? AND proof_type = 'transactions'
     ORDER BY created_at DESC LIMIT 1`,
    [loanId]
  );

  const firstResult = result[0];
  const firstRow = firstResult?.values[0];

  if (!firstRow) {
    return null;
  }

  return {
    id: firstRow[0] as number,
    proof_id: firstRow[1] as string,
    proof_type: firstRow[2] as DataProof['proof_type'],
    borrower_id: firstRow[3] as number,
    loan_id: firstRow[4] as string | null,
    data_hash: firstRow[5] as string,
    signature: firstRow[6] as string,
    transaction_count: firstRow[7] as number | null,
    window_start: firstRow[8] as string | null,
    window_end: firstRow[9] as string | null,
    net_income: firstRow[10] as number | null,
    avg_monthly_income: firstRow[11] as number | null,
    kyc_level: firstRow[12] as number | null,
    verification_status: firstRow[13] as string | null,
    verified: Boolean(firstRow[14]),
    verified_at: firstRow[15] as string | null,
    expires_at: firstRow[16] as string | null,
    created_at: firstRow[17] as string,
  };
}

/**
 * Mark a proof as verified
 */
export function markProofVerified(proofId: string): boolean {
  const database = getDatabase();
  const now = new Date().toISOString();

  database.run(
    `UPDATE data_proofs SET verified = 1, verified_at = ? WHERE proof_id = ?`,
    [now, proofId]
  );

  const proof = getDataProofById(proofId);
  return proof?.verified ?? false;
}

/**
 * Check if a proof is valid (not expired and verified)
 */
export function isProofValid(proofId: string): boolean {
  const proof = getDataProofById(proofId);
  if (!proof) {
    return false;
  }

  if (!proof.verified) {
    return false;
  }

  if (proof.expires_at) {
    const expiresAt = new Date(proof.expires_at).getTime();
    if (Date.now() > expiresAt) {
      return false;
    }
  }

  return true;
}

/**
 * Link a DSCR calculation to a data proof
 */
export function linkDscrToProof(dscrId: number, proofId: string): void {
  const database = getDatabase();
  const proof = getDataProofById(proofId);

  if (!proof) {
    throw new Error(`Proof not found: ${proofId}`);
  }

  database.run(
    `UPDATE dscr_calculations SET data_proof_id = ?, proof_verified = ? WHERE id = ?`,
    [proof.id, proof.verified ? 1 : 0, dscrId]
  );
}

// ============= Statistics Operations =============

export interface DatabaseStats {
  total_borrowers: number;
  total_loans: number;
  total_transactions: number;
  loans_by_status: Record<string, number>;
  average_loan_amount: number;
  average_dscr: number | null;
}

/**
 * Helper to safely extract a scalar count from a query result
 */
function getCountResult(result: QueryExecResult[]): number {
  const firstResult = result[0];
  const firstRow = firstResult?.values[0];
  return (firstRow?.[0] as number) ?? 0;
}

/**
 * Helper to safely extract a nullable number from a query result
 */
function getNullableNumberResult(result: QueryExecResult[]): number | null {
  const firstResult = result[0];
  const firstRow = firstResult?.values[0];
  const value = firstRow?.[0];
  return value === null || value === undefined ? null : (value as number);
}

export function getDatabaseStats(): DatabaseStats {
  const database = getDatabase();

  const borrowerCount = getCountResult(database.exec('SELECT COUNT(*) FROM borrowers'));
  const loanCount = getCountResult(database.exec('SELECT COUNT(*) FROM loans'));
  const transactionCount = getCountResult(database.exec('SELECT COUNT(*) FROM transactions'));
  const avgLoanAmount = getNullableNumberResult(database.exec('SELECT AVG(amount) FROM loans'));
  const avgDscr = getNullableNumberResult(database.exec('SELECT AVG(dscr_value) FROM dscr_calculations'));

  const statusResult = database.exec('SELECT status, COUNT(*) FROM loans GROUP BY status');
  const loansByStatus: Record<string, number> = {};
  const statusFirstResult = statusResult[0];
  if (statusFirstResult) {
    for (const row of statusFirstResult.values) {
      const status = row[0];
      const count = row[1];
      if (typeof status === 'string' && typeof count === 'number') {
        loansByStatus[status] = count;
      }
    }
  }

  return {
    total_borrowers: borrowerCount,
    total_loans: loanCount,
    total_transactions: transactionCount,
    loans_by_status: loansByStatus,
    average_loan_amount: avgLoanAmount ?? 0,
    average_dscr: avgDscr,
  };
}
