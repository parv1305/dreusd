# DRE Stablecoin — Implementation Status

This document tracks implementation status against the **DRE Stablecoin Requirements** (product/requirements doc). It is a living summary for development and audit planning.

---

## Contract Overview

| Contract | Status | Notes |
|----------|--------|--------|
| **dreUSD** | ✅ Implemented | ERC-20 + EIP-2612 + OFT; role-gated mint/burn; freeze; sanctions |
| **dreUSDs** | ✅ Implemented | ERC-4626 vault; pausable; yield via dreRewardsDistributor |
| **dreUSDManager** | ✅ Implemented | Mint/mintFrom/mintAndStake/mintFromUsd; express + withdrawal (NFT-based) |
| **dreUSDOracle** | ✅ Implemented | Chainlink price feeds; staleness; getUsdValue / getTokenAmount |
| **dreRewardsDistributor** | ✅ Implemented | Streaming yield (rate + vestedAmount); claimVested by vault; pausable |
| **CustodianRouter** | ❌ Not implemented | Requirements describe separate router for sweep/disburse/staged/custodians |
| **dreWithdrawalNFT** | ✅ Implemented | Withdrawal queue (standard and express; two instances: 7 days 0% fee, 6h 50 bps fee) |
| **dreAaveAdapter** | ✅ Implemented | Adapter for withdrawal USDC sourcing (e.g. Aave) |

---

## Implemented vs Requirements

### dreUSD (Base Stablecoin)

| Requirement | Status |
|-------------|--------|
| ERC-20 + EIP-2612 + LayerZero OFT | ✅ |
| Mint/burn restricted to dreUSDManager | ✅ Single address via `dreUSDManager` (set by DEFAULT_ADMIN); not a role |
| Address freeze | ✅ freeze / unfreeze (GUARDIAN_ROLE / onlyGuardian) |
| Sanctions (e.g. Chainalysis) | ✅ setSanctionsList; checks on transfer/permit |
| 1:1 redeemable for USDC | ✅ Via manager withdrawal flows |

---

### dreUSDs (Savings Vault)

| Requirement | Status |
|-------------|--------|
| ERC-4626, underlying dreUSD | ✅ |
| Instant stake/unstake | ✅ |
| totalAssets includes yield | ✅ super.totalAssets() + vestedAmount() from distributor |
| Vault does not pull rewards | ✅ Rewards claimed by vault via claimVested (pull) |
| Pausable deposit/withdraw | ✅ PausableUpgradeable + PAUSER_ROLE |
| LayerZero / Ovault | ✅ Per BRIDGING.md, OVAULT.md |

---

### dreUSDManager (Supply Controller)

| Requirement | Status |
|-------------|--------|
| mint(asset, amountIn, receiver, permit2Sig) | ✅ |
| mintFrom(from, asset, amountIn, receiver, permit2Sig) | ✅ |
| mintAndStake(asset, amountIn, receiver, minSharesOut, permit2Sig) | ✅ |
| mintFromUsd(FiatMint, custodianSig) | ✅ KEEPER_ROLE; EIP-712; daily cap; mintRef replay guard |
| Sanctions on mint/redeem | ✅ |
| Oracle-based peg / USD value | ✅ getUsdValue, getTokenAmount |
| FIFO + Express redemption | ✅ Express (NFT) + Withdrawal (NFT + adapter) |
| Pause (mint/withdraw) | ✅ PAUSER_ROLE |
| Custodian list (add/remove) | ✅ updateCustodianList(address, bool) (MODERATOR_ROLE) |
| requestWithdrawal(assetsIn) | ⚠️ Different shape: requestWithdrawal(dreUSDAmount, …) and requestExpressWithdrawal(…) with NFTs |
| fulfillWithdrawal(ids, amounts) | ⚠️ Different: fillWithdrawal / fillExpressWithdrawals (treasury/partner + adapter) |
| setMinWithdrawalAmount / setMaxWithdrawalAmount | ❌ Not present |
| withdrawalStatus(owner) view | ❌ Not present (withdrawals are NFT-based; no single owner-status view) |
| unstakeAndRequestWithdraw (1-click from dreUSDs) | ❌ Not present |
| CustodianRouter integration (stage → sweep → disburseBatch) | ❌ No CustodianRouter; manager/adapter handle flows |

---

### CustodianRouter (Requirements)

| Requirement | Status |
|-------------|--------|
| sweep(token, maxAmount) | ❌ Contract not implemented |
| disburseBatch(token, recipients, amounts, reason) | ❌ |
| staged balances | ❌ |
| updateCustodianList(address, bool) | ❌ (custodians live on dreUSDManager in current design) |
| dailySweepCap / dailyDisburseCap / expressBudget | ❌ |
| setPaused / setInstantBudget | ❌ |
| Events: SweepPerformed, Disbursed, CustodianAdded/Removed | ❌ |

---

### dreRewardsDistributor (Yield)

