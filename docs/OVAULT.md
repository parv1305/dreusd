# OVault Deployment Guide

This guide covers the deployment of LayerZero OVault components for cross-chain vault operations.

## Deployment Order

Deploy the contracts in the following order:

1. **ShareOFTAdapter** (on hub chain - Base)
2. **ShareOFT** (on each spoke chain)
3. **Composer** (on hub chain - Base, after ShareOFTAdapter is deployed)

## 1. Deploy ShareOFTAdapter

Deploy the ShareOFTAdapter on the hub chain (Base Sepolia or Base Mainnet).

### Required Variables

**From Config.sol:**
- `DREUSDS_ADDRESS` - The vault share token address
- `DEFAULT_ADMIN` - Admin address
- LayerZero endpoint (automatically selected based on chain ID)

**Environment Variables:**
- `PRIVATE_KEY` - Private key for deployment

### Deployment Command

```bash
forge script script/ovault/deployShareOFTAdapter.s.sol:DeployShareOFTAdapter \
  --rpc-url <BASE_RPC_URL> \
  --broadcast --verify
```

### After Deployment

Update `DRE_SHARE_OFT_ADAPTER_ADDRESS` in `script/Config.sol` with the deployed address before proceeding to step 3.

---

## 2. Deploy ShareOFT

Deploy ShareOFT on each spoke chain. **Do NOT deploy on Base (hub chain).**

Supported spokes are defined in **`script/Config.sol`** and wiring helpers (e.g. **testnet:** Ethereum Sepolia; **mainnet:** Ethereum, Polygon, Arbitrum One, Monad, MegaETH, Ink). Use the same **`DeployShareOFT`** / **`DeployDreSystem`** flow on each spoke RPC with that chain’s `defaultAdmin` (and, for mainnet spokes, **`MAINNET_SPOKE_*_ADMIN`** plus shared **`MAINNET_DREUSD`** after dreUSD exists).

### Required Variables

**From Config.sol:**
- `DEFAULT_ADMIN` - Admin address
- `DEFAULT_CREATE2_FACTORY` - CREATE2 factory address
- LayerZero endpoint (automatically selected based on chain ID)

**Environment Variables:**
- `PRIVATE_KEY` - Private key for deployment

### Deployment Command

For each spoke chain:

```bash
forge script script/ovault/deployShareOFT.s.sol:DeployShareOFT \
  --rpc-url <SPOKE_CHAIN_RPC_URL> \
  --broadcast \
  --verify
```

**Note:** ShareOFT uses CREATE2 for deterministic addresses, so it will have the same address across all spoke chains.

### After Deployment

Update `DRE_SHARE_OFT_ADDRESS` in `script/Config.sol` with the deployed address (same on all spoke chains).

---

## 3. Deploy Composer

Deploy the Composer on the hub chain (Base Sepolia or Base Mainnet) **after** ShareOFTAdapter is deployed and its address is updated in Config.

### Required Variables

**From Config.sol:**
- `DREUSDS_ADDRESS` - The vault address
- `DREUSD_ADDRESS` - The asset OFT address
- `DRE_SHARE_OFT_ADAPTER_ADDRESS` - ShareOFTAdapter address (must be set before deployment)

**Environment Variables:**
- `PRIVATE_KEY` - Private key for deployment

### Deployment Command

```bash
forge script script/ovault/deployComposer.s.sol:DeployComposer \
  --rpc-url <BASE_RPC_URL> \
  --broadcast \
  --verify
```

### After Deployment

Update `DRE_OVAULT_COMPOSER_ADDRESS` in `script/Config.sol` with the deployed address.

---

## Summary of Config Variables

Make sure the following addresses are set in `script/Config.sol`:

- `DREUSD_ADDRESS` - Asset OFT (dreUSD token)
- `DREUSDS_ADDRESS` - Vault (dreUSDs)
- `DEFAULT_ADMIN` - Admin address
- `DRE_SHARE_OFT_ADAPTER_ADDRESS` - Set after step 1
- `DRE_SHARE_OFT_ADDRESS` - Set after step 2 (same on all spoke chains)
- `DRE_OVAULT_COMPOSER_ADDRESS` - Set after step 3

## Chain Requirements

- **Hub chain (Base Sepolia / Base Mainnet):** ShareOFTAdapter, Composer (plus full hub stack from **docs/DEPLOYMENT.md**).
- **Spoke chains:** ShareOFT (and dreUSD asset OFT) on each chain in **`Config`** — testnet: Ethereum Sepolia; mainnet: Ethereum, Polygon, Arbitrum One, Monad, MegaETH, Ink (see **`shareOftMainnetSpokeChainIds()`** / **`dreUsdMainnetChainIds()`** in `script/Config.sol`).

---

## Required Allowances

After deployment, the following token approvals are needed for OVault operations:

### 1. For Deposits (Cross-Chain Asset to Shares)

Users need to approve the **Composer** to spend their **dreUSD** tokens:

### 2. For Sending Shares Cross-Chain

Users need to approve the **ShareOFTAdapter** to spend their **dreUSDs** (vault shares):


| Token | Spender | Purpose |
|-------|---------|---------|
| dreUSD | dreOVaultComposer | Cross-chain deposits (asset → shares) |
| dreUSDs | dreShareOFTAdapter | Cross-chain share transfers |

**Note:** The Composer automatically handles internal approvals for the vault and adapters during its constructor, so no additional approvals are needed at the contract level.

---

## 4. Wire Contracts

