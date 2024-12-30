import { getContract } from "viem";
import { Contract, JsonRpcProvider, keccak256, toUtf8Bytes, Wallet } from "ethers";
import SimpleLoanPool from "./SimpleLoanPool.abi.json";
import { publicClient, walletClient } from "./client";

const provider = new JsonRpcProvider(process.env.NEXT_PUBLIC_RPC_URL as string);
const signer = new Wallet(process.env.PRIVATE_KEY as string, provider);

const simpleLoanPool = new Contract(
  process.env.LOAN_CONTRACT_ADDRESS as string,
  SimpleLoanPool.abi,
  signer
);

export async function getLoanAmount(loanId: string, contractAddress: `0x${string}`,): Promise<bigint | undefined> {
    try {
        const hashedLoanId = keccak256(toUtf8Bytes(loanId));

        console.log('hashedLoanId', hashedLoanId);
        if (!simpleLoanPool.loanIdToAmount) {
            throw new Error("loanIdToAmount function not found");
        }

        const amount: bigint | undefined = (await simpleLoanPool.loanIdToAmount(hashedLoanId)) as bigint | undefined;
        console.log('amount', amount);
        return amount;
    } catch (error) {
        console.error("Error getting loan amount", error);
    }
}

export async function updateLoanInterestRate(loanId: string, contractAddress: `0x${string}`, interestRate: bigint) {
    try {
        const hashedLoanId = keccak256(toUtf8Bytes(loanId));

        console.log('hashedLoanId', hashedLoanId);

        if (!simpleLoanPool.updateLoanInterestRate) {
            throw new Error("updateLoanInterestRate function not found");
        }
    
        await simpleLoanPool.updateLoanInterestRate(hashedLoanId, interestRate);
    } catch (error) {
        console.error("Error updating loan interest rate", error);
    }
}