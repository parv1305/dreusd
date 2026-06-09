# Money Flows (Off-Chain Perspective)

This document describes all user flows and admin touchpoints for **USDC/USDT → dreUSD** (mint) and **dreUSD → USDC** (withdrawal), from an off-chain perspective. For each flow we list what the user does, when an admin must act, and what the admin needs (role, tokens, config).

---

## Client service & dashboard (summary)

This section summarizes the flows from a **client service / ops / dashboard** perspective: what the dashboard shows, when we need to act, and what we need to have.

### 0. Standard withdrawal (7 days): dashboard & Aave

- **User:** Requests withdrawal → dreUSD is burned → **Withdrawal NFT** is created.
- **We have 7 days** to fill the position (configurable `withdrawalWaitingTime`).
- **Dashboard:** Show each pending standard withdrawal (NFT) in the **standard / long-queue dashboard** (tokenId, owner, USDC amount, createdAt, fillable after).
- **Do we need to increase position in Aave?**
  - **Pending demand:** Sum of `position.usdcAmount` for all **fillable** withdrawal NFTs (i.e. `createdAt + withdrawalWaitingTime <= now`).
  - **Available in Aave:** Call the **vault adapter** (e.g. `dreAaveAdapter`) **`getAvailableBalance()`** — this is the USDC we can withdraw from Aave (capped by aToken balance and pool liquidity).
  - **Dashboard logic:** If **pending demand > getAvailableBalance()** → show **“Increase position in Aave”** (or top up the vault adapter’s aUSDC). When we fill, we **burn part of the Aave position** (aUSDC is redeemed via the adapter) and USDC is sent to the NFT owner.

### 1. User request: express vs normal withdrawal

**Both flows:**

- User requests withdrawal (express or normal) → **NFT is created** and should be shown in the **corresponding dashboard** (express queue vs standard/long queue).

**Express withdrawal:**

- NFT appears in the **express withdrawal dashboard**.
- After ~6h (operational target), the **wallet that calls the fill** must:
  - **Hold USDC** (at least sum of `userAmount + fee` for each position being filled).
  - **Set allowance:** `USDC.approve(dreUSDManager, amount)` so the manager can pull USDC.
- That wallet (has **EXPRESS_OPERATOR_ROLE**) calls **`fillExpressWithdrawals(tokenIds)`**. Manager pulls USDC from the caller: user amount → NFT owner, fee → express fee recipient.

**Normal (standard) withdrawal:**

- NFT appears in the **standard / long-queue dashboard**.
- We see the **position in Aave** (via the vault adapter: aUSDC balance / `getAvailableBalance()`).
- When we fill: Treasury (has **TREASURY_ROLE**) calls **`fillWithdrawal(tokenIds, useVault: true)`**. The manager uses the **vault adapter** to **withdraw USDC from Aave** (burns/redeems aUSDC) and sends USDC to the NFT owner. So we **burn part of the Aave position** (aUSDC) and fill the withdrawal.

### 2. Admin mintRewards (fiat mint → dreUSD → dreRewardsDistributor & vest)

- **Admin** selects an **amount** (USD, 2 decimals). The **receiver** must be the dreRewardsDistributor address.
- **Custodian (allowed wallet):** Signs an **EIP-712–style message** (struct: `mintRef`, `receiver`, `usdAmount`, `validUntil`, `chainId`). The contract verifies the signer is in the custodian list and uses the same struct hash (see `FiatMint` and `_computeFiatMintStructHash`). In practice this is **personal_sign** over `keccak256(abi.encode(mintRef, receiver, usdAmount, validUntil, chainId))`.
- **Keeper (broadcaster):** Must have **KEEPER_ROLE** on dreUSDManager. Calls **`mintRewards(FiatMint m, bytes custodianSig)`**. That mints dreUSD to the distributor and immediately calls **`addRewards()`** on the distributor in the same tx. No separate approval or transfer step is needed.

**Funding model:** The distributor does not pull tokens. To add rewards by other means, **transfer dreUSD into the distributor** (e.g. from an EOA or multisig), then have an address with **MODERATOR_ROLE** on the distributor call **`addRewards()`**. 

**What admin needs:**