After deployment, wire the contracts to enable cross-chain communication. The wiring scripts configure LayerZero pathways, DVNs, confirmations, and enforced options.

### Wire dreUSD OFT

Run **`wireDreUSD`** once on **every** chain in the active dreUSD mesh (the script selects peers from `Config`; **testnet:** Base Sepolia + Ethereum Sepolia; **mainnet:** Base Mainnet + Ethereum, Polygon, Arbitrum, Monad, MegaETH, Ink). Each run must have **`dreUSD`** set in `Config` for all peers.

```bash
forge script script/ovault/wireDreUSD.s.sol:wireDreUSD \
  --rpc-url <CHAIN_RPC_URL> \
  --broadcast
```

### Wire dreShareOFT (hub and spokes)

**`wireShareOFT`** configures both the hub adapter and each spoke’s ShareOFT. Run on **Base** first (pathways to every spoke in `Config.shareOftMainnetSpokeChainIds()` / testnet spoke list), then on **each spoke** RPC.

```bash
# Hub (Base Sepolia or Base Mainnet)
forge script script/ovault/wireShareOFT.s.sol:wireShareOFT \
  --rpc-url <BASE_RPC_URL> \
  --broadcast

# Each spoke (repeat per chain)
forge script script/ovault/wireShareOFT.s.sol:wireShareOFT \
  --rpc-url <SPOKE_RPC_URL> \
  --broadcast
```

**Note:** On the hub this opens paths from **`dreShareOFTAdapter`** to each spoke’s **`dreShareOFT`**. On a spoke it sets the path back to the hub and, where configured (e.g. Ethereum Sepolia), compose options for vault flows. There is no separate `wireShareOFTAdapter` script—the adapter is wired via **`wireShareOFT`** on the hub.

### Wiring Configuration Details

The wiring scripts configure:

- **Pathways**: Bidirectional connections between chains
- **DVNs**: Required and optional Data Verification Networks (LayerZero Labs, Nethermind)
- **Confirmations**: `Config.confirmationsForChain(chainId)` (e.g. higher on Ethereum / Polygon mainnet than on L2 hubs; tune to match LayerZero / DVN guidance)
- **Enforced Options**: 
  - `sendOptions`: Gas for `lzReceive` (80,000 gas)
  - `sendAndCallOptions`: Gas for `lzCompose` on hub chain (400,000 gas) - enables composer functionality

**Important:** The composer is only called when tokens are sent with compose enabled. The `sendAndCallOptions` are configured for messages TO the hub chain where the composer is located.

---

## 5. Deposit Scripts

After deployment and wiring, you can use the deposit scripts to interact with the vault. There are three deposit scripts for different use cases:

### depositHub.s.sol - Direct Deposit on Hub Chain

Deposits dreUSD assets directly into the vault on the hub chain (Base Sepolia) without any cross-chain operations. This is a simple local deposit.

**Usage:**

```bash
export PRIVATE_KEY=your_private_key
export ASSET_AMOUNT=100000000000000000000  # Amount in wei (100 tokens with 18 decimals)
export RECIPIENT=0xRecipientAddress  # Optional: defaults to sender if not set

forge script script/ovault/depositHub.s.sol:depositHub \
  --rpc-url <BASE_SEPOLIA_RPC_URL> \
  --broadcast
```

**What it does:**
- Approves the vault to spend dreUSD (if needed)
- Deposits dreUSD assets directly into the vault
- Receives dreUSDs shares on the hub chain
- No cross-chain operations involved

### depositHubAndSend.s.sol - Deposit on Hub and Send to Spoke

Deposits dreUSD assets on the hub chain and sends the resulting shares to a spoke chain using the composer.

**Usage:**

```bash
export PRIVATE_KEY=your_private_key
export ASSET_AMOUNT=100000000000000000000  # Amount in wei (100 tokens with 18 decimals)
export RECIPIENT=0xRecipientAddress  # Address to receive shares on destination chain
export DST_CHAIN_ID=11155111  # Destination chain ID (e.g., Ethereum Sepolia)

forge script script/ovault/depositHubAndSend.s.sol:depositHubAndSend \
  --rpc-url <BASE_SEPOLIA_RPC_URL> \
  --broadcast
```

**What it does:**
- Approves the composer to spend dreUSD (if needed)
- Uses the composer's `depositAndSend` function
- Deposits dreUSD assets into the vault on the hub chain
- Sends the resulting shares cross-chain to the recipient on the destination chain

### depositSpoke.s.sol - Deposit from Spoke Chain

Deposits dreUSD assets from a spoke chain (e.g., Ethereum Sepolia) and receives shares on the hub chain (Base Sepolia).

**Usage:**

```bash
export PRIVATE_KEY=your_private_key
export ASSET_AMOUNT=100000000000000000000  # Amount in wei (100 tokens with 18 decimals)
export RECIPIENT=0xRecipientAddress  # Address to receive shares on hub chain (Base Sepolia)

forge script script/ovault/depositSpoke.s.sol:depositSpoke \
  --rpc-url <SPOKE_CHAIN_RPC_URL> \
  --broadcast
```

**What it does:**
- Sends dreUSD tokens with compose enabled to the composer on the hub chain
- The compose message contains instructions for where to send the resulting shares
- When tokens arrive at the composer, it deposits them into the vault
- The composer sends the resulting shares to the recipient on the hub chain

**Note:** This script requires the asset OFT (dreUSD) to be wired with compose functionality enabled for messages to the hub chain.
