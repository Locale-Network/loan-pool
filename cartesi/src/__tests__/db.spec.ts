import {
  initDatabase,
  closeDatabase,
  getDatabase,
  createBorrower,
  getBorrowerByAddress,
  getBorrowerById,
  updateBorrowerKycLevel,
  createLoan,
  getLoanById,
  getLoansByBorrower,
  updateLoanStatus,
  updateLoanDscr,
  insertTransactions,
  getTransactionsByBorrower,
  getTransactionsForDscr,
  saveDscrCalculation,
  getDscrHistory,
  updatePlaidSyncCursor,
  getPlaidSyncCursor,
  getDatabaseStats,
} from '../db';

describe('Database Module', () => {
  beforeEach(async () => {
    closeDatabase();
    await initDatabase();
  });

  afterEach(() => {
    closeDatabase();
  });

  describe('initDatabase', () => {
    it('should initialize the database', async () => {
      const db = getDatabase();
      expect(db).toBeDefined();
    });

    it('should create all required tables', () => {
      const db = getDatabase();
      const tables = db.exec(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
      );
      const tableNames = tables[0].values.map((row: unknown[]) => row[0]);

      expect(tableNames).toContain('borrowers');
      expect(tableNames).toContain('loans');
      expect(tableNames).toContain('transactions');
      expect(tableNames).toContain('dscr_calculations');
      expect(tableNames).toContain('plaid_sync_state');
    });
  });

  describe('Borrower Operations', () => {
    const testAddress = '0x1234567890abcdef1234567890abcdef12345678';

    it('should create a borrower', () => {
      const borrower = createBorrower(testAddress);

      expect(borrower).toBeDefined();
      expect(borrower.wallet_address).toBe(testAddress.toLowerCase());
      expect(borrower.kyc_level).toBe(0);
      expect(borrower.id).toBeGreaterThan(0);
    });

    it('should create a borrower with plaid hash', () => {
      const plaidHash = 'test-plaid-hash';
      const borrower = createBorrower(testAddress, plaidHash);

      expect(borrower.plaid_item_hash).toBe(plaidHash);
    });

    it('should get borrower by address', () => {
      createBorrower(testAddress);
      const borrower = getBorrowerByAddress(testAddress);

      expect(borrower).toBeDefined();
      expect(borrower?.wallet_address).toBe(testAddress.toLowerCase());
    });

    it('should return null for non-existent address', () => {
      const borrower = getBorrowerByAddress('0xnonexistent');
      expect(borrower).toBeNull();
    });

    it('should get borrower by ID', () => {
      const created = createBorrower(testAddress);
      const borrower = getBorrowerById(created.id);

      expect(borrower).toBeDefined();
      expect(borrower?.id).toBe(created.id);
    });

    it('should update KYC level', () => {
      createBorrower(testAddress);
      updateBorrowerKycLevel(testAddress, 2);

      const borrower = getBorrowerByAddress(testAddress);
      expect(borrower?.kyc_level).toBe(2);
    });

    it('should handle duplicate borrower creation gracefully', () => {
      createBorrower(testAddress);
      const borrower = createBorrower(testAddress, 'new-hash');

      expect(borrower.wallet_address).toBe(testAddress.toLowerCase());
      expect(borrower.plaid_item_hash).toBe('new-hash');
    });
  });

  describe('Loan Operations', () => {
    const testAddress = '0x1234567890abcdef1234567890abcdef12345678';
    let borrowerId: number;

    beforeEach(() => {
      const borrower = createBorrower(testAddress);
      borrowerId = borrower.id;
    });

    it('should create a loan', () => {
      const loan = createLoan('loan-001', borrowerId, testAddress, 100000);

      expect(loan).toBeDefined();
      expect(loan.id).toBe('loan-001');
      expect(loan.borrower_id).toBe(borrowerId);
      expect(loan.amount).toBe(100000);
      expect(loan.status).toBe('pending');
    });

    it('should create loan with custom term', () => {
      const loan = createLoan('loan-002', borrowerId, testAddress, 50000, 36);

      expect(loan.term_months).toBe(36);
    });

    it('should get loan by ID', () => {
      createLoan('loan-003', borrowerId, testAddress, 75000);
      const loan = getLoanById('loan-003');

      expect(loan).toBeDefined();
      expect(loan?.id).toBe('loan-003');
    });

    it('should return null for non-existent loan', () => {
      const loan = getLoanById('non-existent');
      expect(loan).toBeNull();
    });

    it('should get loans by borrower', () => {
      createLoan('loan-004', borrowerId, testAddress, 100000);
      createLoan('loan-005', borrowerId, testAddress, 200000);

      const loans = getLoansByBorrower(borrowerId);

      expect(loans).toHaveLength(2);
      expect(loans.map(l => l.id)).toContain('loan-004');
      expect(loans.map(l => l.id)).toContain('loan-005');
    });

    it('should update loan status', () => {
      createLoan('loan-006', borrowerId, testAddress, 100000);
      updateLoanStatus('loan-006', 'approved');

      const loan = getLoanById('loan-006');
      expect(loan?.status).toBe('approved');
    });

    it('should update loan DSCR and interest rate', () => {
      createLoan('loan-007', borrowerId, testAddress, 100000);
      updateLoanDscr('loan-007', 5.5, 1.35, 'approved');

      const loan = getLoanById('loan-007');
      expect(loan?.interest_rate).toBe(5.5);
      expect(loan?.dscr).toBe(1.35);
      expect(loan?.status).toBe('approved');
    });
  });

  describe('Transaction Operations', () => {
    const testAddress = '0x1234567890abcdef1234567890abcdef12345678';
    let borrowerId: number;

    beforeEach(() => {
      const borrower = createBorrower(testAddress);
      borrowerId = borrower.id;
    });

    it('should insert transactions', () => {
      const count = insertTransactions(borrowerId, [
        { amount: 1000, date: '2024-01-15', category: 'income' },
        { amount: -500, date: '2024-01-16', category: 'expense' },
      ]);

      expect(count).toBe(2);
    });

    it('should insert transaction with all fields', () => {
      insertTransactions(borrowerId, [
        {
          plaid_transaction_id: 'plaid-001',
          amount: 2500,
          date: '2024-01-20',
          category: 'payroll',
          merchant_name: 'Acme Corp',
          pending: false,
          is_income: true,
        },
      ]);

      const transactions = getTransactionsByBorrower(borrowerId);
      expect(transactions).toHaveLength(1);
      expect(transactions[0]!.amount).toBe(2500);
      expect(transactions[0]!.is_income).toBe(true);
    });

    it('should get transactions by borrower', () => {
      insertTransactions(borrowerId, [
        { amount: 1000, date: '2024-01-15' },
        { amount: 2000, date: '2024-01-16' },
        { amount: 3000, date: '2024-01-17' },
      ]);

      const transactions = getTransactionsByBorrower(borrowerId);
      expect(transactions).toHaveLength(3);
    });

    it('should filter transactions by date range', () => {
      insertTransactions(borrowerId, [
        { amount: 1000, date: '2024-01-10' },
        { amount: 2000, date: '2024-01-15' },
        { amount: 3000, date: '2024-01-20' },
      ]);

      const transactions = getTransactionsByBorrower(
        borrowerId,
        '2024-01-12',
        '2024-01-18'
      );

      expect(transactions).toHaveLength(1);
      expect(transactions[0]!.date).toBe('2024-01-15');
    });

    it('should get transactions for DSCR calculation', () => {
      // Insert recent transactions
      const today = new Date();
      const recentDate = new Date(today);
      recentDate.setMonth(today.getMonth() - 6);
      const dateStr = recentDate.toISOString().split('T')[0]!;

      insertTransactions(borrowerId, [
        { amount: 5000, date: dateStr, pending: false },
      ]);

      const transactions = getTransactionsForDscr(borrowerId);
      expect(transactions.length).toBeGreaterThanOrEqual(1);
    });

    it('should handle duplicate plaid_transaction_id', () => {
      insertTransactions(borrowerId, [
        { plaid_transaction_id: 'plaid-dup', amount: 1000, date: '2024-01-15' },
      ]);

      // Insert same transaction ID with updated amount
      insertTransactions(borrowerId, [
        { plaid_transaction_id: 'plaid-dup', amount: 1500, date: '2024-01-15' },
      ]);

      const transactions = getTransactionsByBorrower(borrowerId);
      expect(transactions).toHaveLength(1);
      expect(transactions[0]!.amount).toBe(1500);
    });
  });

  describe('DSCR Calculation Operations', () => {
    const testAddress = '0x1234567890abcdef1234567890abcdef12345678';
    let borrowerId: number;

    beforeEach(() => {
      const borrower = createBorrower(testAddress);
      borrowerId = borrower.id;
      createLoan('loan-dscr', borrowerId, testAddress, 100000);
    });

    it('should save DSCR calculation', () => {
      const calc = saveDscrCalculation('loan-dscr', borrowerId, 1.35, 5000, 3700, 'hash123');

      expect(calc).toBeDefined();
      expect(calc.dscr_value).toBe(1.35);
      expect(calc.monthly_noi).toBe(5000);
      expect(calc.monthly_debt_service).toBe(3700);
      expect(calc.input_hash).toBe('hash123');
    });

    it('should get DSCR history', () => {
      saveDscrCalculation('loan-dscr', borrowerId, 1.2);
      saveDscrCalculation('loan-dscr', borrowerId, 1.3);
      saveDscrCalculation('loan-dscr', borrowerId, 1.35);

      const history = getDscrHistory('loan-dscr');

      expect(history).toHaveLength(3);
      // Should contain all three values
      const dscrValues = history.map(h => h.dscr_value);
      expect(dscrValues).toContain(1.2);
      expect(dscrValues).toContain(1.3);
      expect(dscrValues).toContain(1.35);
    });

    it('should return empty array for loan with no calculations', () => {
      const history = getDscrHistory('non-existent-loan');
      expect(history).toHaveLength(0);
    });
  });

  describe('Plaid Sync State Operations', () => {
    const testAddress = '0x1234567890abcdef1234567890abcdef12345678';
    let borrowerId: number;

    beforeEach(() => {
      const borrower = createBorrower(testAddress);
      borrowerId = borrower.id;
    });

    it('should update sync cursor', () => {
      updatePlaidSyncCursor(borrowerId, 'cursor-abc123');

      const cursor = getPlaidSyncCursor(borrowerId);
      expect(cursor).toBe('cursor-abc123');
    });

    it('should update existing cursor', () => {
      updatePlaidSyncCursor(borrowerId, 'cursor-v1');
      updatePlaidSyncCursor(borrowerId, 'cursor-v2');

      const cursor = getPlaidSyncCursor(borrowerId);
      expect(cursor).toBe('cursor-v2');
    });

    it('should return null for borrower without cursor', () => {
      const cursor = getPlaidSyncCursor(borrowerId);
      expect(cursor).toBeNull();
    });
  });

  describe('Database Statistics', () => {
    it('should return statistics for empty database', () => {
      const stats = getDatabaseStats();

      expect(stats.total_borrowers).toBe(0);
      expect(stats.total_loans).toBe(0);
      expect(stats.total_transactions).toBe(0);
      expect(stats.average_loan_amount).toBe(0);
    });

    it('should return accurate statistics', () => {
      const borrower1 = createBorrower('0x1111111111111111111111111111111111111111');
      const borrower2 = createBorrower('0x2222222222222222222222222222222222222222');

      createLoan('loan-stat-1', borrower1.id, borrower1.wallet_address, 100000);
      createLoan('loan-stat-2', borrower1.id, borrower1.wallet_address, 200000);
      updateLoanStatus('loan-stat-2', 'approved');

      createLoan('loan-stat-3', borrower2.id, borrower2.wallet_address, 150000);

      insertTransactions(borrower1.id, [
        { amount: 5000, date: '2024-01-15' },
        { amount: 6000, date: '2024-01-16' },
      ]);

      const stats = getDatabaseStats();

      expect(stats.total_borrowers).toBe(2);
      expect(stats.total_loans).toBe(3);
      expect(stats.total_transactions).toBe(2);
      expect(stats.loans_by_status).toHaveProperty('pending', 2);
      expect(stats.loans_by_status).toHaveProperty('approved', 1);
      expect(stats.average_loan_amount).toBe(150000);
    });
  });
});
