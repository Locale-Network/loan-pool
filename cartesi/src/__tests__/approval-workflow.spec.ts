import {
  initDatabase,
  closeDatabase,
  createBorrower,
  createLoan,
  createPendingRateChange,
  getPendingRateChanges,
  getPendingRateChangeById,
  approveRateChange,
  rejectRateChange,
  getLoanById,
  updateLoanStatus,
} from '../db';

describe('Approval Workflow', () => {
  beforeEach(async () => {
    closeDatabase();
    await initDatabase();
  });

  afterEach(() => {
    closeDatabase();
  });

  describe('Pending Rate Changes', () => {
    it('should create a pending rate change', () => {
      const borrower = createBorrower('0xApprovalCreate1111111111111111111111111');
      const loanId = 'loan-create-test';
      createLoan(loanId, borrower.id, borrower.wallet_address, 10000);

      const change = createPendingRateChange(
        loanId,
        5.0, // current rate
        6.5, // proposed rate
        1.35, // dscr value
        'DSCR calculation triggered rate change',
        'system'
      );

      expect(change).toBeDefined();
      expect(change.id).toBeGreaterThan(0);
      expect(change.loan_id).toBe(loanId);
      expect(change.current_rate).toBe(5.0);
      expect(change.proposed_rate).toBe(6.5);
      expect(change.dscr_value).toBe(1.35);
      expect(change.status).toBe('pending');
      expect(change.requested_by).toBe('system');
    });

    it('should get pending rate changes for a loan', () => {
      const borrower = createBorrower('0xApprovalGet11111111111111111111111111111');
      const loanId = 'loan-get-pending-test';
      createLoan(loanId, borrower.id, borrower.wallet_address, 10000);

      createPendingRateChange(loanId, 5.0, 6.5, 1.35, 'Test reason 1', 'system');
      createPendingRateChange(loanId, 6.5, 7.0, 1.28, 'Test reason 2', 'admin');

      const changes = getPendingRateChanges(loanId);

      // Filter to only this loan's changes (db state may persist)
      const ourChanges = changes.filter(c => c.loan_id === loanId);
      expect(ourChanges).toHaveLength(2);

      // Check that both rates are present (don't assume order)
      const rates = ourChanges.map(c => c.proposed_rate);
      expect(rates).toContain(6.5);
      expect(rates).toContain(7.0);
    });

    it('should get all pending rate changes when no loan_id specified', () => {
      const borrower = createBorrower('0xApprovalAll111111111111111111111111111111');
      const loanId1 = 'loan-all-test-1';
      const loanId2 = 'loan-all-test-2';
      createLoan(loanId1, borrower.id, borrower.wallet_address, 10000);
      createLoan(loanId2, borrower.id, borrower.wallet_address, 20000);

      createPendingRateChange(loanId1, 5.0, 6.5, 1.35, 'Reason 1', 'system');
      createPendingRateChange(loanId2, 4.0, 5.5, 1.40, 'Reason 2', 'system');

      const allChanges = getPendingRateChanges();

      // Filter to only these test's loan IDs since db state persists across tests
      const ourChanges = allChanges.filter(c => c.loan_id === loanId1 || c.loan_id === loanId2);
      expect(ourChanges).toHaveLength(2);
    });

    it('should get pending rate change by id', () => {
      const borrower = createBorrower('0xApprovalById1111111111111111111111111111');
      const loanId = 'loan-byid-test';
      createLoan(loanId, borrower.id, borrower.wallet_address, 10000);

      const created = createPendingRateChange(loanId, 5.0, 6.5, 1.35, 'Test', 'system');

      const fetched = getPendingRateChangeById(created.id);

      expect(fetched).toBeDefined();
      expect(fetched!.id).toBe(created.id);
      expect(fetched!.loan_id).toBe(loanId);
    });

    it('should return null for non-existent rate change id', () => {
      const result = getPendingRateChangeById(99999);
      expect(result).toBeNull();
    });
  });

  describe('Approve Rate Change', () => {
    it('should approve a pending rate change and update loan', () => {
      const borrower = createBorrower('0xApproveTest11111111111111111111111111111');
      const loanId = 'loan-approve-test';
      createLoan(loanId, borrower.id, borrower.wallet_address, 10000);

      const change = createPendingRateChange(loanId, 5.0, 6.5, 1.35, 'Test', 'system');

      const result = approveRateChange(change.id, 'admin@example.com');

      expect(result).toBe(true);

      // Verify the change is updated
      const updated = getPendingRateChangeById(change.id);
      expect(updated!.status).toBe('approved');
      expect(updated!.approved_by).toBe('admin@example.com');
      expect(updated!.resolved_at).toBeDefined();

      // Verify loan rate is updated
      const loan = getLoanById(loanId);
      expect(loan!.interest_rate).toBe(6.5);
    });

    it('should not approve already resolved rate change', () => {
      const borrower = createBorrower('0xApproveResolved1111111111111111111111111');
      const loanId = 'loan-approve-resolved';
      createLoan(loanId, borrower.id, borrower.wallet_address, 10000);

      const change = createPendingRateChange(loanId, 5.0, 6.5, 1.35, 'Test', 'system');

      // First approval
      approveRateChange(change.id, 'admin1@example.com');

      // Second approval attempt should fail
      const result = approveRateChange(change.id, 'admin2@example.com');

      expect(result).toBe(false);
    });

    it('should return false for non-existent rate change', () => {
      const result = approveRateChange(99999, 'admin@example.com');
      expect(result).toBe(false);
    });
  });

  describe('Reject Rate Change', () => {
    it('should reject a pending rate change', () => {
      const borrower = createBorrower('0xRejectTest111111111111111111111111111111');
      const loanId = 'loan-reject-test';
      createLoan(loanId, borrower.id, borrower.wallet_address, 10000);

      const change = createPendingRateChange(loanId, 5.0, 6.5, 1.35, 'Test', 'system');

      const result = rejectRateChange(change.id, 'admin@example.com');

      expect(result).toBe(true);

      // Verify the change is updated
      const updated = getPendingRateChangeById(change.id);
      expect(updated!.status).toBe('rejected');
      expect(updated!.approved_by).toBe('admin@example.com');
      expect(updated!.resolved_at).toBeDefined();

      // Verify loan status is updated back to pending
      const loan = getLoanById(loanId);
      expect(loan!.status).toBe('pending');
    });

    it('should not reject already resolved rate change', () => {
      const borrower = createBorrower('0xRejectResolved11111111111111111111111111');
      const loanId = 'loan-reject-resolved';
      createLoan(loanId, borrower.id, borrower.wallet_address, 10000);

      const change = createPendingRateChange(loanId, 5.0, 6.5, 1.35, 'Test', 'system');

      // First rejection
      rejectRateChange(change.id, 'admin1@example.com');

      // Second rejection attempt should fail
      const result = rejectRateChange(change.id, 'admin2@example.com');

      expect(result).toBe(false);
    });
  });

  describe('Rate Change Integration', () => {
    it('should only return pending rate changes (not approved or rejected)', () => {
      const borrower = createBorrower('0xIntegration1111111111111111111111111111');
      const loan1 = 'loan-integration-1';
      const loan2 = 'loan-integration-2';
      const loan3 = 'loan-integration-3';

      createLoan(loan1, borrower.id, borrower.wallet_address, 10000);
      createLoan(loan2, borrower.id, borrower.wallet_address, 20000);
      createLoan(loan3, borrower.id, borrower.wallet_address, 30000);

      const change1 = createPendingRateChange(loan1, 5.0, 6.0, 1.30, 'Test 1', 'system');
      const change2 = createPendingRateChange(loan2, 5.0, 6.5, 1.25, 'Test 2', 'system');
      const change3 = createPendingRateChange(loan3, 5.0, 7.0, 1.20, 'Test 3', 'system');

      // Approve one
      approveRateChange(change1.id, 'admin');

      // Reject one
      rejectRateChange(change3.id, 'admin');

      // Filter to these specific loans since db state persists
      const pending = getPendingRateChanges().filter(
        c => c.loan_id === loan1 || c.loan_id === loan2 || c.loan_id === loan3
      );

      // Only the pending one (loan2) should remain
      expect(pending).toHaveLength(1);
      expect(pending[0]!.loan_id).toBe(loan2);
    });
  });
});