| Step | Who | What they need |
|------|-----|-----------------|
| Sign | Custodian wallet | Be in custodian list (`updateCustodianList`). Sign FiatMint struct (mintRef, receiver=distributor, usdAmount, validUntil, chainId). |
| Broadcast mintRewards | Keeper wallet | **KEEPER_ROLE** on dreUSDManager. Call `mintRewards(m, custodianSig)` with receiver = dreRewardsDistributor. |

---

## 1. High-Level Money Flow

### 1.1 Stablecoin → dreUSD (Mint)

```
User/Depositor                    System                         Outcome
────────────────────────────────────────────────────────────────────────────
USDC/USDT (user wallet)    →    dreUSDManager (mint)    →    dreUSD (user)
                                      ↓
                              Custodian Vault
                              (receives stablecoin)
```

### 1.2 dreUSD → USDC (Withdrawal)

**Express (6h target, fee):**

```
User dreUSD  →  burn + Express NFT  →  Express Operator fills  →  User USDC (+ fee to fee recipient)
                                            ↑
                                    Partner holds USDC
                                    Later: Treasury payExpressDebt → Partner
```

**Standard (7 days, 0% fee):**

```
User dreUSD  →  burn + Withdrawal NFT  →  (wait 7 days)  →  Treasury fillWithdrawal  →  User USDC
                                                                   ↑
                                            USDC from Treasury or Vault Adapter (e.g. Aave)
```

---

## 2. User Flows: USDC/USDT → dreUSD

### 2.1 Direct Mint (ERC20 approve)

| Step | Actor | Action | Notes |
|------|--------|--------|--------|
| 1 | User | Approve dreUSDManager to spend USDC or USDT | One-time or per-tx |
| 2 | User | Call `mint(asset, amount, minAmountOut, deadline)` | `asset` = USDC or USDT |
| 3 | Contract | Pulls stablecoin from user → custodianVault; mints dreUSD to user | Oracle used for amount; sanctions checked |

**Admin:** None required for this flow.  
**Preconditions (set by admin):** `updateVault()` (custodian vault), `updateAllowedList(asset, true)`, oracle configured, sanctions list if used, contract not paused.

---

### 2.2 Direct Mint with Permit (gasless approve)

| Step | Actor | Action | Notes |
|------|--------|--------|--------|
| 1 | User | Sign EIP-2612 permit for dreUSDManager (amount, deadline) | Off-chain; no prior approve tx |
| 2 | User | Call `mint(asset, amountIn, receiver, minAmountOut, deadline, permitSig)` | Permit executed in same tx |
| 3 | Contract | Same as 2.1: stablecoin → custodianVault, dreUSD → receiver | |

**Admin:** None.  
**Preconditions:** Same as 2.1; asset must support permit (e.g. USDC with permit).

---

### 2.3 Mint From (third party pays)

| Step | Actor | Action | Notes |
|------|--------|--------|--------|
| 1 | Payer | Approve dreUSDManager or sign permit for stablecoin | |
| 2 | Anyone | Call `mintFrom(from, asset, amountIn, receiver, minAmountOut, deadline, permitSig)` | `from` = payer, `receiver` = dreUSD recipient |
| 3 | Contract | Pulls stablecoin from `from` → custodianVault; mints dreUSD to `receiver` | |

**Admin:** None.  
**Preconditions:** Same as 2.1.

---

### 2.4 Mint and Stake (deposit → dreUSDs)

| Step | Actor | Action | Notes |
|------|--------|--------|--------|
| 1 | User | Approve dreUSDManager or sign permit | |
| 2 | User | Call `mintAndStake(asset, amountIn, receiver, minAmountOut, minSharesOut, deadline, permitSig)` | |
| 3 | Contract | Stablecoin → custodianVault; dreUSD minted to manager then deposited into dreUSDs vault; **dreUSDs shares** to receiver | No dreUSD in wallet; user holds dreUSDs (staked). |

**Admin:** None.  
**Preconditions:** Same as 2.1; dreUSDs vault must be set and accept deposits.

---

### 2.5 Fiat Mint (off-chain USD → dreUSD)

| Step | Actor | Action | Notes |
|------|--------|--------|--------|
| 1 | User | Deposit USD off-chain (e.g. bank, rails) | Per partner/process |
| 2 | Custodian | Create FiatMint (mintRef, receiver, usdAmount, validUntil, chainId) and sign | Must be in custodian list |
| 3 | Keeper | Call `mintFromUsd(FiatMint, custodianSig)` | On-chain submission |
| 4 | Contract | Validates signature, daily cap, mintRef unused; mints dreUSD to receiver | No on-chain stablecoin from user |

