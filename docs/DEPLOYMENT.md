# dreUSD System Deployment

This document describes the three-phase deployment process: **Deploy** (contract deployment), **Setup** (roles, allowances, and contract wiring), and **Wire OVault** (LayerZero pathways for cross-chain vault operations).

## Overview

1. **DeployDreSystem.s.sol** — Deploys all contracts. Requires `script/Config.sol` values that are known before deployment and the `PRIVATE_KEY` env var.
2. **SetupDreSystem.s.sol** — Configures roles and contract references. Requires all deployed addresses to be set in `Config.sol`, and uses `ADMIN_PRIVATE_KEY`.

Base-specific components (dreUSDs, dreRewardsDistributor, Oracle, AaveV3 adapter, NFTs, dreUSDManager, ShareOFT adapter, Composer) are only deployed and set up on **Base Sepolia (84532)** or **Base Mainnet (8453)**.

---

## Hub and spoke chains

LayerZero endpoints are resolved with **`Config.getLzEndpoint(chainId)`** (not stored on `ChainConfig`).

### Hub (full protocol stack)

| Network        | Chain ID |
|----------------|----------|
| Base Sepolia   | 84532    |
| Base Mainnet   | 8453     |

Deploy **DeployDreSystem** here first (or in parallel with spokes only after hub `dreUSD` address is known for spoke compliance, if your flow requires it). **SetupDreSystem** runs **only** on these chains.

### Spoke chains (dreUSD OFT + dreShareOFT)

On each spoke, **DeployDreSystem** deploys **dreUSD** (asset OFT) and **dreShareOFT** (CREATE2); it does **not** deploy the vault stack. The chain must be supported by **`getChainConfig`** and **`getLzEndpoint`** in `script/Config.sol`.

#### Testnet

| Network           | Chain ID  | Notes |
|-------------------|-----------|--------|
| Ethereum Sepolia  | 11155111  | Roles and `dreUSD` / `dreShareOFT` in `_ethSepoliaConfig()`. |

`wireDreUSD` / `wireShareOFT` use **Base Sepolia + Ethereum Sepolia** as the testnet mesh (see `Config` and `wireDreUSD.s.sol`).

#### Mainnet

| Network        | Chain ID | `Config` spoke admin constant (DEFAULT_ADMIN / UPGRADER / GUARDIAN on spoke `dreUSD`) |
|----------------|----------|--------------------------------------------------------------------------------------|
| Ethereum       | 1        | `MAINNET_SPOKE_ETHEREUM_ADMIN`                                                       |
| Polygon        | 137      | `MAINNET_SPOKE_POLYGON_ADMIN`                                                        |
| Arbitrum One   | 42161    | `MAINNET_SPOKE_ARBITRUM_ADMIN`                                                       |
| Monad          | 143      | `MAINNET_SPOKE_MONAD_ADMIN`                                                          |
| MegaETH        | 4326     | `MAINNET_SPOKE_MEGAETH_ADMIN`                                                        |
| Ink            | 57073    | `MAINNET_SPOKE_INK_ADMIN`                                                            |

**Shared across all mainnet spokes** (same deployed address on every spoke when using the same CREATE2 salt + factory):

- `MAINNET_DREUSD` → `ChainConfig.dreUSD`
- `MAINNET_DRE_SHARE_OFT` → `ChainConfig.dreShareOFT`

Set each **`MAINNET_SPOKE_*_ADMIN`** to the delegate that must receive roles on that chain (often the CREATE2 deployer; can be the same multisig on every chain). After deployment, set **`MAINNET_DREUSD`** and **`MAINNET_DRE_SHARE_OFT`** once; wiring scripts read them via `getChainConfig` for every spoke.

On **Base Mainnet**, set hub fields in **`_baseMainnetConfig()`** (`dreUSD`, `dreShareOFTAdapter`, `dreOVaultComposer`, vault/manager/oracle/NFTs, etc.) as you deploy.

### Suggested mainnet spoke order

