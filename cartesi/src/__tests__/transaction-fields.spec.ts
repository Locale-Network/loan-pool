import {
  initDatabase,
  closeDatabase,
  createBorrower,
  insertTransactions,
  getTransactionsByBorrower,
  getTransactionsForDscr,
} from '../db';

describe('Transaction Fields', () => {
  beforeEach(async () => {
    closeDatabase();
    await initDatabase();
  });

  afterEach(() => {
    closeDatabase();
  });

  describe('Plaid Transaction Metadata', () => {
    it('should store and retrieve personal_finance_category fields', () => {
      const borrower = createBorrower('0xCategoryTest11111111111111111111111111111');

      insertTransactions(borrower.id, [
        {
          plaid_transaction_id: 'tx-category-1',
          amount: 1000,
          date: '2024-01-15',
          merchant_name: 'Salary Deposit',
          category: 'Income',
          personal_finance_category_primary: 'INCOME',
          personal_finance_category_detailed: 'INCOME_WAGES',
          category_confidence: 'VERY_HIGH',
        },
      ]);

      const transactions = getTransactionsByBorrower(borrower.id);

      expect(transactions).toHaveLength(1);
      expect(transactions[0]!.personal_finance_category_primary).toBe('INCOME');
      expect(transactions[0]!.personal_finance_category_detailed).toBe('INCOME_WAGES');
      expect(transactions[0]!.category_confidence).toBe('VERY_HIGH');
    });

    it('should store and retrieve category_confidence', () => {
      const borrower = createBorrower('0xConfidenceTest1111111111111111111111111');

      insertTransactions(borrower.id, [
        {
          plaid_transaction_id: 'tx-confidence-1',
          amount: 500,
          date: '2024-01-10',
          merchant_name: 'Coffee Shop',
          category: 'Food',
          category_confidence: 'HIGH',
        },
        {
          plaid_transaction_id: 'tx-confidence-2',
          amount: 50,
          date: '2024-01-11',
          merchant_name: 'Unknown Vendor',
          category: 'Other',
          category_confidence: 'LOW',
        },
      ]);

      const transactions = getTransactionsByBorrower(borrower.id);

      expect(transactions).toHaveLength(2);
      // Find transactions by plaid_transaction_id to avoid order dependency
      const highConfTx = transactions.find(tx => tx.plaid_transaction_id === 'tx-confidence-1');
      const lowConfTx = transactions.find(tx => tx.plaid_transaction_id === 'tx-confidence-2');
      expect(highConfTx!.category_confidence).toBe('HIGH');
      expect(lowConfTx!.category_confidence).toBe('LOW');
    });

    it('should store and retrieve is_recurring flag', () => {
      const borrower = createBorrower('0xRecurringTest11111111111111111111111111');

      insertTransactions(borrower.id, [
        {
          plaid_transaction_id: 'tx-recurring-1',
          amount: 15,
          date: '2024-01-15',
          merchant_name: 'Netflix',
          category: 'Entertainment',
          is_recurring: true,
        },
        {
          plaid_transaction_id: 'tx-recurring-2',
          amount: 100,
          date: '2024-01-20',
          merchant_name: 'One-time Purchase',
          category: 'Shopping',
          is_recurring: false,
        },
      ]);

      const transactions = getTransactionsByBorrower(borrower.id);

      expect(transactions).toHaveLength(2);
      // Find transactions by plaid_transaction_id to avoid order dependency
      const recurringTx = transactions.find(tx => tx.plaid_transaction_id === 'tx-recurring-1');
      const nonRecurringTx = transactions.find(tx => tx.plaid_transaction_id === 'tx-recurring-2');
      expect(recurringTx!.is_recurring).toBe(true);
      expect(nonRecurringTx!.is_recurring).toBe(false);
    });

    it('should handle null/undefined for optional fields', () => {
      const borrower = createBorrower('0xNullFieldTest1111111111111111111111111');

      insertTransactions(borrower.id, [
        {
          plaid_transaction_id: 'tx-minimal-1',
          amount: 200,
          date: '2024-01-05',
          merchant_name: 'Basic Transaction',
          // No optional fields
        },
      ]);

      const transactions = getTransactionsByBorrower(borrower.id);

      expect(transactions).toHaveLength(1);
      expect(transactions[0]!.personal_finance_category_primary).toBeNull();
      expect(transactions[0]!.personal_finance_category_detailed).toBeNull();
      expect(transactions[0]!.category_confidence).toBeNull();
      // is_recurring defaults to false when not provided
    });

    it('should store all fields together', () => {
      const borrower = createBorrower('0xAllFieldsTest11111111111111111111111111');

      const fullTransaction = {
        plaid_transaction_id: 'tx-full-1',
        amount: 2500,
        date: '2024-02-01',
        merchant_name: 'Monthly Rent',
        category: 'Housing',
        personal_finance_category_primary: 'RENT_AND_UTILITIES',
        personal_finance_category_detailed: 'RENT_AND_UTILITIES_RENT',
        category_confidence: 'VERY_HIGH',
        is_recurring: true,
        recurring_stream_id: 'stream-rent-123',
        recurring_frequency: 'MONTHLY',
        recurring_is_active: true,
      };

      insertTransactions(borrower.id, [fullTransaction]);

      const transactions = getTransactionsByBorrower(borrower.id);

      expect(transactions).toHaveLength(1);
      const tx = transactions[0]!;
      expect(tx.amount).toBe(2500);
      expect(tx.merchant_name).toBe('Monthly Rent');
      expect(tx.personal_finance_category_primary).toBe('RENT_AND_UTILITIES');
      expect(tx.personal_finance_category_detailed).toBe('RENT_AND_UTILITIES_RENT');
      expect(tx.category_confidence).toBe('VERY_HIGH');
      expect(tx.is_recurring).toBe(true);
      expect(tx.recurring_stream_id).toBe('stream-rent-123');
      expect(tx.recurring_frequency).toBe('MONTHLY');
      expect(tx.recurring_is_active).toBe(true);
    });

    it('should store recurring stream metadata', () => {
      const borrower = createBorrower('0xStreamTest1111111111111111111111111111');

      insertTransactions(borrower.id, [
        {
          plaid_transaction_id: 'tx-stream-1',
          amount: 99,
          date: '2024-03-01',
          merchant_name: 'Spotify',
          category: 'Entertainment',
          is_recurring: true,
          recurring_stream_id: 'stream-spotify-456',
          recurring_frequency: 'MONTHLY',
          recurring_is_active: true,
        },
        {
          plaid_transaction_id: 'tx-stream-2',
          amount: 150,
          date: '2024-03-15',
          merchant_name: 'Gym Membership (Cancelled)',
          category: 'Health',
          is_recurring: true,
          recurring_stream_id: 'stream-gym-789',
          recurring_frequency: 'MONTHLY',
          recurring_is_active: false, // No longer active
        },
      ]);

      const transactions = getTransactionsByBorrower(borrower.id);

      expect(transactions).toHaveLength(2);

      const spotify = transactions.find(tx => tx.recurring_stream_id === 'stream-spotify-456');
      expect(spotify).toBeDefined();
      expect(spotify!.recurring_is_active).toBe(true);

      const gym = transactions.find(tx => tx.recurring_stream_id === 'stream-gym-789');
      expect(gym).toBeDefined();
      expect(gym!.recurring_is_active).toBe(false);
    });
  });

  describe('DSCR Calculation with New Fields', () => {
    it('should retrieve transactions for DSCR with all fields', () => {
      const borrower = createBorrower('0xDscrFieldTest1111111111111111111111111');

      // Use recent dates (relative to current date)
      const now = new Date();
      const lastMonth = new Date(now.getFullYear(), now.getMonth() - 1, 15).toISOString().split('T')[0];
      const twoMonthsAgo = new Date(now.getFullYear(), now.getMonth() - 2, 15).toISOString().split('T')[0];

      // Insert transactions with various metadata
      insertTransactions(borrower.id, [
        {
          plaid_transaction_id: 'tx-dscr-1',
          amount: 5000,
          date: lastMonth!,
          merchant_name: 'Paycheck',
          category: 'Income',
          personal_finance_category_primary: 'INCOME',
          personal_finance_category_detailed: 'INCOME_WAGES',
          category_confidence: 'VERY_HIGH',
          is_recurring: true,
        },
        {
          plaid_transaction_id: 'tx-dscr-2',
          amount: 3000,
          date: twoMonthsAgo!,
          merchant_name: 'Paycheck',
          category: 'Income',
          personal_finance_category_primary: 'INCOME',
          personal_finance_category_detailed: 'INCOME_WAGES',
          category_confidence: 'VERY_HIGH',
          is_recurring: true,
        },
      ]);

      // Get transactions for DSCR (typically filters to recent months)
      const dscrTransactions = getTransactionsForDscr(borrower.id, 12);

      expect(dscrTransactions).toHaveLength(2);

      // DSCR transactions should have amount and date
      dscrTransactions.forEach(tx => {
        expect(tx.amount).toBeGreaterThan(0);
        expect(tx.date).toBeDefined();
      });
    });
  });

  describe('Transaction Categories for Financial Analysis', () => {
    it('should categorize income transactions correctly', () => {
      const borrower = createBorrower('0xIncomeCatTest111111111111111111111111');

      const incomeTransactions = [
        {
          plaid_transaction_id: 'income-1',
          amount: 5000,
          date: '2024-01-15',
          merchant_name: 'Direct Deposit - Employer',
          category: 'Income',
          personal_finance_category_primary: 'INCOME',
          personal_finance_category_detailed: 'INCOME_WAGES',
        },
        {
          plaid_transaction_id: 'income-2',
          amount: 200,
          date: '2024-01-20',
          merchant_name: 'Interest Payment',
          category: 'Income',
          personal_finance_category_primary: 'INCOME',
          personal_finance_category_detailed: 'INCOME_INTEREST_EARNED',
        },
      ];

      insertTransactions(borrower.id, incomeTransactions);

      const transactions = getTransactionsByBorrower(borrower.id);

      transactions.forEach(tx => {
        expect(tx.personal_finance_category_primary).toBe('INCOME');
      });
    });

    it('should handle expense transactions with categories', () => {
      const borrower = createBorrower('0xExpenseCatTest11111111111111111111111');

      const expenseTransactions = [
        {
          plaid_transaction_id: 'expense-1',
          amount: -2000,
          date: '2024-01-01',
          merchant_name: 'Rent Payment',
          category: 'Housing',
          personal_finance_category_primary: 'RENT_AND_UTILITIES',
          personal_finance_category_detailed: 'RENT_AND_UTILITIES_RENT',
          is_recurring: true,
        },
        {
          plaid_transaction_id: 'expense-2',
          amount: -150,
          date: '2024-01-15',
          merchant_name: 'Electric Company',
          category: 'Utilities',
          personal_finance_category_primary: 'RENT_AND_UTILITIES',
          personal_finance_category_detailed: 'RENT_AND_UTILITIES_GAS_AND_ELECTRICITY',
          is_recurring: true,
        },
      ];

      insertTransactions(borrower.id, expenseTransactions);

      const transactions = getTransactionsByBorrower(borrower.id);

      expect(transactions).toHaveLength(2);

      // Verify recurring expenses are marked
      transactions.forEach(tx => {
        expect(tx.is_recurring).toBe(true);
      });
    });
  });
});
