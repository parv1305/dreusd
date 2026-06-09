# DRE Protocol — Smart Contract Architecture

## Overview

The DRE Protocol is a yield-bearing stablecoin system built on dreUSD, an ERC20 token backed by fiat reserves held at regulated custodians. Users can stake dreUSD to receive dreUSDs (staked dreUSD), which automatically accrues yield from off-chain USD products.

---

## Contract Architecture

### 1. dreUSDManager — Mint, Withdrawal & Position Manager

**Type:** UUPS upgradeable contract governed via DRE multisig  
**Purpose:** Handles minting, express withdrawals, and long queue withdrawal positions for dreUSD.

#### Immutable Addresses (set in constructor):
- `dreUSD` - The dreUSD token contract
- `dreUSDs` - The staking vault contract
- `usdc` - USDC token for withdrawals

#### Minting Functions:

| Function | Description |
|----------|-------------|
| `mint(asset, amount, minAmountOut, deadline)` | Mint with standard ERC20 approval; dreUSD minted to msg.sender |
| `mint(asset, amountIn, minAmountOut, deadline, permitSig)` | Mint with ERC20 Permit; dreUSD minted to msg.sender (no receiver parameter) |
| `mintFrom(from, asset, amountIn, receiver, minAmountOut, deadline, permitSig, authorizeSig)` | Mint on behalf of another address to a receiver |
| `mintAndStake(asset, amountIn, receiver, minAmountOut, minSharesOut, deadline, permitSig)` | Mint and stake in one transaction; `minAmountOut` protects dreUSD mint, `minSharesOut` protects final dreUSDs shares (totalAssets() can move between quote and execution) |
| `mintFromUsd(FiatMint m, bytes custodianSig)` | Fiat mint with custodian signature (KEEPER_ROLE) |

All minting functions include:
- `minAmountOut` - Slippage protection (minimum dreUSD to receive)
- `deadline` - Order expiration timestamp

#### Withdrawal System — Two Queues:

**Express Withdrawals (6h fill target, 50 bps fee):**
- Global limit of `expressWithdrawalMaxLimit` (default 10M USDC)
- Limit decreases when withdrawal requested, increases when filler is paid back
- Fee calculated in USDC, collected when position is filled
- Positions represented as ERC721 NFTs (second instance of `dreWithdrawalNFT`)

**Long Queue Withdrawals (7 days, 0% fee):**
- No global limit
- No fee
- Positions represented as ERC721 NFTs (`dreWithdrawalNFT` for standard queue)

```solidity
// Request express withdrawal. Returns only express NFT id; no long-queue fallback.
// All-or-nothing: reverts with NoExpressAvailable if totalUsdcAmount > expressWithdrawalAvailable.
// Slippage: reverts with SlippageExceeded if totalUsdcAmount (gross from oracle) < minUsdcAmount.
// Full dreUSDAmount is burned on success.
function requestExpressWithdrawal(
    uint256 dreUSDAmount,
    uint256 minUsdcAmount,   // Slippage protection (reverts if totalUsdcAmount < this)
    uint256 deadline
) external returns (uint256 expressTokenId);

// Request long queue withdrawal only (7 days, no fee, no express)
function requestWithdrawal(
    uint256 dreUSDAmount,
    uint256 minUsdcAmount,
    uint256 deadline
) external returns (uint256 tokenId);
```

#### Express Withdrawal Flow (requestExpressWithdrawal):
1. Check deadline and that express capacity is available
2. Use oracle to get total USDC amount for dreUSDAmount
3. Revert if totalUsdcAmount &lt; minUsdcAmount (slippage, checked on gross amount)
4. Revert if totalUsdcAmount &gt; expressWithdrawalAvailable (all-or-nothing; no partial fill)
5. Burn full dreUSDAmount from user
6. Mint single express NFT for totalUsdcAmount (fee calculated and stored)
7. Return expressTokenId only

#### Partner Fill Functions:
- `fillExpressWithdrawals(uint256[] tokenIds)` - Fill express positions (EXPRESS_OPERATOR_ROLE)
- `fillWithdrawal(uint256[] tokenIds, bool useVault)` - Fill withdrawal positions (TREASURY_ROLE)

