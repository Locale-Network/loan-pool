import Decimal from 'decimal.js';
import { AdvanceHandler, InspectHandler, InspectQuery, AdvanceRequestData } from '../router';
import { getDatabase, getLoanById, getBorrowerByAddress, updateLoanDscr, saveDscrCalculation } from '../db';
import { getDefaultDscrTarget } from '../config';
import { createHash } from 'crypto';

/**
 * zkFetch DSCR Verification Handler
 *
 * This handler processes DSCR verification requests that include zkFetch proofs
 * from the Reclaim Protocol. The zkFetch proof attests that the transaction data
 * came from an authentic Plaid API response.
 *
 * Flow:
 * 1. Lending platform fetches transactions via zkFetch (generates ZK proof)
 * 2. Platform calculates DSCR and submits to Cartesi with zkFetch proof
 * 3. This handler verifies the proof and stores the verified DSCR
 * 4. Cartesi emits a NOTICE that can be relayed to SimpleLoanPool.handleNotice()
 *
 * See: loan-pool/memory-bank/ZKFETCH_ARCHITECTURE.md
 */

/**
 * Payload for zkFetch DSCR verification
 */
interface ZkFetchDscrPayload {
  action: 'verify_dscr_zkfetch';
  loanId: string;
  borrowerAddress: string;
  data: {
    transactionCount: number;
    monthlyNoi: number; // Scaled by 100
    monthlyDebtService: number; // Scaled by 100
    dscrValue: number; // Scaled by 10000
    zkFetchProofHash: string;
    calculatedAt: number; // Unix timestamp
  };
  zkProof: {
    identifier: string;
    claimData: {
      provider: string;
      parameters: string;
      context: string;
    };
    signatures: string[];
  } | null;
}

/**
 * zkFetch proof verification result stored in database
 */
export interface ZkFetchVerification {
  id: number;
  loan_id: string;
  borrower_address: string;
  dscr_value: number;
  monthly_noi: number;
  monthly_debt_service: number;
  transaction_count: number;
  zkfetch_proof_hash: string;
  zkfetch_identifier: string | null;
  zkfetch_provider: string | null;
  verified: boolean;
  verified_at: string;
  created_at: string;
}

/**
 * Initialize the zkFetch verifications table
 */
export function initZkFetchTable(): void {
  const database = getDatabase();

  database.run(`
    CREATE TABLE IF NOT EXISTS zkfetch_verifications (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      loan_id TEXT NOT NULL,
      borrower_address TEXT NOT NULL,
      dscr_value REAL NOT NULL,
      monthly_noi REAL NOT NULL,
      monthly_debt_service REAL NOT NULL,
      transaction_count INTEGER NOT NULL,
      zkfetch_proof_hash TEXT NOT NULL,
      zkfetch_identifier TEXT,
      zkfetch_provider TEXT,
      verified INTEGER DEFAULT 0,
      verified_at TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (loan_id) REFERENCES loans(id)
    );

    CREATE INDEX IF NOT EXISTS idx_zkfetch_loan_id ON zkfetch_verifications(loan_id);
    CREATE INDEX IF NOT EXISTS idx_zkfetch_borrower ON zkfetch_verifications(borrower_address);
    CREATE INDEX IF NOT EXISTS idx_zkfetch_proof_hash ON zkfetch_verifications(zkfetch_proof_hash);
  `);

  console.log('zkFetch verifications table initialized');
}

/**
 * Save a zkFetch verification to the database
 */
