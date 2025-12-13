// Borrower handlers
export { handleRegisterBorrower, handleUpdateKyc, handleInspectBorrower } from './borrower';

// Loan handlers
export {
  handleCreateLoan,
  handleUpdateLoanStatus,
  handleInspectLoan,
  handleApproveLoan,
  handleDisburseLoan,
} from './loan';

// Transaction handlers
export { handleSyncTransactions, handleInspectTransactions } from './transaction';

// DSCR handlers
export {
  handleCalculateDscr,
  handleInspectDscr,
  handleApproveRateChange,
  handleRejectRateChange,
  handleInspectPendingRateChanges,
} from './dscr';

// Proof handlers
export {
  handleSubmitDataProof,
  handleInspectProof,
  handleInspectVerifiedDscr,
} from './proof';

// zkFetch handlers (zkFetch + Cartesi DSCR verification)
export {
  handleVerifyDscrZkFetch,
  handleInspectZkFetch,
  initZkFetchTable,
  getZkFetchVerifications,
  getLatestVerifiedDscr,
} from './zkfetch';

// Stats handlers
export { handleInspectStats } from './stats';
