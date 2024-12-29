import { createPublicClient, createWalletClient, http } from 'viem';

const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL;
if (!RPC_URL) {
  throw new Error('RPC_URL not configured');
}

export const publicClient = createPublicClient({
  transport: http(RPC_URL),
});

export const walletClient = createWalletClient({
  transport: http(RPC_URL),
  key: process.env.PRIVATE_KEY as `0x${string}`,
});