function saveZkFetchVerification(params: {
  loanId: string;
  borrowerAddress: string;
  dscrValue: number;
  monthlyNoi: number;
  monthlyDebtService: number;
  transactionCount: number;
  zkFetchProofHash: string;
  zkFetchIdentifier?: string;
  zkFetchProvider?: string;
  verified: boolean;
}): ZkFetchVerification {
  const database = getDatabase();
  const now = new Date().toISOString();

  database.run(
    `INSERT INTO zkfetch_verifications
     (loan_id, borrower_address, dscr_value, monthly_noi, monthly_debt_service,
      transaction_count, zkfetch_proof_hash, zkfetch_identifier, zkfetch_provider,
      verified, verified_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      params.loanId,
      params.borrowerAddress.toLowerCase(),
      params.dscrValue,
      params.monthlyNoi,
      params.monthlyDebtService,
      params.transactionCount,
      params.zkFetchProofHash,
      params.zkFetchIdentifier || null,
      params.zkFetchProvider || null,
      params.verified ? 1 : 0,
      params.verified ? now : null,
      now,
    ]
  );

  const result = database.exec('SELECT last_insert_rowid()');
  const id = (result[0]?.values[0]?.[0] as number) ?? 0;

  return {
    id,
    loan_id: params.loanId,
    borrower_address: params.borrowerAddress.toLowerCase(),
    dscr_value: params.dscrValue,
    monthly_noi: params.monthlyNoi,
    monthly_debt_service: params.monthlyDebtService,
    transaction_count: params.transactionCount,
    zkfetch_proof_hash: params.zkFetchProofHash,
    zkfetch_identifier: params.zkFetchIdentifier || null,
    zkfetch_provider: params.zkFetchProvider || null,
    verified: params.verified,
    verified_at: params.verified ? now : '',
    created_at: now,
  };
}

/**
 * Get zkFetch verification history for a loan
 */
export function getZkFetchVerifications(loanId: string): ZkFetchVerification[] {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, loan_id, borrower_address, dscr_value, monthly_noi, monthly_debt_service,
     transaction_count, zkfetch_proof_hash, zkfetch_identifier, zkfetch_provider,
     verified, verified_at, created_at
     FROM zkfetch_verifications WHERE loan_id = ? ORDER BY created_at DESC`,
    [loanId]
  );

  const firstResult = result[0];
  if (!firstResult) {
    return [];
  }

  return firstResult.values.map((row: unknown[]) => ({
    id: row[0] as number,
    loan_id: row[1] as string,
    borrower_address: row[2] as string,
    dscr_value: row[3] as number,
    monthly_noi: row[4] as number,
    monthly_debt_service: row[5] as number,
    transaction_count: row[6] as number,
    zkfetch_proof_hash: row[7] as string,
    zkfetch_identifier: row[8] as string | null,
    zkfetch_provider: row[9] as string | null,
    verified: Boolean(row[10]),
    verified_at: row[11] as string,
    created_at: row[12] as string,
  }));
}

/**
 * Get the latest verified DSCR for a borrower
 */
export function getLatestVerifiedDscr(borrowerAddress: string): ZkFetchVerification | null {
  const database = getDatabase();
  const result = database.exec(
    `SELECT id, loan_id, borrower_address, dscr_value, monthly_noi, monthly_debt_service,
     transaction_count, zkfetch_proof_hash, zkfetch_identifier, zkfetch_provider,
     verified, verified_at, created_at
     FROM zkfetch_verifications
     WHERE borrower_address = ? AND verified = 1
     ORDER BY created_at DESC LIMIT 1`,
    [borrowerAddress.toLowerCase()]
  );

  const firstResult = result[0];
  const firstRow = firstResult?.values[0];

  if (!firstRow) {
    return null;
  }

  return {
    id: firstRow[0] as number,
    loan_id: firstRow[1] as string,
    borrower_address: firstRow[2] as string,
    dscr_value: firstRow[3] as number,
    monthly_noi: firstRow[4] as number,
    monthly_debt_service: firstRow[5] as number,
    transaction_count: firstRow[6] as number,
    zkfetch_proof_hash: firstRow[7] as string,
    zkfetch_identifier: firstRow[8] as string | null,
    zkfetch_provider: firstRow[9] as string | null,
    verified: Boolean(firstRow[10]),
    verified_at: firstRow[11] as string,
    created_at: firstRow[12] as string,
  };
}

/**
 * Verify a zkFetch proof
 *
 * In production, this would validate the Reclaim Protocol proof signatures.
 * For now, we perform basic validation and trust the proof structure.
 */
function verifyZkFetchProof(proof: ZkFetchDscrPayload['zkProof']): {
  valid: boolean;
  error?: string;
} {
  if (!proof) {
    // No proof provided - could be a legacy request or testing
    return { valid: false, error: 'No zkFetch proof provided' };
  }

  // Basic validation
  if (!proof.identifier) {
    return { valid: false, error: 'Missing proof identifier' };
  }

  if (!proof.claimData?.provider) {
    return { valid: false, error: 'Missing claim provider' };
  }

  if (!proof.signatures || proof.signatures.length === 0) {
    return { valid: false, error: 'Missing proof signatures' };
  }

  // TODO: In production, verify signatures against Reclaim Protocol witnesses
  // This would involve:
  // 1. Fetching the witness public keys
  // 2. Verifying each signature against the claim data
  // 3. Checking that enough witnesses have signed (threshold)

  return { valid: true };
}

/**
 * Handle zkFetch DSCR verification request
 *
 * This handler:
 * 1. Validates the zkFetch proof
 * 2. Stores the verified DSCR in the database
 * 3. Updates the loan status
 * 4. Returns a response that can be used to emit a NOTICE
 */
