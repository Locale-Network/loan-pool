import { getContract } from "viem";
import { keccak256, toUtf8Bytes } from "ethers";
import SimpleLoanPool from "./SimpleLoanPool.abi.json";
import { publicClient, walletClient } from "./client";

export async function getLoanAmount(loanId: string, contractAddress: `0x${string}`,): Promise<bigint | undefined> {
    try {
        const contract = getContract({
            address: contractAddress,
            abi: SimpleLoanPool.abi,
            publicClient,
        });

        const hashedLoanId = keccak256(toUtf8Bytes(loanId));

        console.log('hashedLoanId', hashedLoanId);

        const amount: bigint | undefined = (await contract.read.loanIdToAmount?.call([hashedLoanId])) as bigint | undefined;
        console.log('amount', amount);
        return amount;
    } catch (error) {
        console.error("Error getting loan amount", error);
    }
}

export async function updateLoanInterestRate(loanId: string, contractAddress: `0x${string}`, interestRate: bigint) {
    try {
        const contract = getContract({
            address: contractAddress,
            abi: SimpleLoanPool.abi,
            publicClient,
            walletClient
        });

        const hashedLoanId = keccak256(toUtf8Bytes(loanId));

        console.log('hashedLoanId', hashedLoanId);
    
        await contract.write.updateLoanInterestRate?.call([hashedLoanId, interestRate]);
    } catch (error) {
        console.error("Error updating loan interest rate", error);
    }
}