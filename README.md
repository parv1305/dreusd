# DRE Contracts

Smart contracts for the DRE USD stablecoin ecosystem.

## Overview

DRE is a USD-pegged stablecoin ecosystem consisting of:

- **dreUSD** - ERC20 stablecoin token pegged 1:1 with USD
- **dreUSDs** - ERC4626 staking vault for dreUSD holders
- **dreUSDManager** - Core contract handling minting, withdrawals, and positions
- **dreUSDOracle** - Chainlink-based price oracle for stablecoin validation
- **dreWithdrawalNFT** - ERC721 NFT for withdrawal queue positions (two instances: standard 7 days / no fee, express 6h / 50 bps fee)
- **dreRewardsDistributor** - Rewards distribution for stakers

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](./docs/ARCHITECTURE.md) | System architecture and contract interactions |
| [Fiat Mint](./docs/FIAT_MINT.md) | Off-chain fiat deposit and minting flow |
| [Sanctions](./docs/SANCTIONS.md) | Sanctions list integration and compliance |
| [Deployment](./docs/DEPLOYMENT.md) | Deployment guide and configuration |
| [Bridging](./docs/BRIDGING.md) | Cross-chain bridging documentation |
| [Style](./docs/STYLE.md) | Naming and style conventions (incl. intentional `dre...` contract names) |

## Quick Start

```bash
# Compile contracts
forge build

# Run tests
forge test

# Start a local node
anvil
```

## Dependencies (git submodules)

```bash
git submodule update --init --recursive
```

## Contracts

```
contracts/
├── dreUSD.sol                    # ERC20 stablecoin with freeze functionality
├── dreUSDs.sol                   # ERC4626 staking vault
├── dreUSDManager.sol             # Core manager (mint, withdraw, positions)
├── DreUSDOracle.sol              # Chainlink price oracle integration
├── dreWithdrawalNFT.sol          # ERC721 for withdrawal queue (standard & express instances)
├── dreAaveAdapter.sol            # Aave V3 adapter for withdrawal liquidity
├── dreRewardsDistributor.sol # Yield streaming to stakers
└── interfaces/
    ├── IdreUSD.sol
    ├── IdreUSDs.sol
    ├── IdreUSDManager.sol
    ├── IDreUSDOracle.sol
    ├── IWithdrawalNFT.sol
    └── ...
```

## Key Features

### Minting
- Mint dreUSD from allowed stablecoins (USDC, USDT)
- Oracle validation via Chainlink price feeds
- ERC20 Permit support for gasless approvals
- Fiat minting with custodian signatures
- Slippage protection (`minAmountOut`) and deadline on all mints

### Withdrawals (Two-Queue System)
- **Express Queue**: Fast fills (6h target), 50 bps fee, global limit
- **Long Queue**: Slower fills (7 days), no fee, no limit
- Positions represented as transferable ERC721 NFTs
- Partners fill positions by providing USDC
- Slippage protection and deadline on all withdrawals

### Security
- Sanctions list integration (Chainalysis)
- Freeze capability on dreUSD
- Role-based access control
- Reentrancy protection (Checks-Effects-Interactions pattern)
- Upgradeable via UUPS proxy pattern

## Roles

| Role | Description |
|------|-------------|
| `MODERATOR_ROLE` | Configuration, oracle, sanctions, stablecoin management |
| `EXPRESS_OPERATOR_ROLE` | Fill express withdrawals, set payback address |
| `KEEPER_ROLE` | Execute fiat mints |
| `TREASURY_ROLE` | Payback express filler |
| `GUARDIAN_ROLE` | Freeze/unfreeze addresses on dreUSD (onlyGuardian) |
| `UPGRADER_ROLE` | Upgrade contract implementations |

## Deployed contracts
###  Base mainnet

| Contract | Address |
|----------|---------|
| dreUSD | `0xB4E008A61b5A7A7D0e1aebd639F704d24821Bb2F` |
| dreUSDs vault | `0x13F7Cbd3562e276b49AAdFf9b3Eef67561371bcF` |
| dreRewardsDistributor | `0x0C5990D188734a3918d793751FB9D9426d5487B2` |
| dreUSDOracle | `0x9Db85D8201d14ad7602aaFaC249F37Aa0B6D99b5` |
| Sequencer uptime feed | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |
| dreWithdrawalNFT (standard, 7d / no fee) | `0x3a5801950282645811f379E272F68b31A80bBC09` |
| dreWithdrawalNFT (express, 6h / 50 bps) | `0x5C156B79C9c9f906d9d8Eea59bB0D2779abBf494` |
| dreUSDManager | `0xa02557918d04973A712d7dFe2A5C735fC0117Ac8` |
| dreAaveAdapter | `0xb10d4843f1F7A807Be8362d009C5eeA78ef4253f` |
| dreShareOFTAdapter | `0xE4F808b1eBff059052529E66EA13c4b171DdDe3b` |
| dreOVaultComposer | `0xFFCCD2d1616D28eEd874D1c68c183f704f6da7bC` |

## License

BUSL-1.1 
