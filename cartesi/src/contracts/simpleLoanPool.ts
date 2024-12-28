import { getContract, keccak256, toBytes } from "viem";
import SimpleLoanPool from "./SimpleLoanPool.abi.json";
import { publicClient } from "./client";

export async function getLoanAmount(loanId: string, contractAddress: `0x${string}`,): Promise<bigint | undefined> {
    try {
        const contract = getContract({
            address: contractAddress,
            abi: SimpleLoanPool,
            publicClient,
        });

        const hashedLoanId = keccak256(toBytes(loanId));
        const amount: bigint | undefined = (await contract.read.loanIdToAmount?.call([hashedLoanId])) as bigint | undefined;
        console.log('amount', amount);
        return amount;
    } catch (error) {
        console.error("Error getting loan amount", error);
    }
}