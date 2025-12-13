#!/bin/bash
# start-local-dev.sh - Start complete local development environment
#
# This script orchestrates:
# 1. Cartesi node (includes Anvil)
# 2. Contract deployment
# 3. Frontend configuration
#
# Prerequisites:
# - Docker running (for Cartesi)
# - Node.js 18+
# - Foundry installed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LENDING_PLATFORM="$PROJECT_DIR/../lending-platform"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}"
echo "============================================"
echo "  Locale Lending - Local Development Setup"
echo "============================================"
echo -e "${NC}"

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker daemon is not running${NC}"
    exit 1
fi

if ! command -v forge &> /dev/null; then
    echo -e "${RED}Error: Foundry (forge) is not installed${NC}"
    echo "Install with: curl -L https://foundry.paradigm.xyz | bash"
    exit 1
fi

if ! command -v node &> /dev/null; then
    echo -e "${RED}Error: Node.js is not installed${NC}"
    exit 1
fi

echo -e "${GREEN}All prerequisites met!${NC}"
echo ""

# Function to wait for Anvil
wait_for_anvil() {
    echo "Waiting for Anvil to be ready..."
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -s http://127.0.0.1:8545 -X POST \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' > /dev/null 2>&1; then
            echo -e "${GREEN}Anvil is ready!${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    echo -e "${RED}Timeout waiting for Anvil${NC}"
    return 1
}

# Check if Cartesi/Anvil is already running
if curl -s http://127.0.0.1:8545 -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' > /dev/null 2>&1; then
    echo -e "${YELLOW}Anvil already running on localhost:8545${NC}"
else
    echo ""
    echo -e "${YELLOW}Anvil is not running.${NC}"
    echo ""
    echo "Please start Cartesi in a separate terminal:"
    echo -e "${GREEN}  cd $PROJECT_DIR/cartesi && cartesi run${NC}"
    echo ""
    echo "Or start standalone Anvil:"
    echo -e "${GREEN}  anvil${NC}"
    echo ""
    echo "Then run this script again."
    exit 1
fi

# Deploy contracts
echo ""
echo "Step 1: Deploy contracts..."
"$SCRIPT_DIR/deploy-local.sh"

# Configure frontend
echo ""
echo "Step 2: Configure frontend..."
cd "$LENDING_PLATFORM"

# Create .env.local if it doesn't exist
if [ ! -f .env.local ]; then
    if [ -f .env.local.example ]; then
        cp .env.local.example .env.local
        echo "Created .env.local from template"
    fi
fi

# Inject addresses
node scripts/inject-addresses.js

echo ""
echo -e "${GREEN}============================================"
echo "  Setup Complete!"
echo "============================================${NC}"
echo ""
echo "Next steps:"
echo ""
echo "  1. Start the relay service (in a new terminal):"
echo -e "     ${GREEN}cd $LENDING_PLATFORM && npm run relay:local${NC}"
echo ""
echo "  2. Start the frontend (in a new terminal):"
echo -e "     ${GREEN}cd $LENDING_PLATFORM && npm run dev${NC}"
echo ""
echo "  3. Open http://localhost:3000 in your browser"
echo ""
echo "  4. Import Anvil test account in MetaMask:"
echo "     Private Key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
echo "     (This account has 10000 ETH and 1M lUSD tokens)"
echo ""
