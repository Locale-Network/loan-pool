## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
forge script script/Create2.s.sol:Create2Script --sig "run()" --rpc-url http://127.0.0.1:8545

forge script script/SimpleLoanPool.s.sol:SimpleLoanPoolScript --sig "deployWithToken(address,address[])" 0x4A9A56af5CadA04dbBbaB8298BC4E149435DcB89 "[0x4A9A56af5CadA04dbBbaB8298BC4E149435DcB89]"  --rpc-url http://127.0.0.1:8545

forge script script/SimpleLoanPool.s.sol:SimpleLoanPoolScript --sig "deployWithToken(address,address[])" 0x4A9A56af5CadA04dbBbaB8298BC4E149435DcB89 "[0x4A9A56af5CadA04dbBbaB8298BC4E149435DcB89]" --rpc-url $ARBITRUM_MAINNET_RPC_URL --etherscan-api-key $ARBITRUM_MAINNET_ETHERSCAN_API_KEY --verify --verifier-url $ARBITRUM_ETHERSCAN_VERIFIER_URL --private-key $PRIVATE_KEY

cast send 0xF60866D9B48dAd4459288531C792e959106b4fA6 "mint(address,uint256)" 0x974F91552D78700C9d65C0f88Dc88A160119A926 1000000000000 --rpc-url $ARBITRUM_MAINNET_RPC_URL --private-key $PRIVATE_KEY
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
