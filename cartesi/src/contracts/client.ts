import { createPublicClient, http } from 'viem';
import { sepolia } from 'viem/chains';

const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL;
if (!RPC_URL) {
  throw new Error('RPC_URL not configured');
}

export const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(RPC_URL),
});
