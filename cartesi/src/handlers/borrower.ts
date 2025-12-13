import { AdvanceHandler, InspectHandler, InspectQuery, AdvanceRequestData } from '../router';
import {
  createBorrower,
  getBorrowerByAddress,
  getBorrowerById,
  updateBorrowerKycLevel,
  Borrower,
} from '../db';

/**
 * Payload for registering a borrower.
 */
interface RegisterBorrowerPayload {
  action: 'register_borrower';
  wallet_address: string;
  plaid_item_hash?: string;
}

/**
 * Payload for updating KYC level.
 */
interface UpdateKycPayload {
  action: 'update_kyc';
  wallet_address: string;
  kyc_level: number;
}

/**
 * Sanitize borrower data for public response.
 * Removes sensitive information.
 */
function sanitizeBorrower(borrower: Borrower): Partial<Borrower> {
  return {
    id: borrower.id,
    wallet_address: borrower.wallet_address,
    kyc_level: borrower.kyc_level,
    created_at: borrower.created_at,
    // plaid_item_hash is intentionally omitted for privacy
  };
}

/**
 * Handle borrower registration.
 */
export const handleRegisterBorrower: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const { wallet_address, plaid_item_hash } = payload as RegisterBorrowerPayload;

  if (!wallet_address || typeof wallet_address !== 'string') {
    throw new Error('Valid wallet_address is required');
  }

  // Validate wallet address format (basic check)
  if (!/^0x[a-fA-F0-9]{40}$/.test(wallet_address)) {
    throw new Error('Invalid wallet address format');
  }

  // Check if borrower already exists
  const existing = getBorrowerByAddress(wallet_address);
  if (existing) {
    return {
      status: 'accept',
      response: {
        action: 'register_borrower',
        success: true,
        borrower: sanitizeBorrower(existing),
        message: 'Borrower already registered',
      },
    };
  }

  // Create new borrower
  const borrower = createBorrower(wallet_address, plaid_item_hash);

  console.log(`Borrower registered: ${wallet_address}`);

  return {
    status: 'accept',
    response: {
      action: 'register_borrower',
      success: true,
      borrower: sanitizeBorrower(borrower),
    },
  };
};

/**
 * Handle KYC level update.
 */
export const handleUpdateKyc: AdvanceHandler = async (
  data: AdvanceRequestData,
  payload: unknown
) => {
  const { wallet_address, kyc_level } = payload as UpdateKycPayload;

  if (!wallet_address || typeof wallet_address !== 'string') {
    throw new Error('Valid wallet_address is required');
  }

  if (typeof kyc_level !== 'number' || kyc_level < 0 || kyc_level > 3) {
    throw new Error('Valid kyc_level (0-3) is required');
  }

  const borrower = getBorrowerByAddress(wallet_address);
  if (!borrower) {
    throw new Error('Borrower not found');
  }

  updateBorrowerKycLevel(wallet_address, kyc_level);

  console.log(`KYC updated for ${wallet_address}: level ${kyc_level}`);

  return {
    status: 'accept',
    response: {
      action: 'update_kyc',
      success: true,
      wallet_address,
      kyc_level,
    },
  };
};

/**
 * Handle inspect query for borrower data.
 */
export const handleInspectBorrower: InspectHandler = async (query: InspectQuery) => {
  const { params } = query;

  // Get borrower by address
  if (params.address) {
    const borrower = getBorrowerByAddress(params.address);
    if (!borrower) {
      return { error: 'Borrower not found', address: params.address };
    }
    return { borrower: sanitizeBorrower(borrower) };
  }

  // Get borrower by ID
  if (params.id) {
    const borrower = getBorrowerById(parseInt(params.id, 10));
    if (!borrower) {
      return { error: 'Borrower not found', id: params.id };
    }
    return { borrower: sanitizeBorrower(borrower) };
  }

  return { error: 'Address or ID parameter required' };
};