Both follow Checks-Effects-Interactions pattern for reentrancy protection.

#### Express Filler Payback:
- `payExpressDebt(uint256 amount)` - Treasury pays express debt (USDC to payback address, increases express limit) (TREASURY_ROLE)

#### Oracle Integration:
- Chainlink price feeds validate stablecoin prices
- Minting reverts if oracle not set for stablecoin
- Reverts if price is stale or invalid
- Slippage protection via `minAmountOut`/`minUsdcAmount` parameters

#### Key Structs:

```solidity
struct FiatMint {
    bytes32 mintRef;      // Unique reference (prevents replay)
    address receiver;     // Recipient address
    uint256 usdAmount;    // USD amount (2 decimals)
    uint256 validUntil;   // Expiration timestamp
    uint256 chainId;      // Chain ID for cross-chain safety
}
```

---

### 2. dreUSD — The Base Stablecoin

**Type:** ERC-20 + EIP-2612 Permit + Upgradeable  
**Purpose:** The protocol's primary stablecoin, 1:1 backed by fiat reserves.

#### Features:
- ERC20 with EIP-2612 permit support
- 18 decimals
- Sanctions list integration (Chainalysis oracle)
- **Freeze functionality** - addresses can be frozen/unfrozen by GUARDIAN_ROLE (onlyGuardian)
- Manager-only mint/burn functions
- Upgradeable via UUPS proxy

#### Freeze System:
```solidity
// Guardian role can freeze/unfreeze addresses
function freeze(address account) external onlyGuardian;
function unfreeze(address account) external onlyGuardian;

// Transfers to/from frozen addresses revert
mapping(address => bool) public frozen;
```

---

### 3. dreUSDs — The Savings Vault

**Type:** ERC-4626 vault + Upgradeable  
**Purpose:** Yield-bearing wrapper for dreUSD stakers.

#### Features:
- ERC4626 compliant vault shares
- Queries dreRewardsDistributor for vested rewards
- `totalAssets()` = `balanceOf(self)` + `distributor.vestedAmount()`
- Claims vested rewards on deposit/withdraw (user pays gas)

---

### 4. dreUSDOracle — Price Oracle

**Type:** UUPS upgradeable contract  
**Purpose:** Validates stablecoin prices via Chainlink feeds.

#### Features:
- Per-token Chainlink aggregator configuration
- Per-token staleness thresholds
- Dynamic price decimals from Chainlink feeds
- No deviation check (slippage handled by callers via `minAmountOut`)

#### Key Functions:
```solidity
function setOracle(address token, address oracleAddress, uint256 stalenessThreshold) external;
function getUsdValue(address token, uint256 amount) external view returns (uint256);
function getTokenAmount(address token, uint256 usdAmount) external view returns (uint256);
function getPriceDecimals(address token) external view returns (uint8);
function validatePrice(address token) external view returns (bool valid);
```

---

### 5. dreWithdrawalNFT (standard & express)

**Type:** ERC721 Enumerable + Upgradeable  
**Purpose:** Represent withdrawal positions as transferable NFTs.

#### Features:
- ERC721 with enumeration for easy querying
- Stores position data: user, usdcAmount, createdAt
- Minted by dreUSDManager on withdrawal request
- Burned by dreUSDManager when position is filled
- Transferable - allows secondary market for withdrawal positions

```solidity
struct Position {
    address user;        // Original creator
    uint256 usdcAmount;  // USDC amount to receive
    uint256 createdAt;   // Creation timestamp
}
```

---

### 6. dreRewardsDistributor — Yield Streaming Engine

**Type:** UUPS upgradeable contract  
**Purpose:** Streams dreUSD rewards to stakers over a fixed vest period (e.g. 7 days). Claimed rewards are sent to an immutable vault address (dreUSDs).

