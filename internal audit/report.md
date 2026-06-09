# Audit Report

## Table of Contents
- Executive Summary
- Detailed Findings
- Code Quality Notes
- LLM Review Notes
- Suppressed Findings
- Run Metadata

## Executive Summary
Total findings: 14. High: 7, Medium: 5, Low: 2.

LLM Review Notes: 18 findings (1 High, 5 Medium, 12 Low).

## Detailed Findings

FIXED

### ERC-4626 share inflation attack: no virtual offset and no minimum deposit protection (High)

- ID: 271a8213cbf4cdec
- Location: contracts/dreUSDs.sol:19-19
- Confidence: Medium
- Sources: upgradeability

ERC-4626 share inflation attack: no virtual offset and no minimum deposit protection

An attacker who is the first depositor (or who can get the vault to a near-empty state) can steal almost all subsequent deposits by performing a donation-based inflation attack. With `_decimalsOffset() = 0`, the virtual shares/assets are only `+1`, meaning a donation of even a small amount (e.g., 1 dreUSD sent directly) can inflate the share price such that a victim depositing gets 0 shares due to rounding. The attacker redeems their 1 share for both their donation and the victim's deposit. The `vestedAmount()` inclusion in `totalAssets()` adds another donation vector — if the attacker can time deposits around reward distribution, the share inflation is amplified without requiring a direct token donation.

Scenario: 1. Attacker deposits 1 wei of dreUSD into the empty vault, receiving 1 share.
2. Attacker sends (donates) 10,000 dreUSD directly to the vault contract (or waits for rewards to vest).
3. Now totalAssets() = 10,000e18 + 1, totalSupply() = 1 + 1 = 2 (with virtual offset).
4. Victim deposits 9,999 dreUSD. shares = 9999e18 * 2 / (10000e18 + 1 + 1) ≈ 1.99 → rounds to 1.
5. Actually with offset=0, formula is: shares = assets * (totalSupply + 1) / (totalAssets + 1). With totalSupply=1: shares = 9999e18 * 2 / (10001e18) ≈ 1. Victim gets 1 share.
6. Attacker redeems their 1 share for half of ~20,000 dreUSD = ~10,000 dreUSD, profiting from victim's deposit.
7. With larger donations relative to victim deposit, victim can get 0 shares (complete loss).


FIXED
### addRewards does not emit event for new reward schedule, hindering off-chain monitoring (High)

- ID: 36fd83f62d4d9af7
- Location: contracts/dreRewardsDistributor.sol:112-112
- Confidence: Medium
- Sources: aderyn

addRewards does not emit event for new reward schedule, hindering off-chain monitoring

The addRewards function modifies critical state variables (rewards, cTs, eTs) but emits no event. Off-chain systems monitoring reward distributions cannot detect when new rewards are added or when the vesting schedule changes. This makes it difficult to detect if a compromised MODERATOR is manipulating the reward schedule.

Scenario: 1. MODERATOR calls addRewards() which silently changes rewards, cTs, and eTs. 2. Off-chain monitoring systems have no event to index — they must poll state variables each block. 3. A compromised MODERATOR could call addRewards() with zero new dreUSD balance (newRewards=0, no state change) or manipulate timing to their advantage without any on-chain audit trail beyond transaction logs.


it doesn't refund because it just burns the corresponding DREUSD for the limit
### requestExpressWithdrawal does not refund excess dreUSD when capped by expressWithdrawalAvailable (High)

- ID: 603cc68a8e60a620
- Location: contracts/dreUSDManager.sol:480-537
- Confidence: Medium
- Sources: slither

requestExpressWithdrawal does not refund excess dreUSD when capped by expressWithdrawalAvailable

When a user requests an express withdrawal larger than `expressWithdrawalAvailable`, the function caps the withdrawal at the available amount and only burns the proportional `dreUSDNeeded`. The remaining dreUSD that the user intended to withdraw is neither burned nor queued into a standard withdrawal. The user loses the opportunity to withdraw the excess amount in the same transaction. While the user's tokens are not lost (they remain in their wallet), the function silently processes a partial withdrawal without informing the user via return value or event that only a portion was processed. The user called with a `minUsdcAmount` slippage check that was validated against `totalUsdcAmount` (the full amount) before the cap was applied (line 459), so the slippage check passes for the full amount but the actual withdrawal is for a smaller amount. This means `minUsdcAmount` does NOT protect the user against receiving less than expected due to the express cap — the slippage check is applied before the cap reduction.

Scenario: 1. Express available is 500,000 USDC. User requests express withdrawal of 1,000,000 dreUSD. 2. Oracle converts to `totalUsdcAmount = 1,000,000 USDC`. 3. User set `minUsdcAmount = 990,000 USDC`. Slippage check passes: 1,000,000 >= 990,000. 4. Cap kicks in: `expressUsdcAmount = 500,000`, `dreUSDNeeded = 500,000 dreUSD`. 5. Only 500,000 dreUSD burned, NFT minted for ~497,500 USDC (after fee). 6. User expected at least 990,000 USDC from their minUsdcAmount but received ~497,500 USDC. The slippage protection was bypassed because it was checked before the cap reduction. 7. The remaining 500,000 dreUSD stays in the user's wallet unprocessed — they must make another transaction.


FIXED
### aToken balance/amount mismatch due to Aave interest accrual causes safeTransferFrom to transfer more value than intended (High)

- ID: 6cfe5fa48e671b77
- Location: contracts/dreAaveAdapter.sol:93-113
- Confidence: High
- Sources: slither

aToken balance/amount mismatch due to Aave interest accrual causes safeTransferFrom to transfer more value than intended

When Aave's `withdraw` returns more than `amount` (which it can due to rounding in Aave's favor or accrued interest on the aTokens held by the adapter between the `safeTransferFrom` and `withdraw` calls), the excess USDC remains in the adapter contract without any accounting. Over many withdrawals, dust amounts of USDC could accumulate in the adapter. This is a minor accounting discrepancy. Additionally, the adapter pulls exactly `amount` of aTokens but the aToken balance may have accrued interest — the `withdraw(usdc, amount, to)` call requests `amount` USDC but burns aTokens based on the current liquidity index, which may differ slightly from the nominal aToken amount transferred. The leftover aTokens (dust) would also remain stranded in the adapter.

