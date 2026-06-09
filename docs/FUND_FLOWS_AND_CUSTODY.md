# Fund Flows and Custody (Compliance)

This document states the **exact** fund flow from user to off-chain, where USDC/USDT sits after deposit, which contract or wallet holds funds in each flow, and how to assign **contract or multisig/wallet ownership to specific entities** for compliance. There is no room for misinterpretation: all statements below are derived from the on-chain logic in `dreUSDManager.sol` and `dreAaveAdapter.sol`.

---

## 1. Exact fund flow from user to off-chain

### 1.1 Deposit / mint flow (user → dreUSD)

**On-chain path (user deposits USDC or USDT and receives dreUSD):**

1. **User** holds USDC or USDT in their wallet.
2. User calls one of: `mint()`, `mint(..., permitSig)`, `mintFrom()`, or `mintAndStake()` on **dreUSDManager**.
3. **dreUSDManager** pulls the stablecoin from the user (via `transferFrom`) and sends it in the **same transaction** to a single destination:
   - **Destination:** the address stored in **`custodianVault`** (set by Moderator via `updateVault()`).
4. **dreUSDManager** mints dreUSD to the user (or to the receiver / to itself for staking, depending on the function).
5. **Off-chain:** The stablecoin now sits in **`custodianVault`**. That address is a **contract or wallet** (in practice a multisig). Whoever controls that address controls the funds. There is **no further automatic movement** of that USDC/USDT from `custodianVault`; any movement is by that entity’s own actions (e.g. moving to a bank, to Aave, etc.).

**Summary:**  
**User wallet → (one tx) → dreUSDManager (logic only) → custodianVault.**  
The dreUSDManager contract **does not hold** the user’s USDC/USDT; it only routes it to `custodianVault`.

**Fiat mint (`mintFromUsd`):**  
No on-chain stablecoin from the user. USD is deposited off-chain (e.g. bank); a custodian signs; Keeper calls `mintFromUsd`; dreUSD is minted to a receiver. **Off-chain USD** sits wherever the bank/rails hold it; no USDC/USDT is deposited on-chain in this flow.

---

### 1.2 Withdrawal flow (dreUSD → user gets USDC)

**Standard withdrawal (7-day queue):**

1. User calls **`requestWithdrawal(dreUSDAmount, ...)`** on dreUSDManager. dreUSD is **burned** from the user; a **Withdrawal NFT** is minted (claim to USDC later).
2. After the waiting period (e.g. 7 days), **Treasury** (or an address with TREASURY_ROLE) calls **`fillWithdrawal(tokenIds, useVault)`**.
   - **If `useVault == true`:**  
     dreUSDManager calls **`withdrawalVaultAdapter.withdraw(usdcAmount, currentOwner)`**.  
     - The adapter (e.g. **AaveV3LongQueueAdapter**) pulls **aUSDC** from the **adapter’s `vault`** (see below) to the adapter, then calls Aave to withdraw; Aave burns aUSDC and sends **USDC** to **currentOwner** (the NFT owner).  
     - So: **aUSDC** was sitting in the **adapter’s vault**; after the tx, **USDC** is in the **user’s wallet**.
   - **If `useVault == false`:**  
     dreUSDManager does **`safeTransferFrom(msg.sender, currentOwner, usdcAmount)`** in USDC. So **msg.sender** (Treasury wallet) must hold USDC and have approved dreUSDManager. After the tx, USDC is in the **user’s wallet**.

**Express withdrawal (6h target, fee):**

1. User calls **`requestExpressWithdrawal(...)`**. dreUSD is **burned**; an **Express NFT** is minted.
2. **Express Operator** (EXPRESS_OPERATOR_ROLE) calls **`fillExpressWithdrawals(tokenIds)`**.  
   - dreUSDManager does **`safeTransferFrom(msg.sender, currentOwner, userAmount)`** and **`safeTransferFrom(msg.sender, expressFeeRecipient, feeAmount)`** in USDC.  
   - So **msg.sender** (Express Operator wallet) holds the USDC until the tx; after the tx, **user amount** is in the **user’s wallet**, **fee** is in **expressFeeRecipient**.
3. **Treasury** later calls **`payExpressDebt(amount)`**. dreUSDManager does **`safeTransferFrom(msg.sender, expressPaybackAddress, amount)`**. So **Treasury** holds USDC until that tx; after the tx, USDC is in **expressPaybackAddress** (partner).

---

## 2. Where does USDT/USDC sit after the user deposits and receives dreUSD?

**Answer:**  
**In the address stored in dreUSDManager’s `custodianVault`.**

- That address is the **only** on-chain destination for stablecoin in the deposit/mint flow (mint, mintFrom, mintAndStake).
- It is set by Moderator via **`updateVault(address)`**.
- In production it should be a **multisig or vault contract**; whoever controls that address holds the USDC/USDT for compliance purposes.
- Optionally, `custodianVault` can be a **`dreVault`** (hop 1) that auto-forwards USDC to a downstream vault or corporate wallet via Chainlink Automation — see [DRE_VAULT.md](./DRE_VAULT.md).

The **dreUSDManager contract** does **not** hold user USDC/USDT in the deposit flow; it only forwards it to `custodianVault` in the same transaction.

---

## 3. Exactly what contract or wallet holds funds (deposit vs withdrawal)

### 3.1 Deposit / mint flow

| Holder | What it holds | When |
|--------|----------------|------|
| **`custodianVault`** (address in dreUSDManager, set via `updateVault()`) | **All USDC and USDT** deposited by users via `mint()`, `mintFrom()`, `mintAndStake()` | After each deposit tx; holds the balance until the owner moves it. |
| **dreUSDManager** | Does **not** hold user USDC/USDT in normal deposit flow. May hold tokens only if sent there by mistake; then **Treasury** can move them via **`adminWithdraw(token, to, amount)`**. | N/A for normal flow. |