#### Funding:
- **Transfer dreUSD into the distributor**, then a holder of **MODERATOR_ROLE** calls `addRewards()`.
- Normal flow: `dreUSDManager.mintRewards()` mints dreUSD to the distributor and calls `addRewards()` in one tx.
#### Mechanism:
- Linear vesting from `cTs` to `eTs`; `vestedAmount()` is claimable.
- **Vault only** can call `claimVested()` when not paused; it transfers vested dreUSD to the immutable vault address.
- dreUSDs calls `claimVested()` during deposit/withdraw so users pay gas for claiming; claimed rewards go to the distributor’s vault (dreUSDs).

---

## Access Control Roles

### dreUSDManager Roles

| Role | Permissions |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke all roles |
| `UPGRADER_ROLE` | Upgrade contract implementation |
| `KEEPER_ROLE` | Execute fiat mints (mintFromUsd) |
| `EXPRESS_OPERATOR_ROLE` | Fill express withdrawals |
| `TREASURY_ROLE` | fillWithdrawal, adminWithdraw, payExpressDebt |
| `MODERATOR_ROLE` | Config: sanctions, vault, custodian list, daily mint cap, allowed stablecoins |
| `WITHDRAWAL_CONFIG_ROLE` | Config: express payback address, express/withdrawal params, vault adapter |

### dreUSD Roles

| Role / Access | Permissions |
|---------------|-------------|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke roles, `setDreUSDManager(address)` |
| `UPGRADER_ROLE` | Upgrade contract implementation |
| `GUARDIAN_ROLE` | Freeze/unfreeze addresses (onlyGuardian) |
| **dreUSDManager** (single address) | Only this address may call `mint()` and `burn()`; set via `setDreUSDManager` |

### dreUSDOracle Roles

| Role | Permissions |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke roles |
| `UPGRADER_ROLE` | Upgrade contract implementation |
| `MODERATOR_ROLE` | Set/remove oracle feeds, update thresholds |

### Withdrawal NFT Roles

| Role / Access | Permissions |
|---------------|-------------|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke roles, `setDreUSD()`, `setDreUSDManager(address)` |
| `UPGRADER_ROLE` | Upgrade contract implementation |
| **dreUSDManager** (single address) | Only this address may call `mint()` and `burn()`; set via `setDreUSDManager` |

---

## Contract Relationships

```
┌─────────────────────────────────────────────────────────────────────┐
│                           USER FLOWS                                │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    ▼                           ▼
    ┌───────────────────────────────┐   ┌───────────────┐
    │        dreUSDManager          │   │   dreUSDs     │◄──────────────┐
    │  (mint/withdraw/positions)    │   │  (staking)    │               │
    └───────────────┬───────────────┘   └───────┬───────┘               │
                    │                           │                       │
                    │ mints/burns               │ claimVested()         │
                    ▼                           ▼                       │
            ┌───────────────┐           ┌───────────────────────┐       │
            │    dreUSD     │           │ StakingRewardsDistrib │       │
            │   (token)     │           │   (yield streamer)    │───────┘
            └───────────────┘           └───────────┬───────────┘
                    ▲                               │
                    │                   ┌───────────▼───────────┐
                    │                   │    Rewards Vault      │
                    │                   └───────────────────────┘
                    │
    ┌───────────────┴───────────────────────────────────────────┐
    │                      dreUSDManager                         │
    │                                                            │
    │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐ │
    │  │ dreUSDOracle │  │ SanctionsList│  │ Custodian Signer │ │
    │  │  (Chainlink) │  │ (Chainalysis)│  │  (Fiat Mints)    │ │
    │  └──────────────┘  └──────────────┘  └──────────────────┘ │
    │                                                            │
    │  ┌──────────────────────┐  ┌──────────────────────────┐   │
    │  │ dreWithdrawalNFT (express) │  │ dreWithdrawalNFT (standard) │   │
    │  │   (ERC721 positions) │  │   (ERC721 positions)     │   │
    │  └──────────────────────┘  └──────────────────────────┘   │
    └───────────────────────────────────────────────────────────┘
```

---

## Withdrawal Flow

### Express (requestExpressWithdrawal)

