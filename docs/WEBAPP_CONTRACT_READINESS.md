# Webapp–Contract Readiness

This document maps **webapp features** (from the DRE app PRD) to the **current smart contracts** and calls out what is **not possible or only partly possible** today, including what the app needs for transaction history and notifications. Use it for code freeze and front-end planning.

---

## Summary: What Works vs What Doesn’t

| Area | Works today | Gaps / limitations |
|------|-------------|---------------------|
| **Balance (cash + savings)** | ✅ dreUSD + dreUSDs balances, totalAssets | — |
| **Deposit (USDC/USDT → dreUSD)** | ✅ mint / mintAndStake; events for history | — |
| **Transfer (dreUSD ↔ dreUSDs)** | ✅ deposit/redeem on vault | — |
| **Withdraw (dreUSD → USDC)** | ✅ Express + Long queue flows | ⚠️ No single “request withdrawal”; no `withdrawalStatus(user)`; app must use NFTs |
| **Transaction history** | ⚠️ Via events only; no `withdrawalStatus(owner)` | See “Transaction history” below |
| **Yield “yesterday” / “est. monthly”** | ⚠️ Computable from vault share price / totalAssets | No dedicated event per user per day |
| **Pending withdrawals (per user)** | ⚠️ Via NFT ownership + events | No single view; need indexer + `balanceOf` / `tokenOfOwnerByIndex` |
| **Notifications (deposit/withdrawal fulfilled)** | ✅ Events exist and can be indexed | Indexer required |
| **Transparency dashboard** | ⚠️ TVL/yield from views; no PoR feed | See “Transparency dashboard” |
| **1-click unstake + request withdrawal** | ❌ No `unstakeAndRequestWithdraw` | User must redeem then request in two steps |
| **Min/max withdrawal limits** | ❌ No setMinWithdrawalAmount / setMaxWithdrawalAmount | — |

---

## 1. Transaction history

**App need:** “Transaction history for each asset”, “Display the last 3 transactions”, “Clicking on a transaction takes a user to transaction information”, “Transaction history that a user would expect in any modern banking app.”

**What the contracts provide:**

- **dreUSD:** Standard ERC-20 `Transfer(from, to, value)`. Index by `from` or `to` = user address.
- **dreUSDs:** ERC-4626 `Deposit(sender, owner, assets, shares)` and `Withdraw(sender, receiver, owner, assets, shares)`. Index by `owner` or `receiver` (and `sender` where relevant).
- **Manager:**  
  - `Minted(receiver, asset, amountIn, dreUsdOut)`  
  - `MintedFrom(from, receiver, asset, amountIn, dreUsdOut)`  
  - `MintAndStake(receiver, asset, amountIn, dreUsdsOut)`  
  - `CustodianFiatMinted(mintRef, receiver, usdAmount, signer)`  
  - `WithdrawRequested(user, dreUSDAmount, totalUsdcAmount, expressUsdcAmount, withdrawalUsdcAmount, expressFeeAmount, expressTokenId, withdrawalTokenId)`  
  - `ExpressWithdrawalRequested(user, tokenId, dreUSDAmount, usdcAmount, feeAmount)`  
  - `WithdrawalRequested(user, tokenId, dreUSDAmount, usdcAmount)`  
  - `ExpressWithdrawalFilled(tokenId, user, usdcAmount, filler)`  
  - `WithdrawalFilled(tokenId, user, usdcAmount, filler)`  
- **NFTs:** `PositionCreated(tokenId, user, usdcAmount, timestamp)` and `PositionFilled(tokenId, owner, usdcAmount, filler)` on Express and Long Queue NFTs.

**Conclusion:**  
Transaction history **is possible** only by **indexing these events** (e.g. The Graph, Envio, or backend indexer). There is **no on-chain “get history for user” view**. For withdrawals, the app must correlate `WithdrawRequested` / `ExpressWithdrawalRequested` / `WithdrawalRequested` with `*WithdrawalFilled` (and NFT `PositionCreated` / `PositionFilled`) to show “pending” vs “fulfilled”.

---

## 2. Pending withdrawals and “withdrawal status”

**App need:** “Request withdrawal option from dreUSD to USDC”, “Withdrawal requests … user sees this in the Transaction history”, “Withdrawal fulfilled … notification”, “Review withdrawal” / “Withdraw USDC” flow.

**What the contracts provide:**