**Admin / Ops:**

| When | Who | Action | What they need |
|------|-----|--------|----------------|
| Before any fiat mint | Moderator | Add custodian signers | `MODERATOR_ROLE`, call `updateCustodianList(custodian, true)` |
| Before any fiat mint | Moderator | Set daily cap | `MODERATOR_ROLE`, `setDailyFiatMintCap(usdAmount2Decimals)` |
| Per mint | Keeper | Submit signed FiatMint | `KEEPER_ROLE`; FiatMint + signature from custodian |

**Preconditions:** Custodian list, daily cap > 0, contract not paused. Receiver not sanctioned if sanctions list set.

---

## 3. User Flows: dreUSD → USDC

### 3.1 Standard Withdrawal (7 days, 0% fee)

| Step | Actor | Action | Notes |
|------|--------|--------|--------|
| 1 | User | Call `requestWithdrawal(dreUSDAmount, minUsdcAmount, deadline)` | User must hold dreUSD |
| 2 | Contract | Burns user’s dreUSD; mints **Withdrawal NFT** (position = USDC amount from oracle) | Oracle used for dreUSD → USDC amount |
| 3 | User | Waits `withdrawalWaitingTime` (e.g. 7 days) | NFT can be transferred; fill goes to current owner |
| 4 | Treasury | Call `fillWithdrawal(tokenIds, useVault)` | See admin table below |
| 5 | Contract | Burns NFT; sends USDC to NFT owner | Source: vault adapter or treasury wallet |

**Admin:**

| When | Who | Action | What they need |
|------|-----|--------|----------------|
| Before first fill | Moderator / Withdrawal Config | Custodian vault (deposit); withdrawal config | Moderator: `updateVault()`. Withdrawal Config: `updateWithdrawal(waitingTime)`, `updateVaultAdapter(adapter)` if using vault |
| When positions are ready | Treasury | Fill standard withdrawals | `TREASURY_ROLE`. **If useVault = false:** Treasury wallet must hold enough USDC and must approve dreUSDManager. **If useVault = true:** Vault adapter (e.g. Aave) must have enough USDC and be set via `updateVaultAdapter()` |

**Preconditions:** Oracle configured; withdrawal NFT contract and waiting time set; sanctions checked at fill time for NFT owner.

---

### 3.2 Express Withdrawal (6h target, fee)

| Step | Actor | Action | Notes |
|------|--------|--------|--------|
| 1 | User | Call `requestExpressWithdrawal(dreUSDAmount, minUsdcAmount, deadline)` | Requires `expressWithdrawalAvailable > 0`; reverts if oracle USDC amount > available (all-or-nothing) or < minUsdcAmount (slippage) |
| 2 | Contract | Burns full dreUSDAmount; mints **Express NFT** (user amount + fee stored); decreases `expressWithdrawalAvailable` | Fee goes to express fee recipient when filled |
| 3 | Express Operator | Call `fillExpressWithdrawals(tokenIds)` | See admin/partner table below |
| 4 | Contract | Burns Express NFT; sends **user USDC** to NFT owner; sends **fee USDC** to express fee recipient; increases `expressFillerDebt` | Operator must hold userAmount + fee per position |
| 5 | Treasury (later) | Call `payExpressDebt(amount)` | Sends USDC to express payback address (partner); reduces debt; frees express capacity |

**Admin / Partner:**

| When | Who | Action | What they need |
|------|-----|--------|----------------|
| Before first express request | Withdrawal Config | Set express limit, fee, fee recipient | `WITHDRAWAL_CONFIG_ROLE`: `updateExpressWithdrawal(maxLimit, feeBps, feeRecipient)` (express NFT set at deploy) |
| Before first express request | Withdrawal Config | Set express payback address (partner) | `updateExpressPaybackAddress(partnerAddress)` |
| When express positions exist | Express Operator (partner) | Fill express NFTs | `EXPRESS_OPERATOR_ROLE`; **USDC balance** ≥ sum of (userAmount + fee) for each position; **approve** dreUSDManager to spend that USDC |
| After fills (periodically) | Treasury | Pay back express filler | `TREASURY_ROLE`; **USDC** to send; **approve** dreUSDManager. Calls `payExpressDebt(amount)`; USDC goes to express payback address; `expressWithdrawalAvailable` increases |