1. Fill hub `_baseMainnetConfig()` pre-deploy fields (admins, USDC, Aave pool, stuck funds recipient, …).
2. Set each spoke’s `MAINNET_SPOKE_*_ADMIN` (non-zero before `DeployDreSystem` on that chain).
3. Run **DeployDreSystem** on **Base Mainnet**, then **SetupDreSystem** on Base.
4. For each mainnet spoke (Ethereum, Polygon, Arbitrum, Monad, MegaETH, Ink): run **DeployDreSystem** with the correct RPC (`--rpc-url`).
5. Update **`MAINNET_DREUSD`** and **`MAINNET_DRE_SHARE_OFT`** to the CREATE2 addresses (identical on all spokes if salt/factory match).
6. Update hub `Config` with `dreUSD`, `dreShareOFTAdapter`, composer, and any other deployed hub addresses.
7. Run **Phase 3** wiring on **every** chain in the mesh (see below).

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) installed.
- **script/Config.sol** updated with:
  - **Before deploy (hub):** `defaultAdmin`, `upgrader`, `guardian`, and other `ChainConfig` fields in `_baseSepoliaConfig()` / `_baseMainnetConfig()`; Aave/USDC/USDT; `getLzEndpoint(chainId)` must be non-zero; custodian, vault, caps, express addresses, role addresses, etc.
  - **Before deploy (each mainnet spoke):** matching `MAINNET_SPOKE_*_ADMIN` and, after first spoke deploys, `MAINNET_DREUSD` / `MAINNET_DRE_SHARE_OFT`.
  - **After deploy:** All deployed contract addresses on the relevant chain’s `getChainConfig` branch (see [Config: Before vs After](#config-before-vs-after)).

---

## Phase 1: Deploy

### Environment

| Variable            | Required | Description                                                                 |
|---------------------|----------|-----------------------------------------------------------------------------|
| `PRIVATE_KEY`       | Yes      | Used to broadcast deployment transactions.                                 |
| `ADMIN_PRIVATE_KEY` | Yes      | Required by the script (must be set; deploy uses `PRIVATE_KEY` only).       |

### Command

```bash
forge script script/DeployDreSystem.s.sol --rpc-url <RPC_URL> --slow --broadcast --verify
```

Use the RPC URL for the chain you are deploying to (hub: Base Sepolia / Base Mainnet; spoke: Sepolia or any configured mainnet spoke above).

### What Gets Deployed

Deployment is **chain-dependent**: hub chains get the full system; spoke chains get **dreUSD + dreShareOFT** only.

**Hub — Base Sepolia (84532) or Base Mainnet (8453):**

- **dreUSD** — ERC20 token (LayerZero endpoint from `getLzEndpoint`, default admin, CREATE2 factory from Config).
- **dreUSDs** — Vault for staked dreUSD.
- **dreRewardsDistributor** — Rewards distributor for vault.
- **dreUSDOracle** — Price oracle.
- **dreAaveAdapter** — Aave V3 integration.
- **dreWithdrawalNFT** — Standard and express withdrawal queue NFTs.
- **dreUSDManager** — Manager.
- **dreShareOFTAdapter** — Vault shares bridged via adapter (`getLzEndpoint(block.chainid)`).
- **dreOVaultComposer** — Composer.
- **dreShareOFT is not deployed on the hub.**

**Each spoke (Sepolia or mainnet table above):**

- **dreUSD** (asset OFT) and **dreShareOFT** (CREATE2).
- Vault, manager, adapter, and composer are **not** deployed on spokes.

### After Deployment

1. Save deployed addresses from the broadcast output (or `broadcast/` JSON).
2. Update **`script/Config.sol`**: hub — all `ChainConfig` fields in `_baseSepoliaConfig()` / `_baseMainnetConfig()`; mainnet spokes — **`MAINNET_DREUSD`**, **`MAINNET_DRE_SHARE_OFT`**, and per-spoke admins as needed.

---

## Phase 2: Setup

Setup applies only on **Base Sepolia (84532)** or **Base Mainnet (8453)**. All addresses used below must already be set in `Config.sol` for that hub chain.

### Environment

| Variable             | Required | Description                                                                 |
|----------------------|----------|-----------------------------------------------------------------------------|
| `ADMIN_PRIVATE_KEY`  | Yes      | Key for admin operations (grant roles, set distributor, oracle, manager).   |

### Command

```bash
forge script script/SetupDreSystem.s.sol --rpc-url <RPC_URL> --slow --broadcast
```

### What Setup Does

| Step | Config / Contract | Action |
|------|-------------------|--------|
| **dreUSD** | `dreUSD`, `manager`, `sanctionsList` | `setDreUSDManager(manager)`; optionally `setSanctionsList`. |
| **dreUSDs** | `dreUSDs`, `rewardsDistributor` | `setRewardsDistributor(rewardsDistributor)`. |
| **dreRewardsDistributor** | `rewardsDistributor`, `manager` | Grant `MODERATOR_ROLE` to manager. |
| **dreWithdrawalNFT** (both) | `withdrawalNFT`, `expressWithdrawalNFT`, `manager` | `setDreUSDManager(manager)` on both. |
| **dreAaveAdapter** | `aaveV3Adapter`, `manager` | `setDreUSDManager(manager)`; optionally `setVault`. |
| **dreUSDManager** | `manager`, vault, adapter, caps, USDC, express addresses | `updateVault`, `updateVaultAdapter`, `setDailyFiatMintCap`, `updateExpressPaybackAddress`, `updateAllowedList(USDC, true)`, `updateExpressWithdrawal`, optionally `setSanctionsList`. |
| **dreUSDOracle** | `oracle`, USDC, feeds, staleness | If USDC feed set: `setOracle(USDC, feed, stalenessThreshold)`. |

---

## Phase 3: Wire OVault Contracts

After Phase 2 on the hub, wire OVault so cross-chain operations work. Config must list **`dreUSD`**, **`dreShareOFTAdapter`**, **`dreShareOFT`** (per chain), and **`dreOVaultComposer`** on the hub where those scripts read them.

### Environment

| Variable                               | Required | Description                                                                 |
|----------------------------------------|----------|-----------------------------------------------------------------------------|
| `ADMIN_PRIVATE_KEY` or `PRIVATE_KEY`   | Yes      | Admin on dreUSD, ShareOFT, and ShareOFTAdapter for wiring.                 |

### Commands

**1. Wire dreUSD OFT** — run **once per chain** that appears in the active dreUSD mesh (testnet: Base Sepolia + Ethereum Sepolia; mainnet: Base Mainnet + Ethereum, Polygon, Arbitrum, Monad, MegaETH, Ink):

```bash
forge script script/ovault/wireDreUSD.s.sol:wireDreUSD --rpc-url <RPC_URL> --slow --broadcast
```

**2. Wire dreShareOFT** — run on the **hub** first, then **each spoke**:

```bash
# Hub (Base Sepolia or Base Mainnet)
forge script script/ovault/wireShareOFT.s.sol:wireShareOFT --rpc-url <HUB_RPC_URL> --slow --broadcast

# Each spoke (e.g. Ethereum Sepolia; repeat for every mainnet spoke RPC)
forge script script/ovault/wireShareOFT.s.sol:wireShareOFT --rpc-url <SPOKE_RPC_URL> --slow --broadcast
```

On the hub, `wireShareOFT` opens pathways from **`dreShareOFTAdapter`** to every spoke’s **`dreShareOFT`**. On a spoke, it connects **`dreShareOFT`** back to the hub adapter. See **`Config.shareOftMainnetSpokeChainIds()`** for the mainnet spoke list.

### What Wiring Does

- **Pathways**: LayerZero paths between hub and spokes.
- **DVNs**: Required DVNs (e.g. LayerZero Labs, Nethermind) as in `wire.s.sol`.
- **Confirmations**: `Config.confirmationsForChain(chainId)` (ULN source-chain confirmations).
- **Enforced options**: `sendOptions` / `sendAndCallOptions` (including compose on Sepolia spoke for composer flows).

See **docs/OVAULT.md** (section “Wire Contracts”) for more detail.

---

## Config: Before vs After

Field names refer to **`ChainConfig`** in **`script/Config.sol`** (and the **`MAINNET_*`** constants for shared mainnet spoke OFT addresses).

**Hub — set before `DeployDreSystem` on Base:**

- `defaultAdmin`, `upgrader`, `guardian`, `moderator`, `withdrawalConfig`, `pauser`, `custodian`, `custodianVault`, `stuckFundsRecipient`
- `dailyFiatMintCapUsd`, `expressPaybackAddress`, `expressFeeRecipient`, `sanctionsList` (optional)
- `managerTreasury`, `managerExpressOperator`, `managerKeeper`
- `aaveV3Pool`, `aaveV3Vault`, `usdc`, `usdt`, oracle feeds, `stalenessThresholdSeconds`
- `DEFAULT_CREATE2_FACTORY`; **`getLzEndpoint(BASE_*)`** must be non-zero

**Hub — set after deployment (before `SetupDreSystem`):**

- `dreUSD`, `dreUSDs`, `rewardsDistributor`, `oracle`, `withdrawalNFT`, `expressWithdrawalNFT`, `manager`, `aaveV3Adapter`, `dreShareOFTAdapter`, `dreOVaultComposer`

**Each mainnet spoke — before `DeployDreSystem` on that chain:**

- Non-zero **`MAINNET_SPOKE_*_ADMIN`** for that chain
- **`getLzEndpoint(chainId)`** non-zero

**Mainnet spokes — after dreUSD + ShareOFT exist on all spokes:**

- **`MAINNET_DREUSD`** and **`MAINNET_DRE_SHARE_OFT`** (same addresses on every spoke if CREATE2 matches)

**Ethereum Sepolia (`_ethSepoliaConfig`):**

- Roles + **`dreUSD`** + **`dreShareOFT`** for wiring and upgrade scripts on that spoke.

---

## Summary

| Phase       | Script                    | Env vars                             | Chains |
|-------------|---------------------------|--------------------------------------|--------|
| Deploy      | DeployDreSystem.s.sol     | `PRIVATE_KEY`, `ADMIN_PRIVATE_KEY`   | Hub: 84532 / 8453 full stack; each spoke: dreUSD + ShareOFT only |
| Setup       | SetupDreSystem.s.sol      | `ADMIN_PRIVATE_KEY`                  | 84532, 8453 only |
| Wire OVault | wireDreUSD, wireShareOFT  | `ADMIN_PRIVATE_KEY` or `PRIVATE_KEY` | Every hub + spoke in the configured mesh; one run per chain |

After deploy, fill `Config` with deployed addresses, run **Setup** once per hub deployment, then run **Phase 3** on the hub and **every** spoke that participates in the OVault network.