- Two separate flows: **Express** (request → express NFT) and **Long queue** (request → long-queue NFT). There is **no single `requestWithdrawal(amount)`** that returns one “request id” and one status.
- **No** `withdrawalStatus(owner)` (or similar) that returns a list of pending requests for a user.
- To get “all pending withdrawals for user” the app must:
  - Query both **dreWithdrawalNFT** instances (express and standard) for tokens owned by the user (e.g. `balanceOf(user)`, `tokenOfOwnerByIndex(user, i)` if using Enumerable).
  - For each tokenId call `getPosition(tokenId)` to get `usdcAmount`, `createdAt`, etc.
  - Use **events** to know when a position is filled (`ExpressWithdrawalFilled`, `WithdrawalFilled`, `PositionFilled`).

**Conclusion:**  
“Request withdrawal” and “withdrawal fulfilled” **are possible**, but the app must implement **NFT-based pending state** and event indexing. There is no single contract view that returns “user’s pending withdrawal requests” or “withdrawal status(owner)”.

---

## 3. Notifications (in-app / email)

**App need:** “Deposit completed – in app only”, “Funds received – in app + email”, “Withdrawal fulfilled – in app + email”.

**What the contracts provide:**

- **Deposit completed:** `Minted(receiver, …)`, `MintedFrom(…, receiver, …)`, `MintAndStake(receiver, …)`, `Deposit(..., owner, ...)` on dreUSDs. Index by `receiver`/`owner` and block timestamp.
- **Funds received:** Same events; “receiver” is the user who received dreUSD/dreUSDs.
- **Withdrawal fulfilled:** `ExpressWithdrawalFilled(tokenId, user, usdcAmount, filler)` and `WithdrawalFilled(tokenId, user, usdcAmount, filler)`. Index by `user`.

**Conclusion:**  
All notification triggers **exist as events**. The app needs an **indexer / backend** that subscribes to these events and pushes to in-app and email. No contract change required for “is this possible?” — only indexing and notification delivery.

---

## 4. Home page: balance, tabs, yield

**App need:** “Neobank style hero balance in USD”, “Account separation Tabs … cash and savings”, “Yield forward display”, “On the savings tab … how much they earned yesterday, and est. earnings monthly”.

**What the contracts provide:**

- **Cash balance:** `IERC20(dreUSD).balanceOf(user)`.
- **Savings balance:** `IERC4626(dreUSDs).balanceOf(user)` in shares; USD value = `convertToAssets(balanceOf(user))` or equivalent (shares × totalAssets / totalSupply).
- **Total USD:** Sum of (dreUSD balance + dreUSDs value in assets). Oracle not required for this; vault’s `convertToAssets` uses `totalAssets()` which includes vested rewards.
- **Yield “yesterday” / “est. monthly”:** Not stored per user on-chain. The app can:
  - Store previous `totalAssets()` / share price at UTC midnight and compare to current to approximate “yesterday’s” yield for the vault; and/or
  - Use `rewardRatePerSecond` (and `vestedAmount()`) from dreRewardsDistributor to show estimated stream; no per-user breakdown on-chain.

**Conclusion:**  
Balance and tabs **work**. “Yesterday’s earnings” and “est. monthly” are **derivable only via off-chain or indexer logic** (e.g. snapshots of vault share price or reward rate), not via a single contract view.

---

## 5. Withdraw flow (USDC send)

**App need:** “Withdraw” → “Menu with USDC balance” → “Send” → “Select address, amount” → “Review withdrawal” → “Withdraw USDC” → “Request withdrawal option from dreUSD to USDC”.

**What the contracts provide:**

- **Sending USDC** (already held): Not a manager function; user signs a normal USDC transfer. Contracts don’t hold user’s USDC for “withdraw” in that sense.
- **Redeeming dreUSD → USDC (request then fulfill):**  
  - User burns dreUSD and gets either an **Express** or **Long queue** NFT (and later receives USDC when the position is filled).  
  - So the app flow is: user chooses “request withdrawal” (dreUSD → USDC), then either **Express** (e.g. 6h, fee) or **Long queue** (e.g. T+7). No single “request withdrawal” that hides express vs long queue.

**Conclusion:**  
“Withdraw USDC” (from dreUSD) **is possible** using existing request + NFT + fill flows. The app must expose **two paths** (Express vs Long queue) or choose one as default. There is **no** single “request withdrawal” that returns one generic “pending withdrawal” list without NFT-based logic.

---

## 6. Transparency dashboard