**Preconditions:** Express config (NFT, limit, fee, fee recipient, payback address), oracle, sanctions at fill time. Express fee recipient can be Treasury (same multisig).

---

## 4. Admin-Only Flows (No User in the Loop)

### 4.1 Sweep Tokens from Manager (adminWithdraw)

| When | Who | Action | What they need |
|------|-----|--------|----------------|
| Manager holds tokens (e.g. accidental send or operational) | Treasury | Call `adminWithdraw(token, to, amount)` | `TREASURY_ROLE`. Transfers `token` from **dreUSDManager** to `to` (e.g. Treasury multisig). Manager must hold ≥ `amount` of `token`. |

Use case: Move USDC/USDT or other tokens that sit on the manager contract to Treasury or another vault.

---

## 5. Summary: When Admin Must Do Something

| Flow | Admin / Role | When | What they need |
|------|--------------|------|----------------|
| Fiat mint | Moderator | Before fiat mints | Add custodians (`updateCustodianList`), set daily cap (`setDailyFiatMintCap`) |
| Fiat mint | Keeper | Each fiat mint | Signed FiatMint; `KEEPER_ROLE` |
| Standard withdrawal | Treasury | When positions are ready (after waiting time) | `TREASURY_ROLE`; USDC (and approve manager) **or** vault adapter with liquidity |
| Express withdrawal | Express Operator | When filling express NFTs | `EXPRESS_OPERATOR_ROLE`; USDC (userAmount + fee per position); approve manager |
| Express payback | Treasury | After express fills (to refill capacity) | `TREASURY_ROLE`; USDC; approve manager; `payExpressDebt(amount)` to express payback address |
| Sweep manager | Treasury | When manager has stray tokens | `TREASURY_ROLE`; `adminWithdraw(token, to, amount)` |

---

## 6. Summary: One-Time or Rare Config (Admin)

These are not per-user flows but must be in place for the above to work:

| Config | Role | Function | Purpose |
|--------|------|----------|--------|
| Custodian vault | Moderator | `updateVault(address)` | Where USDC/USDT from mints goes |
| Allowed stablecoins | Moderator | `updateAllowedList(token, true)` | Allow USDC, USDT, etc. for mint |
| Sanctions | Moderator | `setSanctionsList(address)` | Optional; used in mint/withdrawal checks |
| Oracle | Set at deploy | Immutable on manager | dreUSD ↔ USDC pricing |
| Withdrawal / Express NFT contracts | Deploy | Constructor args | Set at deploy (immutable); standard and express NFT contract addresses |
| Withdrawal waiting time | Withdrawal Config | `updateWithdrawal(waitingTime)` | Standard queue wait (e.g. 7 days) |
| Withdrawal source | Withdrawal Config | `updateVaultAdapter(adapter)` | Optional; e.g. Aave for fill source |
| Express queue params | Withdrawal Config | `updateExpressWithdrawal(maxLimit, feeBps, feeRecipient)` | Global limit, fee bps, fee recipient (e.g. Treasury) |
| Express payback | Withdrawal Config | `updateExpressPaybackAddress(address)` | Partner address that receives payExpressDebt |

---

## 7. Quick Reference: Money Direction

| Direction | User flow | Where stablecoin comes from | Where stablecoin goes | Where dreUSD goes |
|-----------|-----------|-----------------------------|------------------------|-------------------|
| USDC/USDT → dreUSD | mint / mintFrom / mintAndStake | User (or `from`) | Custodian vault | User (or receiver) |
| USDC/USDT → dreUSD | mintFromUsd (fiat) | Off-chain (no on-chain stablecoin) | — | Receiver |
| dreUSD → USDC | requestWithdrawal | — | — | Burned |
| dreUSD → USDC | fillWithdrawal | Treasury or vault adapter | NFT owner | — |
| dreUSD → USDC | requestExpressWithdrawal | — | — | Burned |
| dreUSD → USDC | fillExpressWithdrawals | Express operator | NFT owner (user amount) + fee recipient (fee) | — |
| dreUSD → USDC | payExpressDebt | Treasury | Express payback address (partner) | — |
