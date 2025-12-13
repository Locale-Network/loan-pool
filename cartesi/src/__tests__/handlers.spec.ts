import {
  initDatabase,
  closeDatabase,
  createBorrower,
  createLoan,
  insertTransactions,
  createPendingRateChange,
  getPendingRateChangeById,
  getLoanById,
} from '../db';
import { handleRegisterBorrower, handleUpdateKyc, handleInspectBorrower } from '../handlers/borrower';
import { handleCreateLoan, handleUpdateLoanStatus, handleInspectLoan } from '../handlers/loan';
import { handleSyncTransactions, handleInspectTransactions } from '../handlers/transaction';
import {
  handleCalculateDscr,
  handleInspectDscr,
  handleApproveRateChange,
  handleRejectRateChange,
  handleInspectPendingRateChanges,
} from '../handlers/dscr';
import { handleInspectStats } from '../handlers/stats';

// Mock fetch
global.fetch = jest.fn(() =>
  Promise.resolve({
    ok: true,
    json: () => Promise.resolve({}),
  })
) as jest.Mock;

const createMockAdvanceData = () => ({
  metadata: {
    msg_sender: '0x1234567890abcdef1234567890abcdef12345678',
    epoch_index: 0,
    input_index: 0,
    block_number: 12345,
    timestamp: Date.now(),
  },
  payload: '0x',
});