| Requirement | Status |
|-------------|--------|
| Receives dreUSD from custodians / keeper | ✅ Funding by transfer into distributor, then addRewards(); no pull/approval |
| Sends vested dreUSD to vault (dreUSDs) | ✅ claimVested() transfers to immutable vault; callable by anyone when not paused |
| transferRewards(amount) onlyOperatorOrVault | ⚠️ Implemented as: transfer dreUSD to distributor + addRewards() (MODERATOR_ROLE); claimVested() public |
| setOperator / setVault / setMinPayout / setPaused | ⚠️ dreUSD/vault immutable (constructor); pause/unpause (PAUSER_ROLE); no setMinPayout |
| Events: RewardsTransferred, OperatorUpdated, VaultUpdated | ⚠️ RewardsClaimed; no operator/vault update events (immutable) |

---

### Oracles & Peg

| Requirement | Status |
|-------------|--------|
| Chainlink primary (USDC/USDT) | ✅ |
| Staleness checks | ✅ Per-token stalenessThresholds |
| getUsdValue / getTokenAmount | ✅ |
| Peg deviation ±50 bps → revert/freeze mint/redeem | ❌ No explicit ±50 bps deviation check or peg-freeze in contracts |
| Redstone / Pyth backup | ❌ Not implemented |
| Manual override (timelock) | ❌ Not implemented |
| Chainlink Proof-of-Reserve | ❌ Not integrated |

---

### Governance & Roles

| Requirement | Status |
|-------------|--------|
| DREGov (timelocked multisig) | ⚠️ Roles exist (DEFAULT_ADMIN_ROLE, MODERATOR_ROLE, etc.); no timelock contract in repo |
| DREGuardian (pause, peg freeze) | ⚠️ PAUSER_ROLE, GUARDIAN_ROLE; no explicit “peg freeze” |
| DREWithdrawalManager (keeper) | ⚠️ TREASURY_ROLE / EXPRESS_OPERATOR_ROLE for fill flows; no single “WithdrawalManager” role name |
| DRERewardsManager (keeper) | ⚠️ Keeper holds CLAIMER_ROLE for distributor; role name differs |
| CustodianMinter | ✅ KEEPER_ROLE for mintFromUsd |
| ProxyAdmin / UUPS upgrades | ✅ UUPS; upgrade via UPGRADER_ROLE |
| Upgrade timelock (24h → 72h @ $250M → 7d @ $1B) | ❌ Not implemented in contracts |

---

### Transparency & Events

| Requirement | Status |
|-------------|--------|
| Mint/Burn/Stake/Unstake events | ✅ |
| Withdrawal requested/fulfilled events | ✅ Express / Withdrawal events |
| Granular inflow/outflow for reconciliation | ⚠️ Per contract; no single CustodianRouter event set |
| mintFromUsd: CustodianFiatMinted (mintRef, receiver, usdAmount, signer) | ✅ |
| Indexed events for analytics | ✅ |

---

## Summary: Gaps and Design Choices

**Not implemented (from requirements):**

1. **CustodianRouter** — No separate contract for staged balances, sweep, disburseBatch, caps, express budget.
2. **Withdrawal min/max** — No setMinWithdrawalAmount / setMaxWithdrawalAmount / getters.
3. **unstakeAndRequestWithdraw** — No 1-click redeem dreUSDs + request withdrawal.
4. **withdrawalStatus(owner)** — No single view; withdrawals are NFT-based.
5. **Peg deviation ±50 bps** — No explicit deviation check or peg-freeze logic.
6. **Backup oracles** — No Redstone/Pyth or manual override.
7. **Chainlink Proof-of-Reserve** — Not integrated.
8. **Upgrade timelock** — No TVL-based delay (24h/72h/7d).

**Design differences (same intent, different shape):**

- **Withdrawals:** Requirements describe a single requestWithdrawal + fulfillWithdrawal + CustodianRouter.disburseBatch. Implementation uses dreWithdrawalNFT (standard and express instances) and fillers (partner/treasury) with dreAaveAdapter (no CustodianRouter).
- **Rewards:** Requirements describe keeper pushing via transferRewards(amount). Implementation: fund by transferring dreUSD into the distributor, then MODERATOR calls addRewards(); claimVested() (callable by anyone) sends vested dreUSD to the immutable vault address (dreUSDs).
- **Freeze:** Requirements: freeze(account, bool) + onlyGuardian. Implementation: freeze(account) / unfreeze(account) + GUARDIAN_ROLE / onlyGuardian.
- **Role names:** Requirements use DREGov, DREGuardian, etc.; implementation uses DEFAULT_ADMIN_ROLE, MODERATOR_ROLE, PAUSER_ROLE, etc. (see [ROLES.md](./ROLES.md)).

---

## References

- **Requirements:** DRE Stablecoin Requirements (product/requirements document).
- **Roles:** [ROLES.md](./ROLES.md)
- **Deployment:** [DEPLOYMENT.md](./DEPLOYMENT.md)
- **Fiat mint:** [FIAT_MINT.md](./FIAT_MINT.md)
- **Sanctions:** [SANCTIONS.md](./SANCTIONS.md). Bridge/compose routing and quarantined balances: [BRIDGE_COMPLIANCE.md](./BRIDGE_COMPLIANCE.md).
- **Bridging / Ovault:** [BRIDGING.md](./BRIDGING.md), [OVAULT.md](./OVAULT.md)