**Fiat mint:** No USDC/USDT on-chain from the user; off-chain USD is at the bank/rails.

### 3.2 Withdrawal flow

| Holder | What it holds | When |
|--------|----------------|------|
| **Standard, `useVault == true`:** **Vault** configured on **withdrawalVaultAdapter** (e.g. **dreAaveAdapter.vault**) | **aUSDC** (Aave interest-bearing USDC). This is the “position in Aave” used to fill standard withdrawals. | Until Treasury calls `fillWithdrawal(..., true)`; then aUSDC is withdrawn via the adapter and USDC is sent to the NFT owner. |
| **Standard, `useVault == false`:** **Treasury** (the wallet that has TREASURY_ROLE and calls `fillWithdrawal`) | **USDC** that will be sent to users when filling. | Treasury must hold and approve USDC before calling `fillWithdrawal(..., false)`. |
| **Express:** **Express Operator** wallet (the address that has EXPRESS_OPERATOR_ROLE and calls `fillExpressWithdrawals`) | **USDC** (user amount + fee) for each position filled. | Must hold and approve USDC before calling `fillExpressWithdrawals`; after the tx, user amount → user, fee → expressFeeRecipient. |
| **Express fee recipient** (`expressFeeRecipient` in dreUSDManager) | **USDC** (express withdrawal fees). | After each express fill; set via `updateExpressWithdrawal(..., feeRecipient)`. |
| **Express payback** (`expressPaybackAddress` in dreUSDManager) | **USDC** sent by Treasury when calling **`payExpressDebt(amount)`**. | After Treasury runs `payExpressDebt`; this is the partner (express filler) address. |
| **Treasury** (wallet that calls `payExpressDebt`) | **USDC** used to pay back the express filler. | Must hold and approve USDC before calling `payExpressDebt`; after the tx, USDC is at `expressPaybackAddress`. |
| **dreUSDManager** | Does **not** hold user USDC in normal withdrawal flow. It only pulls from the above (adapter, Treasury, or Express Operator) and sends to users/fee recipient/payback address. | N/A for normal flow. |

---

## 4. Assigning contract or multisig/wallet ownership (for compliance)

Use the table below to assign **ownership / responsibility** of each holding address to a **specific entity** (e.g. “DRE Treasury”, “Partner”, “Custodian”). All addresses are either set in dreUSDManager or in the vault adapter; the entity that controls the private keys or multisig for that address is the one to assign for compliance.

| Contract or wallet (on-chain address) | What it holds | Suggested entity (assign for compliance) |
|---------------------------------------|----------------|------------------------------------------|
| **`custodianVault`** (dreUSDManager state; set via `updateVault()`) | All USDC/USDT from user deposits (mint / mintFrom / mintAndStake) | **Deposit / Custodian Vault** – e.g. “DRE Custodian” or the multisig that receives user deposits. |
| **Vault** on **dreAaveAdapter** (`adapter.vault`) | aUSDC (Aave position) used to fill **standard** withdrawals | **Withdrawal liquidity** – e.g. “DRE Treasury” or the multisig that holds the Aave position for long-queue fills. |
| **Treasury** (wallet with TREASURY_ROLE that calls `fillWithdrawal(..., false)` and/or `payExpressDebt`) | USDC for standard fills (when not using vault) and for express payback | **Treasury** – e.g. “DRE Treasury” multisig. |
| **Express Operator** (wallet with EXPRESS_OPERATOR_ROLE that calls `fillExpressWithdrawals`) | USDC at fill time (user amount + fee) | **Express filler / partner** – e.g. “Express Partner” or the entity that fills express withdrawals. |
| **`expressFeeRecipient`** (set in dreUSDManager via `updateExpressWithdrawal(..., feeRecipient)`) | USDC (express withdrawal fees) | **Fee recipient** – often same as Treasury, e.g. “DRE Treasury”. |
| **`expressPaybackAddress`** (set in dreUSDManager via `updateExpressPaybackAddress()`) | USDC sent when Treasury calls `payExpressDebt()` | **Express payback** – partner’s address, e.g. “Express Partner” (not DRE’s multisig). |
| **dreUSDManager** (contract) | No user funds in normal operation; may hold tokens only if sent by mistake; Treasury can sweep with `adminWithdraw` | **Protocol** – no custody assignment for user funds; assign “Protocol” or “DRE” for the contract itself. |

**Summary for compliance:**

- **User deposits (USDC/USDT):**  
  → **Single holder:** **`custodianVault`**.  
  → Assign ownership of **`custodianVault`** to the entity responsible for user deposits (e.g. DRE Custodian multisig).

- **Standard withdrawal (7-day):**  
  → **USDC source:** either **(a)** the **adapter’s vault** (aUSDC in Aave) or **(b)** the **Treasury** wallet.  
  → Assign **(a)** to the entity that holds the Aave position (e.g. DRE Treasury), **(b)** to the Treasury multisig.

- **Express withdrawal:**  
  → **At fill:** USDC from **Express Operator** → user + **expressFeeRecipient**.  
  → **Payback:** USDC from **Treasury** → **expressPaybackAddress**.  
  → Assign: Express Operator and expressPaybackAddress → partner; expressFeeRecipient and Treasury → DRE Treasury (or as you name them).

This document is the single source of truth for fund flow and custody; assign the “Suggested entity” column to your actual legal/entity names for compliance.