describe('Handlers', () => {
  beforeEach(async () => {
    closeDatabase();
    await initDatabase();
    jest.clearAllMocks();
  });

  afterEach(() => {
    closeDatabase();
  });

  describe('Borrower Handlers', () => {
    describe('handleRegisterBorrower', () => {
      it('should register a new borrower', async () => {
        const result = await handleRegisterBorrower(createMockAdvanceData(), {
          action: 'register_borrower',
          wallet_address: '0x1111111111111111111111111111111111111111',
        });

        expect(result.status).toBe('accept');
        expect(result.response).toHaveProperty('success', true);
        expect(result.response).toHaveProperty('borrower');
      });

      it('should return existing borrower if already registered', async () => {
        const address = '0x2222222222222222222222222222222222222222';

        await handleRegisterBorrower(createMockAdvanceData(), {
          action: 'register_borrower',
          wallet_address: address,
        });

        const result = await handleRegisterBorrower(createMockAdvanceData(), {
          action: 'register_borrower',
          wallet_address: address,
        });

        expect(result.status).toBe('accept');
        expect(result.response).toHaveProperty('message', 'Borrower already registered');
      });

      it('should reject invalid wallet address', async () => {
        await expect(
          handleRegisterBorrower(createMockAdvanceData(), {
            action: 'register_borrower',
            wallet_address: 'invalid',
          })
        ).rejects.toThrow('Invalid wallet address format');
      });

      it('should reject missing wallet address', async () => {
        await expect(
          handleRegisterBorrower(createMockAdvanceData(), {
            action: 'register_borrower',
          })
        ).rejects.toThrow('Valid wallet_address is required');
      });
    });

    describe('handleUpdateKyc', () => {
      it('should update KYC level', async () => {
        const address = '0x3333333333333333333333333333333333333333';
        createBorrower(address);

        const result = await handleUpdateKyc(createMockAdvanceData(), {
          action: 'update_kyc',
          wallet_address: address,
          kyc_level: 2,
        });

        expect(result.status).toBe('accept');
        expect(result.response).toHaveProperty('kyc_level', 2);
      });

      it('should reject invalid KYC level', async () => {
        const address = '0x4444444444444444444444444444444444444444';
        createBorrower(address);

        await expect(
          handleUpdateKyc(createMockAdvanceData(), {
            action: 'update_kyc',
            wallet_address: address,
            kyc_level: 5,
          })
        ).rejects.toThrow('Valid kyc_level (0-3) is required');
      });

      it('should reject non-existent borrower', async () => {
        await expect(
          handleUpdateKyc(createMockAdvanceData(), {
            action: 'update_kyc',
            wallet_address: '0x5555555555555555555555555555555555555555',
            kyc_level: 1,
          })
        ).rejects.toThrow('Borrower not found');
      });
    });

    describe('handleInspectBorrower', () => {
      it('should return borrower by address', async () => {
        const address = '0x6666666666666666666666666666666666666666';
        createBorrower(address);

        const result = await handleInspectBorrower({
          type: 'borrower',
          params: { address },
        });

        expect(result).toHaveProperty('borrower');
        expect((result as any).borrower.wallet_address).toBe(address.toLowerCase());
      });

      it('should return error for non-existent borrower', async () => {
        const result = await handleInspectBorrower({
          type: 'borrower',
          params: { address: '0xnonexistent' },
        });

        expect(result).toHaveProperty('error', 'Borrower not found');
      });
    });
  });

  describe('Loan Handlers', () => {
    const borrowerAddress = '0x7777777777777777777777777777777777777777';

    describe('handleCreateLoan', () => {
      it('should create a new loan', async () => {
        const result = await handleCreateLoan(createMockAdvanceData(), {
          action: 'create_loan',
          loan_id: 'loan-test-001',
          borrower_address: borrowerAddress,
          amount: '100000',
        });

        expect(result.status).toBe('accept');
        expect(result.response).toHaveProperty('success', true);
        expect((result.response as any).loan.id).toBe('loan-test-001');
      });

      it('should create borrower if not exists', async () => {
        await handleCreateLoan(createMockAdvanceData(), {
          action: 'create_loan',
          loan_id: 'loan-test-002',
          borrower_address: '0x8888888888888888888888888888888888888888',
          amount: '50000',
        });

        const inspectResult = await handleInspectBorrower({
          type: 'borrower',
          params: { address: '0x8888888888888888888888888888888888888888' },
        });

        expect(inspectResult).toHaveProperty('borrower');
      });

      it('should reject duplicate loan ID', async () => {
        await handleCreateLoan(createMockAdvanceData(), {
          action: 'create_loan',
          loan_id: 'loan-dup',
          borrower_address: borrowerAddress,
          amount: '100000',
        });

        await expect(
          handleCreateLoan(createMockAdvanceData(), {
            action: 'create_loan',
            loan_id: 'loan-dup',
            borrower_address: borrowerAddress,
            amount: '200000',
          })
        ).rejects.toThrow('Loan with ID loan-dup already exists');
      });

      it('should reject invalid amount', async () => {
        await expect(
          handleCreateLoan(createMockAdvanceData(), {
            action: 'create_loan',
            loan_id: 'loan-invalid',
            borrower_address: borrowerAddress,
            amount: '0',
          })
        ).rejects.toThrow('Loan amount must be greater than 0');
      });
    });

    describe('handleUpdateLoanStatus', () => {
      it('should update loan status', async () => {
        const borrower = createBorrower(borrowerAddress);
        createLoan('loan-status-test', borrower.id, borrowerAddress, 100000);

        const result = await handleUpdateLoanStatus(createMockAdvanceData(), {
          action: 'update_loan_status',
          loan_id: 'loan-status-test',
          status: 'approved',
        });

        expect(result.status).toBe('accept');
        expect(result.response).toHaveProperty('status', 'approved');
      });

      it('should reject invalid status', async () => {
        const borrower = createBorrower(borrowerAddress);
        createLoan('loan-invalid-status', borrower.id, borrowerAddress, 100000);

        await expect(
          handleUpdateLoanStatus(createMockAdvanceData(), {
            action: 'update_loan_status',
            loan_id: 'loan-invalid-status',
            status: 'invalid_status',
          })
        ).rejects.toThrow('Valid status required');
      });
    });

    describe('handleInspectLoan', () => {
      it('should return loan by ID', async () => {
        const borrower = createBorrower(borrowerAddress);
        createLoan('loan-inspect', borrower.id, borrowerAddress, 75000);

        const result = await handleInspectLoan({
          type: 'loan',
          params: { id: 'loan-inspect' },
        });

        expect(result).toHaveProperty('loan');
        expect((result as any).loan.id).toBe('loan-inspect');
      });

      it('should return loans by borrower', async () => {
        const borrower = createBorrower(borrowerAddress);
        createLoan('loan-b1', borrower.id, borrowerAddress, 50000);
        createLoan('loan-b2', borrower.id, borrowerAddress, 60000);

        const result = await handleInspectLoan({
          type: 'loan',
          params: { borrower: borrowerAddress },
        });

        expect(result).toHaveProperty('loans');
        expect((result as any).loans).toHaveLength(2);
      });
    });
  });

  describe('Transaction Handlers', () => {
    const borrowerAddress = '0x9999999999999999999999999999999999999999';

    describe('handleSyncTransactions', () => {
      it('should sync transactions', async () => {
        const result = await handleSyncTransactions(createMockAdvanceData(), {
          action: 'sync_transactions',
          borrower_address: borrowerAddress,
          transactions: [
            { amount: 1000, date: '2024-01-15' },
            { amount: 2000, date: '2024-01-16' },
          ],
        });

        expect(result.status).toBe('accept');
        expect(result.response).toHaveProperty('transactions_synced', 2);
      });

      it('should update cursor when provided', async () => {
        const result = await handleSyncTransactions(createMockAdvanceData(), {
          action: 'sync_transactions',
          borrower_address: borrowerAddress,
          transactions: [{ amount: 1000, date: '2024-01-15' }],
          cursor_hash: 'cursor-test-123',
        });

        expect(result.response).toHaveProperty('cursor_updated', true);
      });

      it('should reject empty transactions', async () => {
        await expect(
          handleSyncTransactions(createMockAdvanceData(), {
            action: 'sync_transactions',
            borrower_address: borrowerAddress,
            transactions: [],
          })
        ).rejects.toThrow('At least one transaction is required');
      });

      it('should reject invalid date format', async () => {
        await expect(
          handleSyncTransactions(createMockAdvanceData(), {
            action: 'sync_transactions',
            borrower_address: borrowerAddress,
            transactions: [{ amount: 1000, date: '2024/01/15' }],
          })
        ).rejects.toThrow('invalid date format');
      });
    });

    describe('handleInspectTransactions', () => {
      it('should return transactions for borrower', async () => {
        const borrower = createBorrower(borrowerAddress);
        insertTransactions(borrower.id, [
          { amount: 1000, date: '2024-01-15' },
          { amount: 2000, date: '2024-01-16' },
        ]);

        const result = await handleInspectTransactions({
          type: 'transactions',
          params: { borrower: borrowerAddress },
        });

        expect(result).toHaveProperty('transaction_count', 2);
        expect(result).toHaveProperty('transactions');
      });
    });
  });

  describe('DSCR Handlers', () => {
    const borrowerAddress = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    describe('handleCalculateDscr', () => {
      it('should calculate DSCR with transactions', async () => {
        const borrower = createBorrower(borrowerAddress);
        createLoan('loan-dscr-test', borrower.id, borrowerAddress, 100000);

        // Insert recent transactions
        const date1 = new Date();
        date1.setMonth(date1.getMonth() - 1);
        const date2 = new Date();
        date2.setMonth(date2.getMonth() - 2);
        const date3 = new Date();
        date3.setMonth(date3.getMonth() - 3);

        insertTransactions(borrower.id, [
          {
            amount: 5000,
            date: date1.toISOString().split('T')[0]!,
          },
          {
            amount: 5000,
            date: date2.toISOString().split('T')[0]!,
          },
          {
            amount: 5000,
            date: date3.toISOString().split('T')[0]!,
          },
        ]);

        const result = await handleCalculateDscr(createMockAdvanceData(), {
          action: 'calculate_dscr',
          loan_id: 'loan-dscr-test',
        });

        expect(result.status).toBe('accept');
        expect(result.response).toHaveProperty('dscr');
        expect(result.response).toHaveProperty('interest_rate');
        expect(result.response).toHaveProperty('input_hash');
      });

      it('should reject loan without transactions', async () => {
        const borrower = createBorrower(borrowerAddress);
        createLoan('loan-no-tx', borrower.id, borrowerAddress, 100000);

        await expect(
          handleCalculateDscr(createMockAdvanceData(), {
            action: 'calculate_dscr',
            loan_id: 'loan-no-tx',
          })
        ).rejects.toThrow('No transactions available');
      });

      it('should reject non-existent loan', async () => {
        await expect(
          handleCalculateDscr(createMockAdvanceData(), {
            action: 'calculate_dscr',
            loan_id: 'non-existent',
          })
        ).rejects.toThrow('Loan not found');
      });
    });

    describe('handleInspectDscr', () => {
      it('should return DSCR history', async () => {
        const borrower = createBorrower(borrowerAddress);
        createLoan('loan-dscr-history', borrower.id, borrowerAddress, 100000);

        const result = await handleInspectDscr({
          type: 'dscr',
          params: { loan_id: 'loan-dscr-history' },
        });

        expect(result).toHaveProperty('loan_id', 'loan-dscr-history');
        expect(result).toHaveProperty('calculation_history');
      });
    });
  });

  describe('Stats Handler', () => {
    it('should return database statistics', async () => {
      // Add some test data
      const borrower = createBorrower('0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
      createLoan('loan-stats', borrower.id, borrower.wallet_address, 100000);

      const result = await handleInspectStats({
        type: 'stats',
        params: {},
      });

      expect(result).toHaveProperty('statistics');
      expect((result as any).statistics.total_borrowers).toBe(1);
      expect((result as any).statistics.total_loans).toBe(1);
    });
  });

  describe('Rate Change Approval Handlers', () => {
    const borrowerAddress = '0xcccccccccccccccccccccccccccccccccccccccc';

    describe('handleApproveRateChange', () => {
      it('should approve a pending rate change', async () => {
        const borrower = createBorrower(borrowerAddress);
        const loanId = 'loan-approve-handler-test';
        createLoan(loanId, borrower.id, borrowerAddress, 100000);

        // Create a pending rate change
        const pendingChange = createPendingRateChange(
          loanId,
          5.0,
          6.5,
          1.35,
          'Test rate change',
          'system'
        );

        const result = await handleApproveRateChange(createMockAdvanceData(), {
          action: 'approve_rate_change',
          change_id: pendingChange.id,
          approved_by: 'admin@example.com',
        });

        expect(result.status).toBe('accept');
        expect(result.response).toHaveProperty('success', true);
        expect(result.response).toHaveProperty('change_id', pendingChange.id);
        expect(result.response).toHaveProperty('approved_by', 'admin@example.com');

        // Verify the change was approved
        const updated = getPendingRateChangeById(pendingChange.id);
        expect(updated!.status).toBe('approved');

        // Verify loan rate was updated
        const loan = getLoanById(loanId);
        expect(loan!.interest_rate).toBe(6.5);
      });

      it('should reject invalid change_id', async () => {
        await expect(
          handleApproveRateChange(createMockAdvanceData(), {
            action: 'approve_rate_change',
            change_id: 'invalid' as any,
            approved_by: 'admin@example.com',
          })
        ).rejects.toThrow('Valid change_id is required');
      });

      it('should reject missing approved_by', async () => {
        await expect(
          handleApproveRateChange(createMockAdvanceData(), {
            action: 'approve_rate_change',
            change_id: 1,
          } as any)
        ).rejects.toThrow('approved_by is required');
      });

      it('should reject non-existent rate change', async () => {
        await expect(
          handleApproveRateChange(createMockAdvanceData(), {
            action: 'approve_rate_change',
            change_id: 99999,
            approved_by: 'admin@example.com',
          })
        ).rejects.toThrow('not found or already resolved');
      });

      it('should reject already resolved rate change', async () => {
        const borrower = createBorrower('0xdddddddddddddddddddddddddddddddddddddddd');
        const loanId = 'loan-double-approve-test';
        createLoan(loanId, borrower.id, borrower.wallet_address, 100000);

        const pendingChange = createPendingRateChange(
          loanId,
          5.0,
          6.5,
          1.35,
          'Test',
          'system'
        );

        // First approval
        await handleApproveRateChange(createMockAdvanceData(), {
          action: 'approve_rate_change',
          change_id: pendingChange.id,
          approved_by: 'admin1@example.com',
        });

        // Second approval attempt should fail
        await expect(
          handleApproveRateChange(createMockAdvanceData(), {
            action: 'approve_rate_change',
            change_id: pendingChange.id,
            approved_by: 'admin2@example.com',
          })
        ).rejects.toThrow('not found or already resolved');
      });
    });

    describe('handleRejectRateChange', () => {
      it('should reject a pending rate change', async () => {
        const borrower = createBorrower('0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee');
        const loanId = 'loan-reject-handler-test';
        createLoan(loanId, borrower.id, borrower.wallet_address, 100000);

        const pendingChange = createPendingRateChange(
          loanId,
          5.0,
          6.5,
          1.35,
          'Test rate change',
          'system'
        );

        const result = await handleRejectRateChange(createMockAdvanceData(), {
          action: 'reject_rate_change',
          change_id: pendingChange.id,
          approved_by: 'admin@example.com',
        });

        expect(result.status).toBe('accept');
        expect(result.response).toHaveProperty('success', true);
        expect(result.response).toHaveProperty('change_id', pendingChange.id);
        expect(result.response).toHaveProperty('rejected_by', 'admin@example.com');

        // Verify the change was rejected
        const updated = getPendingRateChangeById(pendingChange.id);
        expect(updated!.status).toBe('rejected');

        // Verify loan status is back to pending
        const loan = getLoanById(loanId);
        expect(loan!.status).toBe('pending');
      });

      it('should reject invalid change_id', async () => {
        await expect(
          handleRejectRateChange(createMockAdvanceData(), {
            action: 'reject_rate_change',
            change_id: null as any,
            approved_by: 'admin@example.com',
          })
        ).rejects.toThrow('Valid change_id is required');
      });

      it('should reject missing approved_by', async () => {
        await expect(
          handleRejectRateChange(createMockAdvanceData(), {
            action: 'reject_rate_change',
            change_id: 1,
            approved_by: '',
          })
        ).rejects.toThrow('approved_by is required');
      });

      it('should reject non-existent rate change', async () => {
        await expect(
          handleRejectRateChange(createMockAdvanceData(), {
            action: 'reject_rate_change',
            change_id: 99999,
            approved_by: 'admin@example.com',
          })
        ).rejects.toThrow('not found or already resolved');
      });
    });

    describe('handleInspectPendingRateChanges', () => {
      it('should return pending rate changes for a loan', async () => {
        const borrower = createBorrower('0xfffffffffffffffffffffffffffffffffffffffF');
        const loanId = 'loan-inspect-pending-test';
        createLoan(loanId, borrower.id, borrower.wallet_address, 100000);

        createPendingRateChange(loanId, 5.0, 6.5, 1.35, 'Test reason', 'system');

        const result = await handleInspectPendingRateChanges({
          type: 'pending_rate_changes',
          params: { loan_id: loanId },
        });

        expect(result).toHaveProperty('pending_rate_changes');
        expect((result as any).pending_rate_changes).toHaveLength(1);
        expect((result as any).pending_rate_changes[0].loan_id).toBe(loanId);
        expect(result).toHaveProperty('total_pending', 1);
        expect(result).toHaveProperty('approval_required');
      });

      it('should return all pending rate changes when no loan_id specified', async () => {
        const borrower1 = createBorrower('0x1111111111111111111111111111111111111111');
        const borrower2 = createBorrower('0x2222222222222222222222222222222222222222');
        const loanId1 = 'loan-all-pending-1';
        const loanId2 = 'loan-all-pending-2';
        createLoan(loanId1, borrower1.id, borrower1.wallet_address, 100000);
        createLoan(loanId2, borrower2.id, borrower2.wallet_address, 200000);

        createPendingRateChange(loanId1, 5.0, 6.0, 1.30, 'Reason 1', 'system');
        createPendingRateChange(loanId2, 4.0, 5.5, 1.40, 'Reason 2', 'system');

        const result = await handleInspectPendingRateChanges({
          type: 'pending_rate_changes',
          params: {},
        });

        expect(result).toHaveProperty('pending_rate_changes');
        // Filter to only our test loans since db state may persist
        const ourChanges = (result as any).pending_rate_changes.filter(
          (c: any) => c.loan_id === loanId1 || c.loan_id === loanId2
        );
        expect(ourChanges).toHaveLength(2);
      });

      it('should return empty array when no pending changes exist', async () => {
        const result = await handleInspectPendingRateChanges({
          type: 'pending_rate_changes',
          params: { loan_id: 'non-existent-loan' },
        });

        expect(result).toHaveProperty('pending_rate_changes');
        expect((result as any).pending_rate_changes).toHaveLength(0);
        expect((result as any).total_pending).toBe(0);
      });
    });
  });
});
