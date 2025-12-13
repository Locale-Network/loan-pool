#!/bin/bash
# deploy-local.sh - Deploy all Locale Lending contracts to local Anvil

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONTRACTS_DIR="$PROJECT_DIR/contracts"
OUTPUT_FILE="$PROJECT_DIR/deployed-addresses.json"

# Default Anvil private key (first account)
export ANVIL_PRIVATE_KEY="${ANVIL_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

echo "============================================"
echo "  Locale Lending - Local Deployment"
echo "============================================"
echo ""

# Check if Anvil is running
if ! curl -s http://127.0.0.1:8545 -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' > /dev/null 2>&1; then
    echo "Error: Anvil is not running on localhost:8545"
    echo ""
    echo "Start Anvil with one of these methods:"
    echo "  1. anvil                           (standalone)"
    echo "  2. cd cartesi && cartesi run       (with Cartesi)"
    echo ""
    exit 1
fi

echo "Anvil detected on localhost:8545"
echo ""

# Build contracts
echo "Building contracts..."
cd "$CONTRACTS_DIR"
forge build --quiet

# Deploy all contracts
echo "Deploying contracts..."
echo ""

# Run the deployment script and capture output
DEPLOY_OUTPUT=$(forge script script/DeployAll.s.sol:DeployAllScript \
    --rpc-url http://127.0.0.1:8545 \
    --broadcast 2>&1)

echo "$DEPLOY_OUTPUT"

# Extract addresses from deployment output
echo ""
echo "Extracting deployed addresses..."

# Parse the console output for addresses
TOKEN=$(echo "$DEPLOY_OUTPUT" | grep "Token (lUSD):" | awk '{print $NF}')
LOAN_POOL=$(echo "$DEPLOY_OUTPUT" | grep "SimpleLoanPool:" | awk '{print $NF}')
STAKING_POOL=$(echo "$DEPLOY_OUTPUT" | grep "StakingPool:" | awk '{print $NF}')
BORROWER_CRED=$(echo "$DEPLOY_OUTPUT" | grep "BorrowerCredential:" | awk '{print $NF}')
INVESTOR_CRED=$(echo "$DEPLOY_OUTPUT" | grep "InvestorCredential:" | awk '{print $NF}')

# Create JSON output file
cat > "$OUTPUT_FILE" << EOF
{
  "chainId": 31337,
  "rpcUrl": "http://127.0.0.1:8545",
  "contracts": {
    "token": "$TOKEN",
    "loanPool": "$LOAN_POOL",
    "stakingPool": "$STAKING_POOL",
    "borrowerCredential": "$BORROWER_CRED",
    "investorCredential": "$INVESTOR_CRED"
  },
  "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "Deployed addresses saved to: $OUTPUT_FILE"
echo ""
cat "$OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "  1. cd ../lending-platform"
echo "  2. node scripts/inject-addresses.js"
echo "  3. npm run dev"