Scenario: 1. Vault holds 1,000,000 aUSDC and approves adapter. 2. WITHDRAWER_ROLE calls `withdraw(1000000e6, recipient)`. 3. `safeTransferFrom` moves exactly 1000000e6 aUSDC to adapter. 4. Between the transfer and `aavePool.withdraw`, interest accrues (even within the same tx, Aave's index may cause rounding). 5. Aave's `withdraw` burns slightly fewer aTokens than the full 1000000e6 transferred, leaving dust aTokens in the adapter. 6. The USDC sent to `to` equals `amount`, but the adapter now holds residual aTokens with no mechanism to account for or redeem them (except via `recoverToken` by admin).


### arbitrary-transfer-from (High)

- ID: a87549eb9d74dcde
- Location: contracts/dreAaveAdapter.sol:105-105
- Confidence: Medium
- Sources: aderyn

Passing an arbitrary `from` address to `transferFrom` (or `safeTransferFrom`) can lead to loss of funds, because anyone can transfer tokens from the `from` address if an approval is made.  

FIXED on address 0, intended others
### Deposit and withdraw permanently DoS'd if rewardsDistributor is unset or set to non-functional address (High)

- ID: ba3a4a8e756c4867
- Location: contracts/dreUSDs.sol:106-106
- Confidence: Medium
- Sources: aderyn

Deposit and withdraw permanently DoS'd if rewardsDistributor is unset or set to non-functional address

The `rewardsDistributor` is not set during `initialize()` and defaults to `address(0)`. Until `setRewardsDistributor()` is called by an admin, every call to `deposit()`, `withdraw()`, `mint()`, `redeem()`, `totalAssets()`, `previewDeposit()`, `previewWithdraw()`, `convertToShares()`, and `convertToAssets()` will revert because they call `vestedAmount()` or `claimVested()` on address(0). If the admin key is compromised, lost, or the admin sets a malicious/broken distributor address, all vault operations are permanently bricked and users cannot withdraw their funds. The admin can also maliciously swap the distributor to a contract that reverts on `claimVested()`, locking all funds.

Scenario: 1. dreUSDs is deployed and initialized via proxy. rewardsDistributor is address(0).
2. Before admin calls setRewardsDistributor(), any user who deposited through a different code path or received shares via transfer cannot withdraw — _claimVestedRewards() calls claimVested() on address(0), which reverts.
3. Alternatively: admin sets rewardsDistributor to a contract that later self-destructs or is upgraded to revert on claimVested(). All deposit/withdraw operations permanently fail.
4. Even totalAssets() reverts, breaking all ERC-4626 view functions and any integrations.

FIXED
### NFT transferability allows withdrawal funds to bypass sanctions/allowlist checks (High)

- ID: d854445c4c279b48
- Location: contracts/dreWithdrawalNFT.sol:16-16
- Confidence: Medium
- Sources: upgradeability

NFT transferability allows withdrawal funds to bypass sanctions/allowlist checks

The withdrawal NFT is a standard ERC721 with no transfer restrictions — no override of _update or _beforeTokenTransfer to enforce sanctions screening. The protocol uses ISanctionsList (Chainalysis) per the manifest. A sanctioned address that already holds a withdrawal NFT position can transfer it to a non-sanctioned address, which can then claim the withdrawal USDC. Alternatively, a sanctioned address's accomplice can receive the NFT and claim funds. The getOriginalUser function tracks the original minter but ownerOf changes on transfer — if fillWithdrawal pays ownerOf (the current holder) rather than getOriginalUser, sanctions are bypassed. Even if fillWithdrawal checks sanctions on the current owner, the sanctioned party has already extracted economic value by selling the NFT.

Scenario: 1. Alice (non-sanctioned) requests a withdrawal, minting NFT tokenId=10 with 100,000 USDC owed. 2. Alice is subsequently sanctioned by Chainalysis. 3. If the manager's fillWithdrawal checks sanctions on ownerOf(10) and blocks Alice, she simply transfers the NFT to Bob (non-sanctioned). 4. Bob calls or waits for fillWithdrawal, which now sees Bob as ownerOf(10) and passes sanctions check, paying Bob 100,000 USDC. 5. Bob forwards funds to Alice off-chain, completing the sanctions evasion.

FIXED
### setVestPeriod to value \< 1 day causes addRewards to revert due to underflow in checked arithmetic (Medium)

- ID: 0a14a90a0a1eca87
- Location: contracts/dreRewardsDistributor.sol:111-136
- Confidence: High
- Sources: slither

setVestPeriod to value < 1 day causes addRewards to revert due to underflow in checked arithmetic

If a MODERATOR sets vestPeriod to any value less than 86400 (1 day), and addRewards is called while there are existing unvested rewards (rewards > 0), the expression `vestPeriod - 1 days` underflows because Solidity 0.8.x checked arithmetic reverts on unsigned integer underflow. This makes it impossible to add new rewards while old rewards are still vesting, effectively freezing the reward distribution system until the vestPeriod is set back to >= 1 day. Any dreUSD transferred to the contract for new rewards becomes temporarily stuck.

Scenario: 1. MODERATOR calls setVestPeriod(3600) to set a 1-hour vest period (valid — passes the != 0 check). 2. MODERATOR transfers dreUSD and calls addRewards(). First call works fine (rewards == 0, takes the first branch at line 116-119). 3. Before the 1-hour vest completes, MODERATOR transfers more dreUSD and calls addRewards() again. 4. _claimVested() runs, partial vesting occurs, rewards > 0 remains. 5. newRewards > 0, rewards > 0, so the else branch at line 120 executes. 6. Line 126: `vestPeriod - 1 days` = `3600 - 86400` underflows → revert. 7. addRewards() is now permanently broken until vestPeriod is increased to >= 86400.

intended
### requestExpressWithdrawal: dreUSDNeeded calculation truncates via integer division, potentially burning less dreUSD than owed (Medium)

- ID: 1d57d2c522911523
- Location: contracts/dreUSDManager.sol:442-477
- Confidence: Medium
- Sources: slither

requestExpressWithdrawal: dreUSDNeeded calculation truncates via integer division, potentially burning less dreUSD than owed

The calculation `dreUSDNeeded = dreUSDAmount * expressUsdcAmount / totalUsdcAmount` rounds DOWN due to integer division. This means the user burns slightly less dreUSD than the proportional amount for the USDC they'll receive. Over many transactions, this creates a small but systematic undercollateralization: less dreUSD is burned than the USDC value of the withdrawal NFT created. The discrepancy per transaction is at most 1 wei of dreUSD, but the direction always favors the user.

Scenario: 1. User requests 1,000,000,000,000,000,001 dreUSD (1e18 + 1 wei) express withdrawal. 2. Oracle returns totalUsdcAmount = 1,000,001 (USDC 6 decimals). 3. expressWithdrawalAvailable = 1,000,000. 4. expressUsdcAmount capped to 1,000,000. 5. dreUSDNeeded = (1e18+1) * 1,000,000 / 1,000,001 = 999,999,000,001,999,998 (truncated). 6. The proportional dreUSD that should be burned is slightly higher. User keeps the truncation difference.

its view, and it computes vested auto, intended

### previewDeposit/previewWithdraw may return inaccurate values due to _claimVestedRewards side effect (Medium)

- ID: 4ff2d25fa898d955
- Location: contracts/dreUSDs.sol:105-107
- Confidence: Medium
- Sources: slither

previewDeposit/previewWithdraw may return inaccurate values due to _claimVestedRewards side effect

The ERC-4626 specification requires that `previewDeposit` returns the exact number of shares that `deposit` would return, and `previewWithdraw` returns the exact number of shares that `withdraw` would burn. However, `_claimVestedRewards()` called within `_deposit` and `_withdraw` can change the reward distribution state in the distributor (e.g., resetting the vesting schedule or starting a new epoch). If `claimVested()` has side effects that cause `vestedAmount()` to return a different value after the claim (which it must, since it transfers tokens and resets vesting state), then a subsequent call's share calculation would differ from what `previewDeposit`/`previewWithdraw` predicted. In the same transaction, if Alice calls `deposit()` and `_claimVestedRewards()` changes the distributor state, a subsequent `deposit()` by Bob in the same block would see a different `vestedAmount()` than his prior `previewDeposit` showed. This breaks ERC-4626 compliance and can cause integration failures with routers, aggregators, or contracts that rely on preview accuracy.

Scenario: 1. Distributor has 1,000 dreUSD vested and ready to claim. `vestedAmount()` returns 1,000e18.
2. Bob calls `previewDeposit(10000e18)` off-chain or from a router contract — sees shares = X based on totalAssets including 1,000 vested.
3. Alice's `deposit()` transaction executes first in the block. Her `_deposit` calls `_claimVestedRewards()`, which transfers the 1,000 dreUSD to the vault and resets the distributor's vesting state. Now `vestedAmount()` returns 0.
4. Bob's `deposit()` transaction executes next. `previewDeposit` now computes shares based on `totalAssets()` where vestedAmount=0 but vault balance is 1,000 higher — net totalAssets is the same.
5. However, if `claimVested()` has additional side effects (like resetting `cTs`/`eTs` timestamps causing `vestedAmount` to change non-trivially, or if there's a partial claim scenario), the totalAssets could differ.
6. More critically: Bob's own `previewDeposit()` call that happened before Alice's transaction would have returned a value based on stale distributor state. The actual shares he receives match the real-time calculation but differ from his pre-transaction preview.

fixed
### Division by zero in _computeVestedAmount when eTs == cTs (Medium)

- ID: 9638701d4a6156d3
- Location: contracts/dreRewardsDistributor.sol:169-174
- Confidence: High
- Sources: slither

Division by zero in _computeVestedAmount when eTs == cTs

After initialization (where cTs == eTs == block.timestamp), if rewards are somehow non-zero (e.g., via an upgrade that sets rewards without going through addRewards, or if addRewards sets rewards > 0 and then _claimVested is called in the same block where eTs == cTs), the division `(eTs - cTs)` evaluates to zero, causing a revert. This creates a denial-of-service condition where claimVested() and addRewards() (which calls _claimVested internally) become uncallable. More critically, consider the path: after initialize, cTs == eTs. If _claimVested is called in the same block as addRewards sets the first schedule, the early-return guard `newClaimTimestamp - cTs == 0` saves it. However, if setVestPeriod is called to a very small value and addRewards is called such that the `else` branch at line 130-131 sets `eTs = eTs + rTs` where rTs rounds to 0, then eTs could equal cTs in subsequent calls, causing a permanent DoS on the rewards system.

Scenario: 1. Contract is initialized: cTs = eTs = block.timestamp. 2. MODERATOR calls addRewards() — first branch sets rewards and eTs = now + vestPeriod, which is safe. 3. Time passes partially. MODERATOR calls setVestPeriod(1) (1 second). 4. MODERATOR transfers a tiny amount of dreUSD and calls addRewards(). _claimVested() runs, updating cTs close to eTs. 5. In the else branch (line 120-132): rTs = newRewards * (eTs - cTs) / rewards. If (eTs - cTs) is 1 and newRewards is small relative to rewards, rTs rounds to 0. newVestPeriod = (eTs - cTs) + 0 = 1. Since 1 < vestPeriod - 1 days (underflows to huge number in unchecked context — but this is checked arithmetic so it reverts if vestPeriod < 1 days). With vestPeriod = 1, `vestPeriod - 1 days` underflows and reverts (checked arithmetic). This blocks the addRewards path. Alternatively, if vestPeriod is set to exactly 1 day, `vestPeriod - 1 days = 0`, and `newVestPeriod < 0` is false, so eTs = eTs + 0 = eTs, but cTs was updated to near eTs, so eTs - cTs could be 0, causing division by zero on next claimVested call.

it falls back to the timestamp (last updated)
### _getLatestPrice does not validate roundId or answeredInRound, allowing consumption of incomplete Chainlink rounds (Medium)

- ID: e1f6a26d3ee7ec95
- Location: contracts/dreUSDOracle.sol:198-208
- Confidence: Medium
- Sources: slither

_getLatestPrice does not validate roundId or answeredInRound, allowing consumption of incomplete Chainlink rounds

The function discards roundId and answeredInRound without checking that answeredInRound >= roundId. In Chainlink's aggregator model, if answeredInRound < roundId, the round has not yet been fully resolved and the answer may be carried over from a previous round. While the staleness check via updatedAt provides some protection, there are edge cases where updatedAt is recent but the answer is stale (e.g., during multi-phase aggregation). Additionally, if the oracle returns updatedAt = 0 (malfunction), the staleness check `block.timestamp - 0 > threshold` would correctly revert for reasonable thresholds, but the lack of an explicit updatedAt > 0 check means this relies entirely on the threshold value.

Scenario: 1. Chainlink aggregator enters a new round (roundId increments) but hasn't received enough oracle responses to finalize.
2. latestRoundData() returns the new roundId with the answer from the previous round and answeredInRound < roundId.
3. updatedAt may reflect the previous round's timestamp, and if within the staleness window, the stale price passes validation.
4. The oracle returns a price from a previous round that may not reflect current market conditions.
5. This is a known Chainlink integration pattern that best practice recommends checking.

fixed (removed)
### \[By Design\] Out-of-order burn adds already-burned token IDs to _skippedTokenIds set (Low)

- ID: f5f2118ec3a30fc0
- Location: contracts/dreWithdrawalNFT.sol:86-112
- Confidence: Medium
- Sources: slither

[By Design] Out-of-order burn adds already-burned token IDs to _skippedTokenIds set

When burns happen out of order, already-burned token IDs within the skipped range are added to _skippedTokenIds. Consider: mint tokens 1-5, then burn(3) followed by burn(5). When burn(5) executes, lastBurnedTokenId is 3, so the loop adds IDs 4 to _skippedTokenIds — but it also re-adds ID 3 (which was just burned and no longer exists) because the loop iterates from lastBurnedTokenId+1=4... wait, let me re-trace. After burn(3): lastBurnedTokenId=3 (IDs 1,2 added to skipped). After burn(5): loop from 4 to 4, adds 4. This is correct for that sequence. However, consider: burn(3) then burn(2). After burn(3): lastBurnedTokenId=3, skipped={1,2}. burn(2): tokenId(2) <= lastBurnedTokenId(3), so it removes 2 from skipped. But lastBurnedTokenId remains 3 — and ID 1 is still in skipped even though it's a live pending token. The real issue is that getSkippedTokenIds returns IDs that are genuinely pending (not yet burned), which is the intended behavior for tracking. However, any consumer of getPendingRange that iterates [lastBurnedTokenId+1, nextTokenId-1] and subtracts skipped IDs will compute an incorrect pending set because the range starts AFTER lastBurnedTokenId, so IDs below lastBurnedTokenId that are still live (in _skippedTokenIds) fall outside the range. The _skippedTokenIds set contains live pending tokens whose IDs are below lastBurnedTokenId, but getPendingRange returns a range starting at lastBurnedTokenId+1, creating an inconsistent view. A keeper iterating getPendingRange would never see these lower-ID positions, potentially stranding them permanently.

Scenario: 1. Tokens 1,2,3,4,5 are minted. lastBurnedTokenId=0, nextTokenId=6. 2. Keeper calls burn(3). lastBurnedTokenId becomes 3. IDs 1,2 are added to _skippedTokenIds. 3. getPendingRange returns (4, 5). getSkippedTokenIds returns [1, 2]. 4. A keeper using getPendingRange to find unfilled positions sees range [4,5] and skipped set [1,2]. The pending range [4,5] minus skipped gives {4,5} — IDs 1 and 2 are NOT in this range. 5. The keeper must separately consult getSkippedTokenIds to discover that tokens 1 and 2 are still pending but outside the range. If the keeper only iterates the pending range (as the naming strongly implies), tokens 1 and 2 are permanently skipped and never filled.

intended, the fee is something we take 
### Express withdrawal accounting mismatch: expressWithdrawalAvailable decremented by gross amount but payback uses total (user + fee) (Low)

- ID: c1cafbadd9e11880
- Location: contracts/dreUSDManager.sol:664-687
- Confidence: Medium
- Sources: slither

Express withdrawal accounting mismatch: expressWithdrawalAvailable decremented by gross amount but payback uses total (user + fee)

There is a unit mismatch between how `expressWithdrawalAvailable` is decremented and how it is restored. On request, `expressWithdrawalAvailable` is decremented by `usdcAmount` (the gross/pre-fee amount). When the express filler fills the withdrawal, `expressFillerDebt` is incremented by `totalRequired = userAmount + feeAmount`. When payback occurs via `_paybackExpressFiller`, `expressWithdrawalAvailable` is increased by the payback `amount`, which can be up to `expressFillerDebt`. Since `expressFillerDebt` includes the fee component but the original decrement did not separate it, the payback restores more capacity than was originally consumed if the full debt is paid. Over many cycles, `expressWithdrawalAvailable` can grow beyond `expressWithdrawalMaxLimit`. However, the `limitHeadroom` check (`expressWithdrawalMaxLimit - expressWithdrawalAvailable`) constrains payback to not exceed the max limit. So the accounting is capped — but the filler accumulates debt (fee portion) they can never get paid back for via this mechanism, because the limit headroom restricts it. This means the express filler permanently loses the fee amounts from their debt, or must be compensated out-of-band.

Scenario: 1. Express limit is 10M USDC, fully available. Fee is 50 bps. 2. User requests express withdrawal for 1,000,000 USDC gross. `expressWithdrawalAvailable` decremented by 1,000,000 to 9,000,000. NFT stores userReceives=995,000, fee=5,000. 3. EXPRESS_OPERATOR fills: `expressFillerDebt += 1,000,000` (995k + 5k). Filler sends 995k to user, 5k to feeRecipient. 4. Treasury pays back debt: `limitHeadroom = 10,000,000 - 9,000,000 = 1,000,000`. Filler debt is 1,000,000. Payback of 1,000,000 is allowed. `expressWithdrawalAvailable = 9,000,000 + 1,000,000 = 10,000,000`. This works for a single cycle. 5. But the filler fronted 1,000,000 USDC total and gets 1,000,000 back. The 5,000 fee went to feeRecipient — the filler is made whole. 6. After closer examination: `totalRequired = userAmount + feeAmount` means the filler's debt includes what they paid to the fee recipient. The payback sends the full amount back to the filler. So the protocol (TREASURY_ROLE) effectively reimburses the filler for the fee payment too, meaning the fee is ultimately paid by the treasury, not the user. The user burned dreUSD to cover the gross amount but only the net was withdrawn from express capacity. The fee flows: user→burn dreUSD, filler→USDC to user+feeRecipient, treasury→USDC to filler for full amount including fee.


## Code Quality Notes

333 code quality finding(s) across 19 detector(s). 77 finding(s) from 6 noisy detector(s) suppressed. 4 finding(s) from 4 additional detector(s) not shown.

### solhint-use-natspec (Info) — 139 instances across 20 file(s)

- Sources: solhint
- Example: contracts/dreAaveAdapter.sol:23 — Missing @author tag in contract 'dreAaveAdapter'
- Affected files:
  - contracts/dreAaveAdapter.sol (4)
  - contracts/dreRewardsDistributor.sol (12)
  - contracts/dreUSD.sol (10)
  - contracts/dreUSDManager.sol (25)
  - contracts/dreUSDOracle.sol (5)
  - contracts/dreUSDs.sol (11)
  - contracts/dreWithdrawalNFT.sol (6)
  - contracts/governance/dreTimelockController.sol (1)
  - contracts/interfaces/IAaveV3Adapter.sol (2)
  - contracts/interfaces/IAaveV3Pool.sol (1)
  - ... and 10 more file(s)

### centralization-risk (Low) — 42 instances across 7 file(s)

- Sources: aderyn
- Example: contracts/dreAaveAdapter.sol:96 — Contracts have owners with privileged rights to perform admin tasks and need to be trusted to not perform malicious updates or drain funds.
- Affected files:
  - contracts/dreAaveAdapter.sol (4)
  - contracts/dreRewardsDistributor.sol (5)
  - contracts/dreUSD.sol (4)
  - contracts/dreUSDManager.sol (18)
  - contracts/dreUSDOracle.sol (4)
  - contracts/dreUSDs.sol (4)
  - contracts/dreWithdrawalNFT.sol (3)

### naming-convention (Info) — 24 instances across 12 file(s)

- Sources: slither
- Example: contracts/governance/dreTimelockController.sol:6 — Contract dreTimelockController (contracts/governance/dreTimelockController.sol#6-12) is not in CapWords

- Affected files:
  - contracts/governance/dreTimelockController.sol (1)
  - contracts/dreUSDManager.sol (6)
  - contracts/dreWithdrawalNFT.sol (2)
  - contracts/interfaces/IdreRewardsDistributor.sol (1)
  - contracts/ovault/dreOVaultComposer.sol (1)
  - contracts/ovault/dreShareOFT.sol (1)
  - contracts/ovault/dreShareOFTAdapter.sol (1)
  - contracts/dreUSDOracle.sol (1)
  - contracts/dreUSDs.sol (2)
  - contracts/dreRewardsDistributor.sol (1)
  - ... and 2 more file(s)

### unindexed-events (Low) — 22 instances across 5 file(s)

- Sources: aderyn
- Example: contracts/interfaces/IAaveV3Adapter.sol:20 — Index event fields make the field more quickly accessible to off-chain tools that parse events. However, note that each index field costs extra gas during emission, so it's not necessarily best to index the maximum allowed per event (three fields). Each event should use three indexed fields if there are three or more fields, and gas usage is not particularly of concern for the events in question. If there are fewer than three fields, all of the fields should be indexed.
- Affected files:
  - contracts/interfaces/IAaveV3Adapter.sol (1)
  - contracts/interfaces/IDreUSDOracle.sol (2)
  - contracts/interfaces/IWithdrawalNFT.sol (1)
  - contracts/interfaces/IdreRewardsDistributor.sol (2)
  - contracts/interfaces/IdreUSDManager.sol (16)

### unspecific-solidity-pragma (Low) — 20 instances across 20 file(s)

- Sources: aderyn
- Example: contracts/dreAaveAdapter.sol:2 — Consider using a specific version of Solidity in your contracts instead of a wide version. For example, instead of `pragma solidity ^0.8.0;`, use `pragma solidity 0.8.0;`
- Affected files:
  - contracts/dreAaveAdapter.sol (1)
  - contracts/dreRewardsDistributor.sol (1)
  - contracts/dreUSD.sol (1)
  - contracts/dreUSDManager.sol (1)
  - contracts/dreUSDOracle.sol (1)
  - contracts/dreUSDs.sol (1)
  - contracts/dreWithdrawalNFT.sol (1)
  - contracts/governance/dreTimelockController.sol (1)
  - contracts/interfaces/IAaveV3Adapter.sol (1)
  - contracts/interfaces/IAaveV3Pool.sol (1)
  - ... and 10 more file(s)

### timestamp (Low) — 14 instances across 3 file(s)

- Sources: slither
- Example: contracts/dreUSDManager.sol:884 — dreUSDManager._mintFromFiatUsd(IdreUSDManager.FiatMint,bytes) (contracts/dreUSDManager.sol#884-910) uses timestamp for comparisons
	Dangerous comparisons:
	- block.timestamp > m.validUntil (contracts/dreUSDManager.sol#888)

- Affected files:
  - contracts/dreUSDManager.sol (8)
  - contracts/dreRewardsDistributor.sol (3)
  - contracts/dreUSDOracle.sol (3)

### constants-instead-of-literals (Low) — 11 instances across 2 file(s)

- Sources: aderyn
- Example: contracts/dreUSDManager.sol:178 — If the same constant literal value is used multiple times, create a constant state variable and reference it throughout the contract.
- Affected files:
  - contracts/dreUSDManager.sol (7)
  - contracts/dreUSDOracle.sol (4)

### solhint-contract-name-capwords (Info) — 11 instances across 11 file(s)

- Sources: solhint
- Example: contracts/dreAaveAdapter.sol:23 — Contract, Structs and Enums should be in CapWords
- Affected files:
  - contracts/dreAaveAdapter.sol (1)
  - contracts/dreRewardsDistributor.sol (1)
  - contracts/dreUSD.sol (1)
  - contracts/dreUSDManager.sol (1)
  - contracts/dreUSDOracle.sol (1)
  - contracts/dreUSDs.sol (1)
  - contracts/dreWithdrawalNFT.sol (1)
  - contracts/governance/dreTimelockController.sol (1)
  - contracts/ovault/dreOVaultComposer.sol (1)
  - contracts/ovault/dreShareOFT.sol (1)
  - ... and 1 more file(s)

### useless-public-function (Low) — 11 instances across 6 file(s)

- Sources: aderyn
- Example: contracts/dreRewardsDistributor.sol:66 — Instead of marking a function as `public`, consider marking it as `external` if it is not used internally.
- Affected files:
  - contracts/dreRewardsDistributor.sol (1)
  - contracts/dreUSD.sol (2)
  - contracts/dreUSDManager.sol (2)
  - contracts/dreUSDOracle.sol (1)
  - contracts/dreUSDs.sol (3)
  - contracts/dreWithdrawalNFT.sol (2)

### reentrancy-events (Low) — 9 instances across 5 file(s)

- Sources: slither
- Example: contracts/dreUSDManager.sol:401 — Reentrancy in dreUSDManager.mintRewards(IdreUSDManager.FiatMint,bytes) (contracts/dreUSDManager.sol#401-410):
	External calls:
	- (dreUSDAmount,signer) = _mintFromFiatUsd(m,custodianSig) (contracts/dreUSDManager.sol#406)
		- IdreUSD(dreUSD).mint(m.receiver,dreUSDAmount) (contracts/dreUSDManager.sol#909)
	- IdreRewardsDistributor(dreRewardsDistributor).addRewards() (contracts/dreUSDManager.sol#408)
	Event emitted after the call(s):
	- MintRewards(m.mintRef,m.receiver,m.usdAmount,dreUSDAmount,signer) (contracts/dreUSDManager.sol#409)

- Affected files:
  - contracts/dreUSDManager.sol (4)
  - contracts/dreAaveAdapter.sol (1)
  - contracts/dreUSDs.sol (2)
  - contracts/dreWithdrawalNFT.sol (1)
  - contracts/dreUSD.sol (1)

### solhint-immutable-vars-naming (Info) — 8 instances across 2 file(s)

- Sources: solhint
- Example: contracts/dreRewardsDistributor.sol:35 — Immutable variables name are set to be in capitalized SNAKE_CASE
- Affected files:
  - contracts/dreRewardsDistributor.sol (2)
  - contracts/dreUSDManager.sol (6)

### empty-block (Low) — 7 instances across 7 file(s)

- Sources: aderyn
- Example: contracts/dreAaveAdapter.sol:183 — Consider removing empty blocks.
- Affected files:
  - contracts/dreAaveAdapter.sol (1)
  - contracts/dreRewardsDistributor.sol (1)
  - contracts/dreUSD.sol (1)
  - contracts/dreUSDManager.sol (1)
  - contracts/dreUSDOracle.sol (1)
  - contracts/dreUSDs.sol (1)
  - contracts/dreWithdrawalNFT.sol (1)

### solhint-no-empty-blocks (Info) — 7 instances across 7 file(s)

- Sources: solhint
- Example: contracts/dreAaveAdapter.sol:183 — Code contains empty blocks
- Affected files:
  - contracts/dreAaveAdapter.sol (1)
  - contracts/dreRewardsDistributor.sol (1)
  - contracts/dreUSD.sol (1)
  - contracts/dreUSDManager.sol (1)
  - contracts/dreUSDOracle.sol (1)
  - contracts/dreUSDs.sol (1)
  - contracts/dreWithdrawalNFT.sol (1)

### shadowing-local (Low) — 3 instance(s)

- Sources: slither
- contracts/ovault/dreShareOFT.sol:29 — dreShareOFT.constructor(string,string,address,address)._name (contracts/ovault/dreShareOFT.sol#29) shadows:
	- ERC20._name (lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol#36) (state variable)

- contracts/ovault/dreShareOFT.sol:30 — dreShareOFT.constructor(string,string,address,address)._symbol (contracts/ovault/dreShareOFT.sol#30) shadows:
	- ERC20._symbol (lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol#37) (state variable)

- contracts/dreUSD.sol:104 — dreUSD.permit(address,address,uint256,uint256,uint8,bytes32,bytes32).owner (contracts/dreUSD.sol#104) shadows:
	- OwnableUpgradeable.owner() (lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#73-76) (function)


### security-md (Info) — 1 instance(s)

- Sources: auzitor
- SECURITY.md:0 — No SECURITY.md file found at the repository root. Consider adding one to document the security contact information and vulnerability reporting procedures.

## LLM Review Notes

### Protocol Manifest

- **Trust roles:** DEFAULT_ADMIN_ROLE, UPGRADER_ROLE, KEEPER_ROLE, EXPRESS_OPERATOR_ROLE, TREASURY_ROLE, MODERATOR_ROLE, WITHDRAWAL_CONFIG_ROLE, PAUSER_ROLE, MANAGER_ROLE, GUARDIAN_ROLE, MINTER_ROLE, BURNER_ROLE, WITHDRAWER_ROLE
- **Assets:** dreUSD, dreUSDs, USDC, aUSDC, withdrawalNFT, expressWithdrawalNFT
- **Oracles:** dreUSDOracle (Chainlink AggregatorV3 feeds), ISanctionsList (Chainalysis)
- **Upgrade style:** UUPS


- fixed
### _computeFiatMintStructHash corrupts Solidity free memory pointer at 0x40 (High)

- **ID:** fcc2123e773ce6b8
- **Category:** math
- **Location:** contracts/dreUSDManager.sol:941-950
- **Contract:** dreUSDManager
- **Function:** _computeFiatMintStructHash
- **Confidence:** High
- **Sources:** claude

**Impact:**
The assembly block writes the `usdAmount` value `c` to memory offset 0x40, which is the Solidity free memory pointer (FMP). After the assembly block returns, the compiler assumes 0x40 still contains a valid FMP. Subsequent Solidity operations (ABI encoding for external calls, string operations, event emissions, error encoding) will allocate memory starting at whatever value `c` was. If `c` is a small value (e.g., a USD amount like 1_000_000_00 = 10^8), the FMP points to low memory, causing subsequent memory allocations to overwrite the scratch space, existing data, or the FMP itself. If `c` is very large, it could point beyond available memory, wasting gas or causing out-of-gas. In the calling function `_mintFromFiatUsd`, after `_computeFiatMintStructHash` returns, the code calls `MessageHashUtils.toEthSignedMessageHash(structHash)`, `ECDSA.recover(ethSignedHash, custodianSig)`, `IERC20Metadata(dreUSD).decimals()`, and `IdreUSD(dreUSD).mint(...)` — all of which perform ABI encoding that relies on a correct FMP. The corrupted FMP can cause these operations to produce incorrect ABI-encoded calldata, potentially leading to signature verification passing for invalid signatures or minting incorrect amounts. Memory offsets 0x00-0x3f are scratch space per Solidity convention [VR-09], but 0x40 is specifically the free memory pointer, NOT scratch space — writing to 0x40 corrupts it. Additionally, 0x60 is the zero-slot, and 0x80 overwrites the start of allocated memory.

**Exploit Scenario:**
1. A keeper calls `mintFromUsd` with a valid FiatMint struct where `usdAmount = 100000000` (1M USD with 2 decimals). 2. `_computeFiatMintStructHash` executes and writes `100000000` (0x5F5E100) to memory offset 0x40. 3. The Solidity free memory pointer now points to address 0x5F5E100 instead of its correct value. 4. When `_mintFromFiatUsd` continues and calls `MessageHashUtils.toEthSignedMessageHash(structHash)`, the ABI encoder reads the corrupted FMP from 0x40 and begins encoding at memory address 0x5F5E100. 5. Depending on the exact value of `c` and current memory layout, subsequent external calls may encode calldata incorrectly, read stale/zero memory for return values, or the transaction may revert with out-of-gas. 6. In the worst case, the corrupted memory causes `ECDSA.recover` to return an unexpected address that happens to be in the custodians mapping, allowing unauthorized minting.

**Evidence:**
- contracts/dreUSDManager.sol:941-950
  ```solidity
  function _computeFiatMintStructHash(bytes32 a, address b, uint256 c, uint256 d, uint256 e) internal pure returns (bytes32 hashedVal) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            mstore(0x40, c)
            mstore(0x60, d)
            mstore(0x80, e)
            hashedVal := keccak256(0x00, 0xa0)
        }
    }
  ```
- contracts/dreUSDManager.sol:884-910
  ```solidity
  function _mintFromFiatUsd(FiatMint calldata m, bytes calldata custodianSig) internal returns (uint256 dreUSDAmount, address signer) {
        // Validate mint request
        if (m.receiver == address(0)) revert ZeroAddress();
        if (m.usdAmount == 0) revert ZeroAmount();
        if (block.timestamp > m.validUntil) revert MintExpired(m.validUntil);
        if (m.chainId != block.chainid) revert InvalidChainId(block.chainid, m.chainId);
        if (usedMintRefs[m.mintRef]) revert MintRefAlreadyUsed(m.mintRef);

        // Check and update daily limit
        _checkAndUpdateDailyFiatMint(m.usdAmount);

        // Verify custodian signature
        bytes32 structHash = _computeFiatMintStructHash(m.mintRef, m.receiver, m.usdAmount, m.validUntil, m.chainId);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        signer = ECDSA.recover(ethSignedHash, custodianSig);
        if (!custodians[signer]) revert InvalidCustodianSignature();

        // Mark mintRef as used
        usedMintRefs[m.mintRef] = true;

        // Convert USD amount to dreUSD (fiat has 2 decimals)
        uint8 dreUSDDecimals = IERC20Metadata(dreUSD).decimals();
        dreUSDAmount = _convertToDecimals(m.usdAmount, 2, dreUSDDecimals);

        // Mint dreUSD to receiver
        IdreUSD(dreUSD).mint(m.receiver, dreUSDAmount);
    }
  ```

**Assumptions:**
- The Solidity compiler uses offset 0x40 as the free memory pointer (this is the standard convention for all Solidity versions)
- Subsequent operations after the assembly block rely on correct FMP for ABI encoding

**Notes for Auditor:**
The Solidity free memory pointer lives at 0x40 per the Solidity memory layout specification. Writing arbitrary values there corrupts all subsequent dynamic memory allocation. The fix would be to either save/restore the FMP around the assembly block, or use memory starting at the current FMP value. Note that 0x60 (the 'zero slot') is also overwritten, which Solidity expects to always contain zero. This affects both `mintFromUsd` and `mintRewards` code paths since both call `_mintFromFiatUsd`.

- fixed

### FiatMint signature uses toEthSignedMessageHash instead of EIP-712 typed data, inconsistent with mintFrom auth scheme (Medium)

- **ID:** 7cdb17b028c8abe5
- **Category:** logic
- **Location:** contracts/dreUSDManager.sol:896-899
- **Contract:** dreUSDManager
- **Function:** _mintFromFiatUsd
- **Confidence:** High
- **Sources:** claude

**Impact:**
The fiat mint path uses `toEthSignedMessageHash` (which prepends `\x19Ethereum Signed Message:\n32`) instead of the EIP-712 `\x19\x01` + domain separator pattern used in `_authorize` for `mintFrom`. This means the fiat mint signature does NOT include a domain separator with chain ID and contract address in the signature scheme itself. While the `chainId` is included in the struct hash data, it is not part of a proper domain separator. This means: (1) The signature format is a plain `eth_sign` / `personal_sign` style hash, which some wallets may not display structured data for. (2) If a custodian signs the same struct hash for a different purpose (any other contract using `toEthSignedMessageHash` on the same data layout), the signature could be replayed. (3) The contract address is NOT bound into the signature at all — if the same code is deployed at multiple addresses (e.g., different chains, or multiple proxy deployments), a signature valid for one deployment is valid for all (the chainId field mitigates cross-chain but not same-chain multiple deployments).

**Exploit Scenario:**
1. Protocol deploys dreUSDManager proxy at address A on mainnet. Custodian signs a fiat mint for 1M USD. 2. Protocol later deploys a second dreUSDManager proxy at address B on mainnet (e.g., for a different product or after migration). 3. The same custodian is registered on both deployments. 4. The keeper replays the custodian's signature on deployment B. The signature is valid because it doesn't bind to the contract address. 5. MintRef prevents replay on the same contract, but if deployment B has separate `usedMintRefs` storage, the same mintRef hasn't been used there. 6. 1M dreUSD is minted on both deployments from a single custodian signature.

**Evidence:**
- contracts/dreUSDManager.sol:896-899
  ```solidity
          bytes32 structHash = _computeFiatMintStructHash(m.mintRef, m.receiver, m.usdAmount, m.validUntil, m.chainId);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        signer = ECDSA.recover(ethSignedHash, custodianSig);
        if (!custodians[signer]) revert InvalidCustodianSignature();
  ```
- contracts/dreUSDManager.sol:793-797
  ```solidity
          bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _authDomainSeparator(), structHash)
        );
        address signer = ECDSA.recover(digest, authorizeSig);
        if (signer != from) revert InvalidMintFromSignature();
  ```

**Assumptions:**
- The same custodian address could be registered on multiple contract deployments
- mintRef is tracked per-contract (in storage), not globally

**Notes for Auditor:**
The `_computeFiatMintStructHash` hashes (mintRef, receiver, usdAmount, validUntil, chainId) but does NOT include the contract address. Combined with `toEthSignedMessageHash` instead of a domain separator, the signature is replayable across different contract deployments on the same chain. Compare with `_authorize` which properly uses `_authDomainSeparator()` containing both `block.chainid` and `address(this)`. The fiat mint path should use the same EIP-712 pattern.


### Precision loss in getTokenAmount when converting dreUSD (18 decimals) to price decimals (8 decimals) via integer division (Medium)

- **ID:** 907803ba60f93147
- **Category:** math
- **Location:** contracts/dreUSDOracle.sol:155-156
- **Contract:** dreUSDOracle
- **Function:** getTokenAmount
- **Confidence:** High
- **Sources:** claude

**Impact:**
When converting dreUSD amounts to token amounts (e.g., for withdrawals), the intermediate division at line 156 truncates up to 10^(dreUsdDecimals - priceDecimals) - 1 = 10^10 - 1 wei of dreUSD value. For the standard Chainlink USDC/USD feed (8 decimals) and dreUSD (18 decimals), any dreUSD amount with fractional value below 1e-8 USD is completely lost. For example, withdrawing 0.000000009999999999 dreUSD (9999999999 wei) yields usdAmountInPriceDecimals = 0, and therefore tokenAmount = 0 — the user burns dreUSD and receives nothing. While individual losses are tiny, this truncation always favors the protocol, and repeated small withdrawals can accumulate losses. More importantly, the division happens BEFORE the multiplication by 10^tokenDecimals, which means precision that could have been preserved through reordering the arithmetic is needlessly discarded.

**Exploit Scenario:**
1. USDC has 6 decimals, Chainlink USDC/USD feed has 8 decimals, dreUSD has 18 decimals.
2. User calls getTokenAmount(USDC, 9_999_999_999) — approximately 0.0000000099 dreUSD.
3. usdAmountInPriceDecimals = 9_999_999_999 / 10^10 = 0 (truncated to zero).
4. tokenAmount = 0 * 10^6 / price = 0.
5. User receives 0 USDC despite burning nonzero dreUSD.
6. Even for larger amounts, the last 10 digits of precision are always truncated. For 1.0000000099e18 dreUSD (~1 USD), the 0.0000000099 portion is lost.
7. The formula could preserve more precision by reordering: tokenAmount = dreUSDAmount * 10^tokenDecimals / (price * 10^(dreUsdDecimals - priceDecimals)), which keeps full 18-decimal precision until the final division.

**Evidence:**
- contracts/dreUSDOracle.sol:154-159
  ```solidity
          uint256 usdAmountInPriceDecimals;
        if (dreUsdDecimals > priceDecimals) {
            usdAmountInPriceDecimals = dreUSDAmount / (10 ** (dreUsdDecimals - priceDecimals)); // 10e18 / 10**(18-8)
        } else {
            usdAmountInPriceDecimals = dreUSDAmount * (10 ** (priceDecimals - dreUsdDecimals));
        }
  ```
- contracts/dreUSDOracle.sol:161-163
  ```solidity
          // tokenAmount = usdAmountInPriceDecimals * 10^tokenDecimals / price
        // forge-lint: disable-next-line(unsafe-typecast)
        tokenAmount = (usdAmountInPriceDecimals * (10 ** tokenDecimals)) / uint256(answer); // 10e8 * 10e6 / 0.99e8 = 10e14/0.99e8 = 10e6/0.99 = 10e4 / 99
  ```

**Assumptions:**
- Standard Chainlink price feeds return 8 decimal prices
- dreUSD always has 18 decimals as hardcoded
- This function is used for withdrawal pricing in dreUSDManager

**Notes for Auditor:**
The precision loss per call is small in absolute terms (< 1e-8 USD), but the arithmetic could be restructured to preserve full precision without additional gas cost. The key issue is dividing before multiplying — usdAmountInPriceDecimals loses 10 digits of precision, and the subsequent multiplication by 10^tokenDecimals cannot recover it. The recommended approach would be: tokenAmount = (dreUSDAmount * 10^tokenDecimals) / (uint256(answer) * 10^(dreUsdDecimals - priceDecimals)). This keeps the numerator at full precision. The severity is Medium because it systematically favors the protocol at the expense of users, even though individual losses are small.

- ACK

### setOracle allows MODERATOR_ROLE to change oracle feed without validation of the new feed's sanity (Medium)

- **ID:** 1d343f1bfa70d0fb
- **Category:** oracle
- **Location:** contracts/dreUSDOracle.sol:54-66
- **Contract:** dreUSDOracle
- **Function:** setOracle
- **Confidence:** High
- **Sources:** claude

**Impact:**
A compromised or malicious MODERATOR can set an oracle to any contract implementing AggregatorV3Interface, including a contract that returns arbitrary prices. There is no validation that the new oracle feed returns a reasonable price, that it implements the expected interface correctly, or that its decimals match expectations. An attacker-controlled oracle could return a price of 1 (essentially zero) allowing massive minting, or an extremely high price allowing withdrawal of all collateral. The staleness threshold has no upper bound either — setting it to type(uint256).max effectively disables staleness checks permanently. Since the function takes effect immediately with no timelock, a compromised moderator key can instantly manipulate all pricing in the system.

**Exploit Scenario:**
1. MODERATOR_ROLE private key is compromised (phishing, key leak, insider).
2. Attacker calls setOracle(USDC, attackerOracleContract, type(uint256).max).
3. attackerOracleContract.latestRoundData() returns answer = 1 (effectively price = 0.00000001 USD per USDC).
4. Attacker deposits 1 USDC into dreUSDManager.
5. getUsdValue calculates: (1e6 * 1) / 1e6 = 1 in price decimals, but the attacker's oracle could return answer = 1e16 (100M USD per USDC).
6. With answer = 1e16: usdValue = (1e6 * 1e16) / 1e6 = 1e16 in oracle decimals = 100,000,000 USD worth of dreUSD minted.
7. Attacker mints massive dreUSD from minimal collateral, then resets oracle and redeems for real collateral.
8. No timelock or sanity check prevents this instant exploit.

**Evidence:**
- contracts/dreUSDOracle.sol:54-66
  ```solidity
      function setOracle(
        address token,
        address oracleAddress,
        uint256 stalenessThreshold
    ) external onlyRole(MODERATOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (oracleAddress == address(0)) revert ZeroAddress();
        if (stalenessThreshold == 0) revert InvalidStalenessThreshold();

        oracles[token] = oracleAddress;
        stalenessThresholds[token] = stalenessThreshold;
        emit OracleSet(token, oracleAddress, stalenessThreshold);
    }
  ```

**Assumptions:**
- MODERATOR_ROLE is a hot key or multisig with lower security than DEFAULT_ADMIN_ROLE
- No external timelock wraps calls to setOracle

**Notes for Auditor:**
Verify the deployment architecture: if MODERATOR_ROLE is behind a timelock or a high-threshold multisig, the practical severity drops. However, the contract itself provides no defense-in-depth — no price sanity bounds, no timelock, no upper bound on staleness threshold. Recommend at minimum: (1) calling latestRoundData() on the new oracle to verify it returns a valid positive price, (2) bounding staleness threshold to a reasonable maximum (e.g., 1 day), (3) considering a timelock for oracle changes.

fixed
### Unbounded loop in burn when burning far-ahead token IDs causes gas exhaustion (Medium)

- **ID:** 9663ef4cb731d243
- **Category:** dos
- **Location:** contracts/dreWithdrawalNFT.sol:98-100
- **Contract:** dreWithdrawalNFT
- **Function:** burn
- **Confidence:** High
- **Sources:** claude

**Impact:**
If the BURNER_ROLE calls burn on a tokenId that is significantly higher than lastBurnedTokenId, the loop iterates (tokenId - lastBurnedTokenId - 1) times, each iteration performing an EnumerableSet.add which writes to storage. Each add costs ~20,000-44,000 gas (cold/warm SSTORE). With a gap of even a few hundred tokens, this could exceed the block gas limit, making the burn transaction revert. This effectively makes it impossible to fill a withdrawal position that is far ahead in the queue unless all intermediate positions are filled first (defeating the purpose of the out-of-order fill mechanism).

**Exploit Scenario:**
1. 1000 withdrawal positions are minted (tokens 1-1000). lastBurnedTokenId=0. 2. The keeper/manager wants to fill token 500 (e.g., because it's the most urgent or highest value). 3. burn(500) is called. The loop iterates from 1 to 499, performing 499 EnumerableSet.add operations. 4. At ~25,000 gas per add (average), this costs ~12.5M gas — potentially exceeding the block gas limit on many chains. 5. The transaction reverts, and token 500 cannot be burned/filled without first filling tokens 1-499 sequentially.

**Evidence:**
- contracts/dreWithdrawalNFT.sol:96-101
  ```solidity
  } else if (tokenId > lastBurnedTokenId + 1) {
            // Burning out of order: mark [lastBurnedTokenId+1, tokenId-1] as skipped
            for (uint256 id = lastBurnedTokenId + 1; id < tokenId; id++) {
                _skippedTokenIds.add(id);
            }
            lastBurnedTokenId = tokenId; // Pending range becomes [tokenId+1, ...]
  ```

**Assumptions:**
- The protocol intends to support out-of-order fills (the skip tracking logic confirms this)
- Large gaps between lastBurnedTokenId and the target tokenId are plausible in a real withdrawal queue

**Notes for Auditor:**
The severity depends on realistic queue sizes and how the manager calls burn. If the manager always fills sequentially, this is moot. But the existence of skip-tracking logic proves out-of-order fills are intended, making this a real DoS vector. The gas cost scales linearly with the gap size. On L2s with lower gas costs this is less severe, but on L1 Ethereum a gap of ~300+ tokens could be prohibitive.

intended
### \[By Design\] addRewards does not update cTs in the non-reset path, causing over-vesting after schedule extension (Low)

- **ID:** c84af3ca49e3bfa4
- **Category:** logic
- **Location:** contracts/dreRewardsDistributor.sol:120-132
- **Contract:** dreRewardsDistributor
- **Function:** addRewards
- **Confidence:** Medium
- **Sources:** claude

**Impact:**
In the else branch at line 129-131 (where eTs is extended but cTs is NOT updated), the vesting math becomes inconsistent. After _claimVested() runs at the start of addRewards, cTs is updated to block.timestamp. Then eTs is extended by rTs. But on the next claimVested call, `_computeVestedAmount` calculates `timePassed * rewards / (eTs - cTs)`. Since cTs was set to block.timestamp during the _claimVested inside addRewards, and eTs was extended beyond the original schedule, the denominator (eTs - cTs) correctly reflects the new total period. However, `rewards` now includes both old remaining and new rewards, and the rate computation uses the old rate to calculate rTs, which can lead to slight accounting discrepancies over multiple addRewards cycles. More importantly, the fact that cTs is NOT reset in this branch but WAS updated by _claimVested at line 163 means the math is actually self-consistent for this specific path. After deeper analysis, this particular path appears correct — the rate-matching logic preserves the linear vesting invariant.

**Exploit Scenario:**
1. Initial state: rewards=1000, cTs=T0, eTs=T0+7days, vestPeriod=7days. 2. At T0+3.5days, MODERATOR calls addRewards() after transferring 500 dreUSD. 3. _claimVested runs: vested = 3.5days * 1000 / 7days = 500. rewards = 500, cTs = T0+3.5days. 4. newRewards = balance - rewards. If balance = 500 + 500 = 1000, newRewards = 500. 5. rTs = 500 * (T0+7days - T0+3.5days) / 500 = 3.5days. 6. newVestPeriod = 3.5days + 3.5days = 7days. This equals vestPeriod, so condition at line 126 is `7days > 7days` (false) OR `7days < 6days` (false). 7. Falls into else: eTs = T0+7days + 3.5days = T0+10.5days. rewards = 1000. 8. Now vesting 1000 over 7 days (T0+3.5d to T0+10.5d) at same rate. This is correct. However, if at T0+7days someone calls claimVested: vested = 3.5days * 1000 / 7days = 500. Then at T0+10.5days: remaining 500 over remaining 3.5days = 500. Total = 1000. This is correct. The vulnerability is more subtle and occurs when addRewards is called multiple times in the else branch, where rounding errors in rTs accumulate.

**Evidence:**
- contracts/dreRewardsDistributor.sol:120-132
  ```solidity
              } else {
                // based on same linear vesting distribution rate, compute how much time new rewards adds to end timestamp
                uint256 rTs = newRewards * (eTs - cTs) / rewards;
                uint256 newVestPeriod = (eTs - cTs) + rTs;
                rewards = rewards + newRewards;
                // if higher than vestingPeriod or lower we redistribute everything over 7 days with new rewards rate
                if (newVestPeriod > vestPeriod || newVestPeriod < (vestPeriod - 1 days)) {
                    cTs = block.timestamp;
                    eTs = block.timestamp + vestPeriod;
                } else {
                    // extend end timestamp by time equivalent to new rewards at current rate
                    eTs = eTs + rTs;
                }
            }
  ```
- contracts/dreRewardsDistributor.sol:169-174
  ```solidity
      function _computeVestedAmount() internal view returns (uint256 vested, uint256 newClaimTimestamp) {
        newClaimTimestamp = block.timestamp > eTs ? eTs : block.timestamp;
        if (newClaimTimestamp - cTs == 0) return (0, newClaimTimestamp);
        uint256 timePassed = newClaimTimestamp - cTs;
        vested = timePassed * rewards / (eTs - cTs);
    }
  ```

**Assumptions:**
- Multiple addRewards calls hit the else branch (eTs extension without reset)
- Rounding in integer division of rTs accumulates over time

**Notes for Auditor:**
After thorough analysis, the else branch (line 129-131) maintains the correct vesting rate but may accumulate rounding dust over many iterations. Each rTs computation truncates, meaning the schedule end drifts slightly shorter than intended. Over many cycles this could leave small amounts of dreUSD permanently locked in the contract (dust, not exploitable for profit). The reset branch (line 127-128) corrects any accumulated drift. This is more of an accounting precision issue than an exploitable vulnerability, but worth noting for completeness.


intended (vested are liniar)
### Front-running reward distribution via sandwich attack on addRewards (Medium)

- **ID:** 973beebdeb9a0bcc
- **Category:** mev
- **Location:** contracts/dreUSDs.sol:74-76
- **Contract:** dreUSDs
- **Function:** totalAssets
- **Confidence:** Medium
- **Sources:** claude

**Impact:**
An attacker can dilute rewards intended for long-term stakers by depositing a large amount of dreUSD just before `addRewards()` is called on the distributor, then withdrawing shortly after rewards vest. Since `totalAssets()` includes `vestedAmount()`, the share price increases as rewards vest over time. The attacker captures a portion of rewards proportional to their share of total supply, despite providing no long-term liquidity. This is a value extraction from existing depositors.

**Exploit Scenario:**
1. Vault has 100,000 dreUSD deposited by legitimate stakers with 100,000 shares outstanding.
2. Attacker monitors the mempool and sees a keeper about to call `addRewards()` on the distributor with 10,000 dreUSD.
3. Attacker front-runs by depositing 100,000 dreUSD into the vault, receiving ~100,000 shares (now 200,000 total shares, attacker owns 50%).
4. Rewards begin vesting. As `vestedAmount()` increases, `totalAssets()` rises, increasing share price for everyone proportionally.
5. After full vesting, attacker redeems their 100,000 shares for ~105,000 dreUSD (their 100k + 50% of 10k rewards).
6. Legitimate stakers who held for the entire period only receive 50% of rewards instead of 100%.

**Evidence:**
- contracts/dreUSDs.sol:74-76
  ```solidity
      function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + IdreRewardsDistributor(rewardsDistributor).vestedAmount();
    }
  ```
- contracts/interfaces/IdreRewardsDistributor.sol:28-28
  ```solidity
      function addRewards() external;
  ```
- contracts/dreUSDs.sol:112-116
  ```solidity
      function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override whenNotPaused {
        // Claim vested rewards from distributor (user pays gas)
        _claimVestedRewards();
        super._deposit(caller, receiver, assets, shares);
    }
  ```

**Assumptions:**
- addRewards() calls are visible in the mempool before execution
- The vesting period is short enough for the attack to be economically viable
- There are no deposit/withdrawal cooldown periods or fees

**Notes for Auditor:**
This is a classic yield-dilution MEV attack. The `addRewards()` function on the distributor interface takes no access-control visible in the interface (though the implementation may restrict it). If the function is permissionless or its calls are predictable, attackers can time deposits to capture disproportionate yield. Mitigations include: deposit cooldown periods, withdrawal fees that decay over time, or streaming rewards in a way that doesn't benefit new depositors for a minimum period. Check the distributor's `addRewards()` implementation for access control and whether the vesting schedule makes this economically viable.

intended, its ok
### Daily fiat mint cap boundary allows 2x cap minting within seconds at UTC day boundary (Low)

- **ID:** 0d8109ec5cdc250d
- **Category:** econ
- **Location:** contracts/dreUSDManager.sol:644-655
- **Contract:** dreUSDManager
- **Function:** _checkAndUpdateDailyFiatMint
- **Confidence:** High
- **Sources:** claude

**Impact:**
The daily cap resets sharply at UTC midnight (when `block.timestamp / 86400` increments). A keeper can submit a `mintFromUsd` transaction for the full daily cap at 23:59:59 UTC and another for the full daily cap at 00:00:00 UTC, effectively minting 2x the daily cap within a very short window. This is a well-known weakness of fixed-window rate limiting versus sliding-window. The effective instantaneous burst is 2x the intended daily cap.

**Exploit Scenario:**
1. Daily fiat mint cap is 10M USD. 2. Keeper submits `mintFromUsd` for 10M USD at block timestamp 1706831999 (23:59:59 UTC). Day N counter: 10M/10M. 3. Next block at timestamp 1706832000 (00:00:00 UTC), keeper submits another `mintFromUsd` for 10M USD. Day N+1 counter: 10M/10M. 4. 20M USD of dreUSD minted within seconds, versus the intended 10M daily limit.

**Evidence:**
- contracts/dreUSDManager.sol:644-655
  ```solidity
      function _checkAndUpdateDailyFiatMint(uint256 usdAmount) internal {
        // Calculate current day number (timestamp / seconds per day)
        uint256 currentDay = block.timestamp / 1 days;
        uint256 newTotal = dailyFiatMinted[currentDay] + usdAmount;
        // will revert automatically if dailyFiatMintCapUsd is 0
        if (newTotal > dailyFiatMintCapUsd) { 
            revert DailyFiatMintCapExceeded(newTotal, dailyFiatMintCapUsd);
        }

        // Update daily minted amount for current day
        dailyFiatMinted[currentDay] += usdAmount;
    }
  ```

**Assumptions:**
- The daily cap is intended to limit the rate of fiat-backed minting for risk management
- Keeper transactions can be timed near day boundaries

**Notes for Auditor:**
This is a well-known weakness of fixed-window rate limiting. A rolling window or TWAP-based cap would be more robust but also more complex. The severity is Low because (1) the KEEPER_ROLE is trusted, (2) each mint still requires a valid custodian signature, and (3) the effective burst is bounded at 2x the cap. However, if the daily cap is set as a risk management measure against custodian key compromise, this doubles the exposure window.

ACK
### getUsdValue truncation favors users during minting — rounding down the USD value of deposited collateral (Low)

- **ID:** de53bda31a6ca122
- **Category:** math
- **Location:** contracts/dreUSDOracle.sol:116-116
- **Contract:** dreUSDOracle
- **Function:** getUsdValue
- **Confidence:** High
- **Sources:** claude

**Impact:**
The division truncates toward zero, which means the computed USD value of a token deposit is slightly less than its true value. For minting, this is protocol-favorable (user gets slightly less dreUSD). However, the rounding direction is not explicitly documented or controlled. For a stablecoin price slightly above $1 (e.g., 1.00000001e8), the truncation is negligible. But the absence of explicit rounding-direction policy means neither getUsdValue nor getTokenAmount has been designed with consistent rounding that always favors the protocol. In getTokenAmount, the final division also truncates toward zero (line 163), which means users receive slightly fewer tokens on withdrawal — also protocol-favorable. So both functions happen to round in the protocol's favor, but this is coincidental rather than by explicit design.

**Exploit Scenario:**
1. User deposits 1 USDC (1e6 units). Chainlink returns price = 100000001 (1.00000001 USD, 8 decimals).
2. usdValue = (1e6 * 100000001) / 1e6 = 100000001 in 8-decimal USD = 1.00000001 USD.
3. No truncation in this case because 1e6 divides evenly.
4. But for amount = 3 USDC and price = 99999999: usdValue = (3e6 * 99999999) / 1e6 = 299999997 (correct, no truncation here either for 6-decimal tokens).
5. For tokens with different decimals (e.g., 8 decimals like WBTC): amount = 1 unit, price = 99999999. usdValue = (1 * 99999999) / 1e8 = 0. User loses the full value.
6. While this is primarily a concern for non-stablecoin tokens with high decimals and tiny amounts, the truncation direction should be explicitly documented.

**Evidence:**
- contracts/dreUSDOracle.sol:114-116
  ```solidity
          // usdValue = amount * price / 10^tokenDecimals
        // forge-lint: disable-next-line(unsafe-typecast)
        usdValue = (amount * uint256(answer)) / (10 ** tokenDecimals);
  ```

**Assumptions:**
- getUsdValue is used for minting pricing
- getTokenAmount is used for withdrawal pricing
- Both functions truncate toward zero (Solidity default)

**Notes for Auditor:**
Both getUsdValue and getTokenAmount truncate toward zero via Solidity's integer division. For minting (getUsdValue), truncation means users get slightly less dreUSD — protocol-favorable. For withdrawals (getTokenAmount), truncation means users get slightly fewer tokens — also protocol-favorable. While this happens to be correct, it's worth documenting the intended rounding direction explicitly, and considering whether roundUp should be used for getUsdValue in any context where it's used to compute how much collateral a user must provide.

ACK
### No upper bound on staleness threshold allows effectively disabling staleness protection (Low)

- **ID:** cd3558922789a43e
- **Category:** dos
- **Location:** contracts/dreUSDOracle.sol:69-76
- **Contract:** dreUSDOracle
- **Function:** setStalenessThreshold
- **Confidence:** High
- **Sources:** claude

**Impact:**
Both setOracle and setStalenessThreshold only validate that the threshold is non-zero, but impose no upper bound. A MODERATOR can set stalenessThreshold to type(uint256).max, which makes the staleness check `block.timestamp - updatedAt > threshold` always false — effectively disabling staleness protection entirely. This means arbitrarily old oracle data (even from years ago) would be accepted as valid. While this requires a privileged role, the lack of an upper bound removes a critical safety guardrail. A reasonable maximum (e.g., 86400 for 1 day) would prevent accidental or malicious configuration that disables the protection.

**Exploit Scenario:**
1. MODERATOR calls setStalenessThreshold(USDC, type(uint256).max).
2. The Chainlink USDC/USD feed stops updating (feed deprecation, aggregator migration, network issues).
3. block.timestamp - updatedAt grows arbitrarily large, but never exceeds type(uint256).max.
4. The staleness check passes indefinitely: all calls to getUsdValue and getTokenAmount use the last-known price.
5. If the actual USDC price has depegged significantly, the stale price enables minting/withdrawal at incorrect rates.
6. The protocol has no automated mechanism to detect or prevent this — the staleness check was the defense.

**Evidence:**
- contracts/dreUSDOracle.sol:69-76
  ```solidity
      function setStalenessThreshold(address token, uint256 stalenessThreshold) external onlyRole(MODERATOR_ROLE) {
        if (oracles[token] == address(0)) revert OracleNotSet(token);
        if (stalenessThreshold == 0) revert InvalidStalenessThreshold();

        uint256 oldThreshold = stalenessThresholds[token];
        stalenessThresholds[token] = stalenessThreshold;
        emit StalenessThresholdUpdated(token, oldThreshold, stalenessThreshold);
    }
  ```
- contracts/dreUSDOracle.sol:57-61
  ```solidity
      ) external onlyRole(MODERATOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (oracleAddress == address(0)) revert ZeroAddress();
        if (stalenessThreshold == 0) revert InvalidStalenessThreshold();
  ```

**Assumptions:**
- MODERATOR_ROLE is trusted but may make configuration errors
- No external monitoring automatically revokes oracle feeds

**Notes for Auditor:**
This is more of a defense-in-depth concern. If MODERATOR is a multisig with good operational practices, they wouldn't set an absurd threshold. But bounding the value in the contract provides a hard safety limit against both malicious and accidental misconfiguration. Consider adding a maximum threshold constant (e.g., MAX_STALENESS = 86400 or 172800).

- FIXED - set to constant
### setVestPeriod can modify vesting parameters during active vesting without claiming first (Low)

- **ID:** 2908d936fed0772e
- **Category:** authz
- **Location:** contracts/dreRewardsDistributor.sol:98-103
- **Contract:** dreRewardsDistributor
- **Function:** setVestPeriod
- **Confidence:** High
- **Sources:** claude

**Impact:**
The vestPeriod variable is used in addRewards to determine whether to reset the vesting schedule (line 126-128). If MODERATOR changes vestPeriod between claimVested/addRewards calls, the threshold comparison at line 126 uses the new vestPeriod value, which could force an unexpected schedule reset or prevent one. For example, reducing vestPeriod right before calling addRewards could force the reset branch (because the existing schedule's remaining period exceeds the new shorter vestPeriod), effectively restarting the vesting clock and delaying the vault's access to already-partially-vested rewards.

**Exploit Scenario:**
1. Active vesting: rewards=1000, cTs=T0, eTs=T0+7days, vestPeriod=7days. 2. At T0+1day, MODERATOR calls setVestPeriod(2 days). 3. MODERATOR immediately calls addRewards() with 100 new dreUSD. 4. _claimVested: vested = 1day * 1000 / 7days ≈ 142. rewards = 858, cTs = T0+1day. 5. newRewards = 100. rTs = 100 * 6days / 858 ≈ 60480s. newVestPeriod = 6days + 60480s ≈ 6.7days. 6. Check: 6.7days > 2days (vestPeriod) → true → reset branch. 7. cTs = T0+1day, eTs = T0+1day + 2days = T0+3days. rewards = 958. 8. Now 958 dreUSD vests over just 2 days instead of the original ~6.7 days remaining. This accelerates distribution but also means any subsequent addRewards will also be forced into the reset branch due to the much shorter vestPeriod, creating unpredictable vesting behavior.

**Evidence:**
- contracts/dreRewardsDistributor.sol:98-103
  ```solidity
      function setVestPeriod(uint256 newVestPeriod) external onlyRole(MODERATOR_ROLE) {
        if (newVestPeriod == 0) revert ZeroVestPeriod();
        uint256 oldVestPeriod = vestPeriod;
        vestPeriod = newVestPeriod;
        emit VestPeriodUpdated(oldVestPeriod, newVestPeriod);
    }
  ```
- contracts/dreRewardsDistributor.sol:126-128
  ```solidity
                  if (newVestPeriod > vestPeriod || newVestPeriod < (vestPeriod - 1 days)) {
                    cTs = block.timestamp;
                    eTs = block.timestamp + vestPeriod;
  ```

**Assumptions:**
- MODERATOR_ROLE is trusted but might not understand the interaction between setVestPeriod and active vesting schedules

**Notes for Auditor:**
setVestPeriod does not call _claimVested() first, nor does it prevent modification during active vesting. This means the vestPeriod change takes effect retroactively on the next addRewards call, potentially causing unintended schedule resets. Consider whether setVestPeriod should be restricted when rewards > 0 or should trigger a _claimVested() first.
ACK
### Existing ERC20 approvals remain active after account is frozen (Low)

- **ID:** f38dab5c4fa6c26f
- **Category:** logic
- **Location:** contracts/dreUSD.sol:80-91
- **Contract:** dreUSD
- **Function:** freeze
- **Confidence:** High
- **Sources:** claude

**Impact:**
When an account is frozen, the `freeze` function only sets the `frozen` mapping to `true`. It does not clear existing ERC20 approvals. While the `_update` hook prevents actual transfers from/to frozen accounts, the approvals remain in storage. When the account is later unfrozen (e.g., after investigation), any pre-existing approvals immediately become usable again. Additionally, the standard `approve` function (inherited from ERC20Upgradeable) is NOT overridden to check freeze/sanctions status — only `permit` is overridden. This means a frozen account owner can still call `approve(spender, amount)` directly to set new approvals while frozen, positioning for instant fund movement upon unfreezing. The `permit` override blocks gasless approval setting for frozen accounts, but the direct `approve` path has no such restriction.

**Exploit Scenario:**
1. User A has approved spender S for 1,000,000 dreUSD via `approve(S, 1000000e18)`.
2. Guardian freezes User A due to suspicious activity.
3. During the freeze, User A calls `approve(S2, type(uint256).max)` — this succeeds because `approve` is not overridden with freeze checks.
4. Investigation concludes and Guardian unfreezes User A.
5. Immediately (potentially in the same block via a bot), S2 calls `transferFrom(A, attacker, balance)` to drain all of A's tokens before any further action can be taken.
6. The pre-positioned approval during the freeze period enabled instant extraction.

**Evidence:**
- contracts/dreUSD.sol:80-84
  ```solidity
      function freeze(address account) external onlyGuardian {
        if (account == address(0)) revert ZeroAddress();
        frozen[account] = true;
        emit AddressFrozen(account);
    }
  ```
- contracts/dreUSD.sol:146-156
  ```solidity
      function _update(address from, address to, uint256 value) internal override {
        // Skip validation for address(0) to allow minting and burning
        if (from != address(0)) {
            _validateAddress(from);
        }
        if (to != address(0)) {
            _validateAddress(to);
        }

        super._update(from, to, value);
    }
  ```
- contracts/dreUSD.sol:103-116
  ```solidity
      function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual override {
        _validateAddress(owner);
        _validateAddress(spender);

        super.permit(owner, spender, value, deadline, v, r, s);
    }
  ```

**Assumptions:**
- The frozen account holder is actively trying to circumvent the freeze
- The account will eventually be unfrozen (otherwise the approvals are moot since transfers are blocked)

**Notes for Auditor:**
The `permit` function is properly overridden to check freeze/sanctions on both owner and spender. However, the standard `approve` function from ERC20Upgradeable is NOT overridden with the same checks. This creates an asymmetry: gasless approvals (permit) are blocked for frozen accounts, but direct approvals (approve) are not. Consider whether `approve` and `increaseAllowance`/`decreaseAllowance` should also enforce freeze checks. Note that the actual token transfer is still blocked by `_update`, so the direct exploit requires unfreezing first — but the ability to set up approvals while frozen weakens the freeze protection.

ACK

### setVault has no transition safety — changing vault while allowance is from old vault causes immediate withdrawal failures (Low)

- **ID:** 98facfe8b7e55d5a
- **Category:** logic
- **Location:** contracts/dreAaveAdapter.sol:157-162
- **Contract:** dreAaveAdapter
- **Function:** setVault
- **Confidence:** High
- **Sources:** claude

**Impact:**
If `setVault` is called and the new vault has not yet approved the adapter for aUSDC spending, all subsequent `withdraw` calls will revert at the `safeTransferFrom` line. If the WITHDRAWER_ROLE (dreUSDManager) has pending withdrawal requests that need to be filled from Aave, those withdrawals will fail until the new vault sets up its approval. This creates a denial-of-service window during vault migration. In a worst case, if the admin sets the vault to an address they control that has approved the adapter, they could redirect withdrawals to pull from a different source.

**Exploit Scenario:**
1. Admin calls `setVault(newMultisig)`. 2. `newMultisig` has not yet called `aUSDC.approve(adapter, amount)`. 3. dreUSDManager calls `adapter.withdraw(amount, recipient)`. 4. `getAvailableBalance()` returns 0 (allowance from new vault is 0), causing `InsufficientBalance` revert. 5. All Aave-sourced withdrawals are blocked until new vault approves the adapter.

**Evidence:**
- contracts/dreAaveAdapter.sol:157-162
  ```solidity
      function setVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_vault == address(0)) revert ZeroAddress();
        address oldVault = vault;
        vault = _vault;
        emit VaultUpdated(oldVault, _vault);
    }
  ```
- contracts/dreAaveAdapter.sol:104-105
  ```solidity
          // Transfer aTokens from vault to this contract
        IERC20(aUsdc).safeTransferFrom(vault, address(this), amount);
  ```

**Assumptions:**
- Vault migration requires coordinated approval setup
- There may be pending withdrawal requests when vault is changed

**Notes for Auditor:**
There is no validation that the new vault has aUSDC balance or has approved the adapter. While this is an admin-only operation, the lack of any transition mechanism (e.g., requiring the new vault to pre-approve, or a two-step vault change) means a misconfigured `setVault` call immediately breaks all withdrawals. Consider recommending a two-step vault migration or at minimum a check that the new vault has approved the adapter.

FIXED - removed
### lastBurnedTokenId only advances forward — burning token below current lastBurnedTokenId doesn't compact the skipped set or advance the watermark (Low)

- **ID:** c5342458bbcf0533
- **Category:** logic
- **Location:** contracts/dreWithdrawalNFT.sol:103-106
- **Contract:** dreWithdrawalNFT
- **Function:** burn
- **Confidence:** High
- **Sources:** claude

**Impact:**
When all skipped tokens in a contiguous range below lastBurnedTokenId are eventually burned, the _skippedTokenIds set becomes empty for that range but lastBurnedTokenId doesn't advance to reflect this. For example, if tokens 1-5 are minted, burn(5) is called (setting lastBurnedTokenId=5, skipped={1,2,3,4}), then burn(1), burn(2), burn(3), burn(4) are called — after all four, _skippedTokenIds is empty, but getPendingRange still returns startTokenId=6 which is correct. However, the _skippedTokenIds set grew to size 4 and was never compacted — the adds/removes create gas overhead. More importantly, the logic doesn't attempt to advance lastBurnedTokenId when consecutive skipped entries at the frontier are cleared. This means the 'pending range' is always correct but the skipped set acts as an ever-growing dirty-flag tracker that only shrinks when individual entries are explicitly removed.

**Exploit Scenario:**
1. Tokens 1-100 minted. 2. burn(100) called — skipped set grows to {1,2,...,99} (99 entries). 3. Tokens 1-99 are burned one by one. Each burn removes one entry from skipped. 4. After all burns, skipped set is empty. But the gas cost of burn(100) was enormous (99 set additions), and the 99 subsequent burns each had to check/remove from the set. 5. The _skippedTokenIds set length oscillates but never triggers a compaction of lastBurnedTokenId when contiguous lower IDs are cleared.

**Evidence:**
- contracts/dreWithdrawalNFT.sol:92-106
  ```solidity
  if (tokenId == lastBurnedTokenId + 1) {
            // Burning in order: advance the front of the queue
            lastBurnedTokenId = tokenId;
            _skippedTokenIds.remove(tokenId);
        } else if (tokenId > lastBurnedTokenId + 1) {
            // Burning out of order: mark [lastBurnedTokenId+1, tokenId-1] as skipped
            for (uint256 id = lastBurnedTokenId + 1; id < tokenId; id++) {
                _skippedTokenIds.add(id);
            }
            lastBurnedTokenId = tokenId; // Pending range becomes [tokenId+1, ...]
        }
        if (tokenId <= lastBurnedTokenId) {
            // Filling a gap (e.g. burn 1 after burning 3): remove from skipped
            _skippedTokenIds.remove(tokenId);
        }
  ```

**Assumptions:**
- The manager processes burns in various orders over time
- The skipped set can accumulate significant entries

**Notes for Auditor:**
This is more of a design inefficiency than a security vulnerability. The lack of frontier advancement means getPendingRange's startTokenId is accurate but the skipped set carries unnecessary bookkeeping burden. In extreme cases with large out-of-order burns followed by in-order cleanup, gas costs are amplified. Consider whether a compaction mechanism (advancing lastBurnedTokenId when consecutive skipped entries are cleared) would improve efficiency.

### initialize missing __UUPSUpgradeable_init call (Low)

- **ID:** 813ca55f01203973
- **Category:** logic
- **Location:** contracts/dreUSDOracle.sol:41-51
- **Contract:** dreUSDOracle
- **Function:** initialize
- **Confidence:** Medium
- **Sources:** claude

**Impact:**
The initialize function calls __AccessControl_init() but does not call __UUPSUpgradeable_init(). While the OpenZeppelin v5 UUPSUpgradeable's init function is currently a no-op (it only calls __UUPSUpgradeable_init_unchained which is also empty), omitting it deviates from the recommended initialization pattern. If a future OZ upgrade adds initialization logic to UUPSUpgradeable, this contract would miss it. This is a minor correctness issue but follows the recommended OpenZeppelin initialization pattern for upgradeable contracts.

**Exploit Scenario:**
1. Contract is deployed and initialized without calling __UUPSUpgradeable_init().
2. Currently this has no functional impact because the OZ v5 implementation is a no-op.
3. If a future OpenZeppelin version adds state initialization to UUPSUpgradeable, upgrading the dependency without updating initialize() could leave UUPSUpgradeable in an uninitialized state.
4. This is a maintenance hazard rather than an active vulnerability.

**Evidence:**
- contracts/dreUSDOracle.sol:41-51
  ```solidity
      function initialize(
        address defaultAdmin
    ) public initializer {
        if (defaultAdmin == address(0)) revert ZeroAddress();
        
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, defaultAdmin);
        _grantRole(MODERATOR_ROLE, defaultAdmin);
    }
  ```

**Assumptions:**
- Using OpenZeppelin Contracts Upgradeable v5.x where UUPSUpgradeable init is a no-op
- Future OpenZeppelin versions may add initialization logic

**Notes for Auditor:**
Low severity because the current OZ v5 implementation has no initialization logic in UUPSUpgradeable. However, best practice for upgradeable contracts is to call all parent initializers to be future-proof.

FIXED
### Frozen accounts can still receive tokens via mint path (Low)

- **ID:** 8fe02590d999d22e
- **Category:** logic
- **Location:** contracts/dreUSD.sol:146-156
- **Contract:** dreUSD
- **Function:** _update
- **Confidence:** Medium
- **Sources:** claude

**Impact:**
The `_update` function correctly validates the `to` address even when `from` is `address(0)` (mint path), so frozen/sanctioned addresses cannot receive minted tokens. However, the `burn` path (where `to` is `address(0)`) skips `to` validation but still validates `from`. This means tokens cannot be burned FROM frozen accounts via the MANAGER_ROLE `burn` function. A frozen account's tokens become permanently locked — they cannot transfer out AND the manager cannot burn them. This could be the desired compliance behavior (preserving evidence/frozen assets) but could also prevent the protocol from recovering tokens from a frozen malicious account.

**Exploit Scenario:**
1. Guardian freezes address X that holds 100,000 dreUSD.
2. The protocol discovers X obtained tokens fraudulently and wants to burn/recover them.
3. Manager calls `burn(X, 100000e18)` but the transaction reverts because `_update` calls `_validateAddress(X)` which reverts with `FrozenAddress(X)`.
4. To burn the tokens, the guardian must first `unfreeze(X)`, at which point X could front-run with a `transfer` to move tokens to another address before the burn executes.
5. The guardian cannot atomically unfreeze-burn-refreeze because only GUARDIAN_ROLE can unfreeze but only MANAGER_ROLE can burn, requiring two separate transactions.

**Evidence:**
- contracts/dreUSD.sol:146-156
  ```solidity
      function _update(address from, address to, uint256 value) internal override {
        // Skip validation for address(0) to allow minting and burning
        if (from != address(0)) {
            _validateAddress(from);
        }
        if (to != address(0)) {
            _validateAddress(to);
        }

        super._update(from, to, value);
    }
  ```
- contracts/dreUSD.sol:70-72
  ```solidity
      function mint(address to, uint256 amount) external onlyRole(MANAGER_ROLE) {
        _mint(to, amount);
    }
  ```

**Assumptions:**
- MANAGER_ROLE and GUARDIAN_ROLE are held by different addresses/multisigs
- The protocol may need to burn tokens from frozen accounts for compliance enforcement

**Notes for Auditor:**
This is a design tension between compliance (freeze = no movement) and enforcement (need to confiscate/burn frozen tokens). The front-running risk during unfreeze-then-burn is real if the frozen account holder is monitoring the mempool. Consider whether a dedicated confiscate function with appropriate role checks would be appropriate. Note that the _update hook correctly validates both from and to on all paths (mint validates to, burn validates from, transfer validates both), so the freeze enforcement itself is complete — the issue is about the inability to perform administrative burns on frozen accounts.

ACK
### recoverToken can drain aTokens that were transferred to the adapter mid-withdrawal flow (Low)

- **ID:** 1f4e17e3922e19f3
- **Category:** authz
- **Location:** contracts/dreAaveAdapter.sol:169-176
- **Contract:** dreAaveAdapter
- **Function:** recoverToken
- **Confidence:** Medium
- **Sources:** claude

**Impact:**
A compromised or malicious DEFAULT_ADMIN_ROLE holder can call `recoverToken(aUsdc, attacker)` to sweep any aTokens that happen to be sitting in the adapter. Under normal operation the adapter should not hold aTokens for more than a single transaction, but in edge cases (failed Aave withdraw, or if aToken dust accumulates per the previous finding), this enables extraction. More critically, there is no restriction preventing `recoverToken` from being called with `token = usdc`, which could drain any USDC that transiently sits in the adapter.

**Exploit Scenario:**
1. Dust aTokens accumulate in the adapter over many withdrawals (per previous finding). 2. Compromised admin calls `recoverToken(aUsdc, attackerAddress)`. 3. All accumulated aTokens are transferred to the attacker. Alternatively: if any future upgrade or integration causes USDC or aUSDC to be held in the adapter, admin can drain it.

**Evidence:**
- contracts/dreAaveAdapter.sol:169-176
  ```solidity
      function recoverToken(address token, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(recipient, balance);
        }
    }
  ```
- contracts/dreAaveAdapter.sol:43-44
  ```solidity
      /// @notice aUSDC token address (Aave interest-bearing USDC)
    address public aUsdc;
  ```

**Assumptions:**
- DEFAULT_ADMIN_ROLE could be compromised or act maliciously
- The adapter holds tokens (even dust) between or after transactions

**Notes for Auditor:**
This is bounded by the trust assumption on DEFAULT_ADMIN_ROLE. However, the function has no restriction on which tokens can be recovered — it can recover aUSDC and USDC, not just accidentally-sent random tokens. A more defensive implementation would exclude known operational tokens (aUsdc, usdc) or require a timelock.

ACK
### getAvailableBalance uses USDC balance of aToken contract as proxy for Aave pool liquidity — can be manipulated via flash loans (Low)

- **ID:** ef7639e8d64c874f
- **Category:** integration
- **Location:** contracts/dreAaveAdapter.sol:122-124
- **Contract:** dreAaveAdapter
- **Function:** getAvailableBalance
- **Confidence:** Medium
- **Sources:** claude

**Impact:**
The available liquidity check queries the USDC balance held by the aToken contract (`IERC20(usdc).balanceOf(aUsdc)`). This balance can be temporarily manipulated: (1) An attacker takes a flash loan from Aave, draining USDC from the aToken contract, causing `getAvailableBalance` to return a lower value. This could cause legitimate withdrawal calls from dreUSDManager to revert with `InsufficientBalance` during the same transaction. (2) Conversely, someone could deposit a large amount of USDC into Aave in the same block to inflate the available liquidity reading. While the `withdraw` call on line 108 would still fail if actual Aave liquidity is insufficient, the `getAvailableBalance` view function could return misleading values to off-chain systems that rely on it for withdrawal queue management.

**Exploit Scenario:**
1. Off-chain keeper calls `getAvailableBalance()` to determine how much can be withdrawn. 2. In the same block, an attacker initiates a flash loan from Aave that borrows most USDC from the pool. 3. `IERC20(usdc).balanceOf(aUsdc)` returns near-zero. 4. `getAvailableBalance()` returns near-zero even though the vault has ample aUSDC. 5. Keeper skips the withdrawal thinking no liquidity is available. 6. Flash loan is repaid in the same transaction, liquidity is restored, but the withdrawal opportunity was missed.

**Evidence:**
- contracts/dreAaveAdapter.sol:122-124
  ```solidity
          // Also check Aave pool liquidity
        uint256 availableLiquidity = IERC20(usdc).balanceOf(aUsdc);
        
  ```
- contracts/dreAaveAdapter.sol:100-102
  ```solidity
          // Check vault has enough aUSDC and has given us allowance
        uint256 available = getAvailableBalance();
        if (available < amount) revert InsufficientBalance(available, amount);
  ```

**Assumptions:**
- Off-chain systems rely on getAvailableBalance for withdrawal queue decisions
- Flash loans can temporarily drain Aave pool USDC within a single transaction

**Notes for Auditor:**
The on-chain `withdraw` function also calls `getAvailableBalance` as a pre-check (line 101-102). If an attacker flash-borrows from Aave in the same transaction, they could cause the WITHDRAWER_ROLE's withdraw call to revert by temporarily draining Aave liquidity. However, the attacker gains no direct economic benefit from this griefing. The real Aave pool's `withdraw` call on line 108 would fail naturally if liquidity is truly insufficient, so the pre-check is redundant in that scenario — but the flash loan manipulation means the pre-check could spuriously fail even when the subsequent Aave withdraw would succeed (because the flash loan would be repaid by then). In practice, the temporal ordering within a single transaction makes this less exploitable, but it's worth noting the assumption about USDC balance as a liquidity proxy.


## Suppressed Findings
Suppressed findings: 0.
Dropped by LLM top-50 cap: 0.
Dismissed by LLM review: 19.
Baseline file: /workspaces/auzitor/target/dreusd-main/.audit-baseline.json

## Run Metadata
- Run ID: 3aa6cef1-3dc3-49c9-b502-4a8629077630
- Timestamp: 2026-02-12T11:38:50.173Z
- Duration (ms): 1293983
- Commit: 1f3542beedf7c44e8b482fce40cd53621d6be50a
- Forge: forge Version: 1.5.1-stable
- Slither: 0.11.5
- Aderyn: aderyn 0.1.9