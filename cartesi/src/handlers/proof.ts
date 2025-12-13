import { AdvanceHandler, InspectHandler, InspectQuery, AdvanceRequestData } from '../router';
import {
  getBorrowerByAddress,
  createBorrower,
  saveTransactionProof,
  saveIdentityProof,
  getDataProofById,
  getProofsByBorrower,
  getLatestTransactionProof,
  markProofVerified,
  isProofValid,
  updateBorrowerKycLevel,
  TransactionProofInput,
  IdentityProofInput,
} from '../db';
import { createHmac } from 'crypto';

/**
 * Secret key for proof verification - must match the backend
 * In production, this should be securely shared between backend and Cartesi
 */
const PROOF_SIGNING_KEY = process.env.ZKPROOF_SIGNING_KEY || 'development-key-replace-in-production';

/**
 * Verify an HMAC signature
 */
function verifySignature(data: string, signature: string): boolean {
  const expectedSignature = createHmac('sha256', PROOF_SIGNING_KEY)
    .update(data)
    .digest('hex');
  return expectedSignature === signature;
}

/**
 * Payload for submitting a transaction proof
 */
interface SubmitTransactionProofPayload {
  action: 'submit_data_proof';
  proof: {
    proofId: string;
    dataType: 'transactions';
    dataHash: string;
    timestamp: number;
    itemIdHash: string;
    borrowerAddress: string;
    loanApplicationId: string;
    signature: string;
    expiresAt: number;
    summary: {
      transactionCount: number;
      windowStart: string;
      windowEnd: string;
      netIncome: number;
      monthCount: number;
      avgMonthlyIncome: number;
    };
  };
  transactionHashes?: string[];
}

/**
 * Payload for submitting an identity proof
 */
interface SubmitIdentityProofPayload {
  action: 'submit_data_proof';
  proof: {
    proofId: string;
    dataType: 'identity';
    dataHash: string;
    timestamp: number;
    itemIdHash: string;
    borrowerAddress: string;
    loanApplicationId: string;
    signature: string;
    expiresAt: number;
    verification: {
      verified: boolean;
      kycLevel: 1 | 2;
      status: string;
      verificationDate: string;
    };
  };
}

type SubmitProofPayload = SubmitTransactionProofPayload | SubmitIdentityProofPayload;

/**
 * Handle submission of a data proof (transactions or identity)
 */
export const handleSubmitDataProof: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const proofPayload = payload as SubmitProofPayload;
  const { proof } = proofPayload;

  // Validate required fields
  if (!proof.proofId || !proof.dataType || !proof.dataHash || !proof.signature) {
    throw new Error('Missing required proof fields');
  }

  if (!proof.borrowerAddress) {
    throw new Error('Borrower address is required');
  }

  // Verify signature
  const { signature, ...proofDataWithoutSig } = proof;
  const isValid = verifySignature(JSON.stringify(proofDataWithoutSig), signature);

  if (!isValid) {
    throw new Error('Invalid proof signature');
  }

  // Check expiration
  if (proof.expiresAt < Date.now()) {
    throw new Error('Proof has expired');
  }

  // Get or create borrower
  let borrower = getBorrowerByAddress(proof.borrowerAddress);
  if (!borrower) {
    borrower = createBorrower(proof.borrowerAddress);
  }

  // Store proof based on type
  if (proof.dataType === 'transactions') {
    const txProof = proof as SubmitTransactionProofPayload['proof'];
    const input: TransactionProofInput = {
      proof_id: txProof.proofId,
      borrower_id: borrower.id,
      loan_id: txProof.loanApplicationId,
      data_hash: txProof.dataHash,
      signature: txProof.signature,
      transaction_count: txProof.summary.transactionCount,
      window_start: txProof.summary.windowStart,
      window_end: txProof.summary.windowEnd,
      net_income: txProof.summary.netIncome,
      avg_monthly_income: txProof.summary.avgMonthlyIncome,
      expires_at: new Date(txProof.expiresAt).toISOString(),
    };

    const savedProof = saveTransactionProof(input);

    // Mark as verified since we validated the signature
    markProofVerified(savedProof.proof_id);

    console.log(
      `[Proof] Stored and verified transaction proof ${savedProof.proof_id} for borrower ${borrower.wallet_address}`
    );

    return {
      status: 'accept',
      response: {
        action: 'submit_data_proof',
        success: true,
        proof_id: savedProof.proof_id,
        proof_type: 'transactions',
        borrower_id: borrower.id,
        verified: true,
        transaction_count: txProof.summary.transactionCount,
        avg_monthly_income: txProof.summary.avgMonthlyIncome,
      },
    };
  } else if (proof.dataType === 'identity') {
    const idProof = proof as SubmitIdentityProofPayload['proof'];
    const input: IdentityProofInput = {
      proof_id: idProof.proofId,
      borrower_id: borrower.id,
      data_hash: idProof.dataHash,
      signature: idProof.signature,
      kyc_level: idProof.verification.kycLevel,
      verification_status: idProof.verification.status,
      expires_at: new Date(idProof.expiresAt).toISOString(),
    };

    const savedProof = saveIdentityProof(input);

    // Mark as verified
    markProofVerified(savedProof.proof_id);

    // Update borrower KYC level
    if (idProof.verification.verified) {
      updateBorrowerKycLevel(proof.borrowerAddress, idProof.verification.kycLevel);
    }

    console.log(
      `[Proof] Stored and verified identity proof ${savedProof.proof_id} for borrower ${borrower.wallet_address}, KYC level: ${idProof.verification.kycLevel}`
    );

    return {
      status: 'accept',
      response: {
        action: 'submit_data_proof',
        success: true,
        proof_id: savedProof.proof_id,
        proof_type: 'identity',
        borrower_id: borrower.id,
        verified: true,
        kyc_level: idProof.verification.kycLevel,
      },
    };
  }

  // This should never happen due to type checking, but handles unknown dataType values
  throw new Error(`Unsupported proof type: ${(proof as { dataType: string }).dataType}`);
};

