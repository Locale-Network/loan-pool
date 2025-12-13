import createClient from 'openapi-fetch';
import { components, paths } from './schema';
import { initDatabase } from './db';
import { createRouter, RouteConfig } from './router';
import {
  handleRegisterBorrower,
  handleUpdateKyc,
  handleInspectBorrower,
  handleCreateLoan,
  handleUpdateLoanStatus,
  handleInspectLoan,
  handleApproveLoan,
  handleDisburseLoan,
  handleSyncTransactions,
  handleInspectTransactions,
  handleCalculateDscr,
  handleInspectDscr,
  handleApproveRateChange,
  handleRejectRateChange,
  handleInspectPendingRateChanges,
  handleSubmitDataProof,
  handleInspectProof,
  handleInspectVerifiedDscr,
  handleInspectStats,
  // zkFetch handlers (zkFetch + Cartesi DSCR verification)
  handleVerifyDscrZkFetch,
  handleInspectZkFetch,
  initZkFetchTable,
} from './handlers';

type AdvanceRequestData = components['schemas']['Advance'];
type InspectRequestData = components['schemas']['Inspect'];
type RequestHandlerResult = components['schemas']['Finish']['status'];
type RollupsRequest = components['schemas']['RollupRequest'];

const rollupServer = process.env.ROLLUP_HTTP_SERVER_URL;
console.log('HTTP rollup_server url is ' + rollupServer);

/**
 * Route configuration for all handlers.
 */
const routeConfig: RouteConfig = {
  advance: {
    // Borrower actions
    register_borrower: handleRegisterBorrower,
    update_kyc: handleUpdateKyc,

    // Loan actions
    create_loan: handleCreateLoan,
    update_loan_status: handleUpdateLoanStatus,
    approve_loan: handleApproveLoan,
    disburse_loan: handleDisburseLoan,

    // Transaction actions
    sync_transactions: handleSyncTransactions,

    // DSCR actions
    calculate_dscr: handleCalculateDscr,

    // Rate change approval actions
    approve_rate_change: handleApproveRateChange,
    reject_rate_change: handleRejectRateChange,

    // Proof actions
    submit_data_proof: handleSubmitDataProof,

    // zkFetch actions (zkFetch + Cartesi DSCR verification)
    verify_dscr_zkfetch: handleVerifyDscrZkFetch,
  },
  inspect: {
    // Borrower queries
    borrower: handleInspectBorrower,

    // Loan queries
    loan: handleInspectLoan,

    // Transaction queries
    transactions: handleInspectTransactions,

    // DSCR queries
    dscr: handleInspectDscr,

    // Pending rate changes queries
    pending_rate_changes: handleInspectPendingRateChanges,

    // Proof queries
    proof: handleInspectProof,
    verified_dscr: handleInspectVerifiedDscr,

    // zkFetch queries
    zkfetch: handleInspectZkFetch,

    // Stats queries
    stats: handleInspectStats,
  },
};

const main = async () => {
  // Initialize database
  console.log('Initializing database...');
  await initDatabase();
  console.log('Database initialized');

  // Initialize zkFetch table
  initZkFetchTable();
  console.log('zkFetch table initialized');

  // Create router with all handlers
  const router = createRouter(routeConfig);

  const { POST } = createClient<paths>({ baseUrl: rollupServer });
  let status: RequestHandlerResult = 'accept';

  console.log('Starting main loop...');

  while (true) {
    const { response } = await POST('/finish', {
      body: { status },
      parseAs: 'text',
    });

    if (response.status === 200) {
      const data = (await response.json()) as RollupsRequest;
      switch (data.request_type) {
        case 'advance_state':
          status = await router.handleAdvance(data.data as AdvanceRequestData);
          break;
        case 'inspect_state':
          await router.handleInspect(data.data as InspectRequestData);
          status = 'accept';
          break;
      }
    } else if (response.status === 202) {
      console.log(await response.text());
    }
  }
};

main().catch(e => {
  console.error('Fatal error:', e);
  process.exit(1);
});
