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