/**
 * Handle inspect query for proof data
 */
export const handleInspectProof: InspectHandler = async (query: InspectQuery) => {
  const { params } = query;

  // Get specific proof by ID
  if (params.proof_id) {
    const proof = getDataProofById(params.proof_id);
    if (!proof) {
      return { error: 'Proof not found', proof_id: params.proof_id };
    }

    return {
      proof_id: proof.proof_id,
      proof_type: proof.proof_type,
      borrower_id: proof.borrower_id,
      loan_id: proof.loan_id,
      data_hash: proof.data_hash,
      verified: proof.verified,
      verified_at: proof.verified_at,
      expires_at: proof.expires_at,
      is_valid: isProofValid(proof.proof_id),
      // Include type-specific data
      ...(proof.proof_type === 'transactions'
        ? {
            transaction_count: proof.transaction_count,
            window_start: proof.window_start,
            window_end: proof.window_end,
            net_income: proof.net_income,
            avg_monthly_income: proof.avg_monthly_income,
          }
        : {}),
      ...(proof.proof_type === 'identity'
        ? {
            kyc_level: proof.kyc_level,
            verification_status: proof.verification_status,
          }
        : {}),
    };
  }

  // Get proofs by borrower address
  if (params.borrower_address) {
    const borrower = getBorrowerByAddress(params.borrower_address);
    if (!borrower) {
      return { error: 'Borrower not found', borrower_address: params.borrower_address };
    }

    const proofs = getProofsByBorrower(borrower.id);
    return {
      borrower_id: borrower.id,
      borrower_address: borrower.wallet_address,
      proofs: proofs.map(p => ({
        proof_id: p.proof_id,
        proof_type: p.proof_type,
        verified: p.verified,
        is_valid: isProofValid(p.proof_id),
        created_at: p.created_at,
      })),
      total_proofs: proofs.length,
    };
  }

  // Get latest transaction proof for a loan
  if (params.loan_id) {
    const proof = getLatestTransactionProof(params.loan_id);
    if (!proof) {
      return { error: 'No transaction proof found for loan', loan_id: params.loan_id };
    }

    return {
      loan_id: params.loan_id,
      proof_id: proof.proof_id,
      verified: proof.verified,
      is_valid: isProofValid(proof.proof_id),
      transaction_count: proof.transaction_count,
      avg_monthly_income: proof.avg_monthly_income,
      window_start: proof.window_start,
      window_end: proof.window_end,
    };
  }

  return { error: 'Missing required parameter: proof_id, borrower_address, or loan_id' };
};

/**
 * Handle inspect query for verified DSCR with proof chain
 */
export const handleInspectVerifiedDscr: InspectHandler = async (query: InspectQuery) => {
  const { params } = query;

  if (!params.loan_id) {
    return { error: 'loan_id parameter required' };
  }

  // Get the latest transaction proof for this loan
  const transactionProof = getLatestTransactionProof(params.loan_id);

  if (!transactionProof) {
    return {
      loan_id: params.loan_id,
      has_verified_data: false,
      error: 'No verified transaction data available',
    };
  }

  const isValid = isProofValid(transactionProof.proof_id);

  return {
    loan_id: params.loan_id,
    has_verified_data: true,
    proof_id: transactionProof.proof_id,
    proof_verified: transactionProof.verified,
    proof_valid: isValid,
    data_hash: transactionProof.data_hash,
    transaction_count: transactionProof.transaction_count,
    avg_monthly_income: transactionProof.avg_monthly_income,
    window_start: transactionProof.window_start,
    window_end: transactionProof.window_end,
    expires_at: transactionProof.expires_at,
  };
};