**App need:** “Transparency dashboard showing users where the funds are deposited and where yield is coming from”, “Weekly reserve attestations”, “Table showing dreUSD asset allocation”, “Charts showing historical TVL … historical APY”.

**What the contracts provide:**

- **TVL (vault):** `dreUSDs.totalAssets()`; dreUSD supply: `dreUSD.totalSupply()`.
- **Yield stream:** `dreRewardsDistributor.vestedAmount()`, `cTs()`, `eTs()`, `rewards()`; use `dreUSD.balanceOf(distributor)` and `dreUSD.balanceOf(vault)` for balances.
- **No** Chainlink Proof-of-Reserve feed integration, **no** on-chain “asset allocation” or “where funds are deposited” (that’s off-chain custody data). No dedicated events for “attestation epoch” or “reserve report”.

**Conclusion:**  
TVL and current yield **can** be read from contracts. **Historical** TVL/APY and **reserve/attestation** data require off-chain or indexer data (and possibly PoR feed later). Transparency dashboard is **partly possible** from chain data only.

---

## 7. Features that are not possible with current contracts

- **withdrawalStatus(owner)** — No view returning “list of pending withdrawals for this user”. App must use NFT ownership + `getPosition` + events.
- **unstakeAndRequestWithdraw** — No 1-click “redeem dreUSDs → dreUSD then request withdrawal”. User must: (1) redeem dreUSDs for dreUSD, (2) call request express or long queue.
- **setMinWithdrawalAmount / setMaxWithdrawalAmount** — Not in contracts; app cannot show or enforce min/max from chain (could enforce in UI only).
- **Single “request withdrawal”** — No one function that takes “amount” and returns one request id; there are two flows (Express / Long queue) with NFTs.
- **Per-user “yesterday’s earnings”** — No contract view; must be derived (e.g. share price snapshots or indexer).
- **Proof-of-Reserve / reserve breakdown** — Not on-chain; attestations and allocation are off-chain.

---

## 8. Event indexer checklist (for transaction history + notifications)

To support “transaction history per user” and “Deposit completed / Funds received / Withdrawal fulfilled” notifications, the indexer (or subgraph) should at least:

| Event (contract) | Index by | Use case |
|------------------|----------|----------|
| `Transfer` (dreUSD) | from, to | dreUSD moves; “funds received” |
| `Deposit`, `Withdraw` (dreUSDs) | owner, receiver, sender | Stake/unstake history |
| `Minted`, `MintedFrom`, `MintAndStake` (Manager) | receiver, from | Deposit completed; funds received |
| `CustodianFiatMinted` (Manager) | receiver | Fiat deposit completed |
| `WithdrawRequested` (Manager) | user | User initiated withdrawal (combined) |
| `ExpressWithdrawalRequested`, `WithdrawalRequested` (Manager) | user | Pending express/withdrawal |
| `ExpressWithdrawalFilled`, `WithdrawalFilled` (Manager) | user | Withdrawal fulfilled notification |
| `PositionCreated`, `PositionFilled` (Express/Withdrawal NFT) | user (from event) | Pending vs filled for NFTs |

Optional: `RewardsClaimed` (dreRewardsDistributor) for “yield distributed to vault” (not per user).

---

## 9. Recommended app-side workarounds before code freeze

1. **Transaction history:** Implement an **event indexer** (or use The Graph / Envio) that indexes the events above and exposes “transactions for user” and “pending withdrawals for user” (via NFT ownership + positions).
2. **Pending withdrawals:** Query Express and Long Queue NFT contracts for `balanceOf(user)` and `tokenOfOwnerByIndex` (if available); for each tokenId call `getPosition(tokenId)`; treat “not yet filled” as pending (using `PositionFilled` events to mark filled).
3. **Withdraw UX:** Either expose “Express” vs “Long queue” explicitly, or choose one as default and document the other for power users.
4. **Yield “yesterday” / “est. monthly”:** Compute from vault share price (and optionally `rewardRatePerSecond` / `vestedAmount`) in the backend or frontend; no new contract view strictly required.
5. **Notifications:** Drive all “Deposit completed”, “Funds received”, “Withdrawal fulfilled” from the indexed events above; no contract changes needed.

---

## References

- Contract implementation status: [IMPLEMENTATION_STATUS.md](./IMPLEMENTATION_STATUS.md)
- Roles and permissions: [ROLES.md](./ROLES.md)
- Interfaces and events: `contracts/interfaces/IdreUSDManager.sol`, `IdreUSD.sol`, `IdreUSDs.sol`, `IWithdrawalNFT.sol`
