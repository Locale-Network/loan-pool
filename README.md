# Loan Pool

## Cartesi Node

Receives proofs through the InputBox contract and processes those proofs before updating the base layer. 

In this case, user transaction history is sent together with the loan id in a proof. The transaction history is processed and the interest rate on the loan updated.

## SimpleLoanPool

The SimpleLoanPool is a smart contract that manages a lending pool with the following features:

### Key Features
- ERC20 token-based lending system
- Role-based access control (Pool Managers, System, Approvers)
- Dynamic interest rate management
- Flexible loan terms and repayment schedules
- Upgradeable contract architecture

### Core Functions
- Loan creation and activation
- Automated repayment calculations
- Interest rate adjustments
- Repayment processing with principal and interest tracking

### Security Features
- Access control hierarchies
- Input validation
- Upgradeable security pattern
- Balance checks

## Getting Started

### Cartesi

Work from the `cartesi` folder:

```bash
cd cartesi
```

Spin up the local environment (Anvil):

```bash
cartesi build
cartesi run
```

Create a private key and assign funds to it:

```bash
curl -X POST --data '{
  "jsonrpc": "2.0",
  "method": "anvil_setBalance",
  "params": [
    "0x4A9A56af5CadA04dbBbaB8298BC4E149435DcB89", << address
    "0x21E19E0C9BAB2400000" << amount
  ],
  "id": 1
}' -H "Content-Type: application/json" http://localhost:8545
```


### Contracts

Work from the `contracts` folder:

```bash
cd contracts
``` 

Make an env file:

```bash
cp .example.env .env
```

Put your private key in here.

Read your .env file into the terminal

```bash
source .env
```


Deploy the contracts (Anvil), replace the address with the one of your private key (it makes you the owner):

```bash
forge script script/SimpleLoanPool.s.sol:SimpleLoanPoolScript --sig "deployWithToken(address,address[])" 0x4A9A56af5CadA04dbBbaB8298BC4E149435DcB89 "[0x4A9A56af5CadA04dbBbaB8298BC4E149435DcB89]"  --rpc-url http://127.0.0.1:8545 --broadcast
```

This will deploy the contracts (including a mock token) and fund the loan pool.

Note down the token and loan pool address. You will need these for the .env file of the Loan Platform.