```
User calls requestExpressWithdrawal(dreUSDAmount, minUsdcAmount, deadline)
                │
                ▼
    ┌───────────────────────────┐
    │ Check deadline            │
    │ Get totalUsdcAmount via   │
    │ oracle                    │
    └───────────────────────────┘
                │
                ▼
    ┌───────────────────────────┐
    │ Revert if totalUsdcAmount │
    │   < minUsdcAmount          │
    │   (slippage on gross)      │
    │ Revert if totalUsdcAmount  │
    │   > expressWithdrawalAvailable │
    │   (all-or-nothing)         │
    └───────────────────────────┘
                │
                ▼
    ┌───────────────────────────┐
    │ Burn full dreUSDAmount    │
    │ Mint single Express NFT   │
    │ Store fee, update limits  │
    │ Return expressTokenId     │
    └───────────────────────────┘
```

### Long queue (requestWithdrawal)

Full dreUSDAmount is burned; oracle gives USDC amount; one standard withdrawal NFT is minted (7 days, no fee). No express portion.

---

## Partner Fill Flow

```
Partner calls fillExpressWithdrawals(tokenIds)
                │
                ▼
    ┌───────────────────────────────┐
    │ For each tokenId:             │
    │                               │
    │ CHECKS:                       │
    │ - Position exists?            │
    │ - Partner has USDC?           │
    │ - Owner not sanctioned?       │
    │                               │
    │ EFFECTS (reentrancy safe):    │
    │ - Delete fee mapping          │
    │ - Burn NFT                    │
    │ - Update counters             │
    │                               │
    │ INTERACTIONS:                 │
    │ - Transfer user amount        │
    │ - Transfer fee to recipient   │
    │ - Emit events                 │
    └───────────────────────────────┘
```

---

## Security Considerations

1. **Sanctions Compliance**: All transfers integrate Chainalysis oracle checks
2. **Freeze Capability**: GUARDIAN_ROLE (onlyGuardian) can freeze addresses on dreUSD
3. **Access Control**: Granular role-based permissions for all operations
4. **Oracle Validation**: Stablecoin mints require valid Chainlink price
5. **Slippage Protection**: `minAmountOut` parameters prevent price manipulation
6. **Deadline Protection**: All orders have expiration timestamps
7. **Replay Protection**: Fiat mints use unique mintRef + chainId + validUntil
8. **Custodian Signatures**: Off-chain fiat mints require custodian ECDSA signature
9. **Upgradeability**: UUPS pattern with dedicated upgrader role
10. **Reentrancy Protection**: Checks-Effects-Interactions pattern in fill functions
11. **Immutable Core Addresses**: dreUSD, dreUSDs, USDC set in constructor
12. **NFT-based Positions**: Withdrawal positions are transferable ERC721 tokens

---

## Deployment Order

1. Deploy dreUSD implementation + proxy
2. Deploy dreUSDOracle implementation + proxy
3. Deploy dreWithdrawalNFT implementation + proxy (standard)
4. Deploy dreWithdrawalNFT implementation + proxy (express)
5. Deploy dreUSDManager implementation + proxy (with dreUSD, dreUSDs, USDC addresses)
6. Deploy/designate Rewards Vault
7. Deploy dreRewardsDistributor implementation + proxy
8. Deploy dreUSDs implementation + proxy
9. Configure:
   - Set dreUSDManager on dreUSD via `setDreUSDManager(manager)` (only manager may mint/burn)
   - Set dreUSDManager on both withdrawal NFT instances via `setDreUSDManager(manager)` (only manager may mint/burn)
   - Set dreUSDManager on dreAaveAdapter via `setDreUSDManager(manager)` or in adapter `initialize` (only manager may call `withdraw()`)
   - Set oracle feeds on dreUSDOracle
   - Set oracle address on dreUSDManager
   - Set NFT addresses on dreUSDManager
   - Set custodian address on dreUSDManager
   - Set expressFeeRecipient on dreUSDManager
   - Add allowed stablecoins
   - Configure limits and caps
10. Grant roles to appropriate addresses
11. Transfer admin to multisig