export const handleVerifyDscrZkFetch: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const input = payload as ZkFetchDscrPayload;
  const { loanId, borrowerAddress, data: dscrData, zkProof } = input;

  // Validate required fields
  if (!loanId || typeof loanId !== 'string') {
    throw new Error('Valid loanId is required');
  }

  if (!borrowerAddress || typeof borrowerAddress !== 'string') {
    throw new Error('Valid borrowerAddress is required');
  }

  if (!dscrData || !dscrData.zkFetchProofHash) {
    throw new Error('Valid DSCR data with zkFetch proof hash is required');
  }

  // Check if loan exists
  const loan = getLoanById(loanId);
  if (!loan) {
    throw new Error(`Loan not found: ${loanId}`);
  }

  // Check if borrower matches
  if (loan.borrower_address.toLowerCase() !== borrowerAddress.toLowerCase()) {
    throw new Error('Borrower address does not match loan');
  }

  // Verify the zkFetch proof
  const proofVerification = verifyZkFetchProof(zkProof);

  // Unscale the DSCR values
  const dscrValue = dscrData.dscrValue / 10000;
  const monthlyNoi = dscrData.monthlyNoi / 100;
  const monthlyDebtService = dscrData.monthlyDebtService / 100;

  // Save the verification to the database
  const verification = saveZkFetchVerification({
    loanId,
    borrowerAddress,
    dscrValue,
    monthlyNoi,
    monthlyDebtService,
    transactionCount: dscrData.transactionCount,
    zkFetchProofHash: dscrData.zkFetchProofHash,
    zkFetchIdentifier: zkProof?.identifier,
    zkFetchProvider: zkProof?.claimData?.provider,
    verified: proofVerification.valid,
  });

  // Determine if DSCR meets threshold
  const targetDscr = getDefaultDscrTarget();
  const meetsThreshold = dscrValue >= targetDscr;

  // Update loan status based on DSCR
  if (proofVerification.valid) {
    const newStatus = meetsThreshold ? 'dscr_verified' : 'dscr_below_threshold';
    updateLoanDscr(loanId, loan.interest_rate || 0, dscrValue, newStatus);

    // Also save to DSCR calculations table for history
    const borrower = getBorrowerByAddress(borrowerAddress);
    if (borrower) {
      saveDscrCalculation(
        loanId,
        borrower.id,
        dscrValue,
        monthlyNoi,
        monthlyDebtService,
        dscrData.zkFetchProofHash
      );
    }

    console.log(
      `[zkFetch] DSCR verified for loan ${loanId}: ${dscrValue.toFixed(4)}, ` +
        `meets threshold: ${meetsThreshold}, proof: ${dscrData.zkFetchProofHash.slice(0, 16)}...`
    );
  } else {
    console.warn(
      `[zkFetch] Proof verification failed for loan ${loanId}: ${proofVerification.error}`
    );
  }

  // Return response for NOTICE emission
  // This data will be relayed to SimpleLoanPool.handleNotice()
  return {
    status: 'accept',
    response: {
      action: 'verify_dscr_zkfetch',
      success: proofVerification.valid,
      notice_type: 'dscr_verified',
      loan_id: loanId,
      borrower_address: borrowerAddress,
      dscr_value: new Decimal(dscrValue).toFixed(4),
      monthly_noi: new Decimal(monthlyNoi).toFixed(2),
      monthly_debt_service: new Decimal(monthlyDebtService).toFixed(2),
      meets_threshold: meetsThreshold,
      target_dscr: targetDscr,
      transaction_count: dscrData.transactionCount,
      zkfetch_proof_hash: dscrData.zkFetchProofHash,
      proof_verified: proofVerification.valid,
      proof_error: proofVerification.error,
      verification_id: verification.id,
      calculated_at: dscrData.calculatedAt,
    },
  };
};

/**
 * Handle inspect query for zkFetch verifications
 */
export const handleInspectZkFetch: InspectHandler = async (query: InspectQuery) => {
  const { params } = query;

  if (params.borrower_address) {
    const latest = getLatestVerifiedDscr(params.borrower_address);
    if (!latest) {
      return {
        borrower_address: params.borrower_address,
        has_verified_dscr: false,
        message: 'No verified DSCR found for borrower',
      };
    }

    return {
      borrower_address: params.borrower_address,
      has_verified_dscr: true,
      latest_verification: {
        loan_id: latest.loan_id,
        dscr_value: new Decimal(latest.dscr_value).toFixed(4),
        monthly_noi: new Decimal(latest.monthly_noi).toFixed(2),
        monthly_debt_service: new Decimal(latest.monthly_debt_service).toFixed(2),
        transaction_count: latest.transaction_count,
        zkfetch_proof_hash: latest.zkfetch_proof_hash,
        verified_at: latest.verified_at,
      },
    };
  }

  if (params.loan_id) {
    const verifications = getZkFetchVerifications(params.loan_id);
    return {
      loan_id: params.loan_id,
      verification_count: verifications.length,
      verifications: verifications.map(v => ({
        id: v.id,
        dscr_value: new Decimal(v.dscr_value).toFixed(4),
        monthly_noi: new Decimal(v.monthly_noi).toFixed(2),
        transaction_count: v.transaction_count,
        zkfetch_proof_hash: v.zkfetch_proof_hash,
        verified: v.verified,
        verified_at: v.verified_at,
        created_at: v.created_at,
      })),
    };
  }

  return {
    error: 'Either loan_id or borrower_address parameter required',
  };
};
