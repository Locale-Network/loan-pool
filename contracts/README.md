# Locale Lending - Smart Contracts

This directory contains the Solidity smart contracts for the Locale Lending platform.

## Architecture Overview

```text
src/
├── ERC20/                    # Token contracts
│   └── UpgradeableCommunityToken.sol
├── Loan/                     # Core loan pool contracts
│   └── SimpleLoanPool.sol
├── Vault/                    # Pool vault for staking
│   ├── PoolVault.sol
│   └── IPoolVault.sol
├── Staking/                  # Staking pool contracts
│   └── StakingPool.sol
└── NFT/                      # Soulbound credential NFTs
    ├── BorrowerCredential.sol
    └── InvestorCredential.sol
```

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- An RPC endpoint (Anvil for local, or Arbitrum Sepolia/Mainnet)

## Setup

```bash
# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test
```

## Environment Variables

Create a `.env` file with:

```bash
# Local development (Anvil)
ANVIL_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Testnet/Mainnet deployment
PRIVATE_KEY=your_private_key_here

# Arbitrum Sepolia
ARBITRUM_TESTNET_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc
ARBITRUM_TESTNET_ETHERSCAN_API_KEY=your_api_key
ARBITRUM_TESTNET_ETHERSCAN_VERIFIER_URL=https://api-sepolia.arbiscan.io/api

# Arbitrum Mainnet
ARBITRUM_MAINNET_RPC_URL=https://arb1.arbitrum.io/rpc
ARBITRUM_MAINNET_ETHERSCAN_API_KEY=your_api_key
ARBITRUM_ETHERSCAN_VERIFIER_URL=https://api.arbiscan.io/api
```

## Deployment Order

Contracts must be deployed in this order due to dependencies:

### 1. Deploy SimpleLoanPool (with Token)

```bash
# Deploy loan pool with new token
forge script script/SimpleLoanPool.s.sol:SimpleLoanPoolScript \
  --sig "deployWithToken(address,address[])" \
  <OWNER_ADDRESS> "[<APPROVER1>,<APPROVER2>]" \
  --rpc-url $ARBITRUM_TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --verify \
  --verifier-url $ARBITRUM_TESTNET_ETHERSCAN_VERIFIER_URL \
  --etherscan-api-key $ARBITRUM_TESTNET_ETHERSCAN_API_KEY \
  --broadcast
```

### 2. Deploy StakingPool

```bash
forge script script/StakingPool.s.sol:StakingPoolScript \
  --rpc-url $ARBITRUM_TESTNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --verify \
  --verifier-url $ARBITRUM_TESTNET_ETHERSCAN_VERIFIER_URL \
  --etherscan-api-key $ARBITRUM_TESTNET_ETHERSCAN_API_KEY \
  --broadcast
```

## Local Development (Anvil)

```bash
# Start local node
anvil

# In another terminal, deploy to local
forge script script/SimpleLoanPool.s.sol:SimpleLoanPoolScript \
  --sig "deployWithToken(address,address[])" \
  0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  "[0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266]" \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

## Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test testVerifyKYCProof

# Run with gas report
forge test --gas-report
```

## Contract Verification

After deployment, verify contracts on the block explorer:

```bash
forge verify-contract <CONTRACT_ADDRESS> \
  src/Path/To/Contract.sol:ContractName \
  --chain-id 421614 \
  --verifier-url $ARBITRUM_TESTNET_ETHERSCAN_VERIFIER_URL \
  --etherscan-api-key $ARBITRUM_TESTNET_ETHERSCAN_API_KEY
```

## Security Considerations

1. **Verification**: Proof verification is handled off-chain via Cartesi rollups with zkFetch (Reclaim Protocol). On-chain contracts receive verified data through Cartesi notices.

2. **Soulbound NFTs**: BorrowerCredential and InvestorCredential are non-transferable tokens minted after KYC/AML verification.

3. **Upgradability**: SimpleLoanPool and other core contracts use UUPS proxy pattern. The upgrade function is protected by access control.

4. **Access Control**: Owner-only functions are protected. Review approvers before deployment.

## Gas Costs (Estimated)

| Operation | Gas |
|-----------|-----|
| Create Loan | ~150,000 |
| Activate Loan | ~80,000 |
| Stake | ~100,000 |
| Unstake | ~90,000 |

## Foundry Commands Reference

```bash
# Build
forge build

# Test
forge test

# Format
forge fmt

# Gas Snapshots
forge snapshot

# Local node
anvil

# Cast (interact with contracts)
cast call <ADDRESS> "functionName()" --rpc-url <RPC_URL>
cast send <ADDRESS> "functionName(args)" --rpc-url <RPC_URL> --private-key <KEY>
```
