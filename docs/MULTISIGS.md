# Multisigs Required

This document lists the multisigs needed to run the dreUSD system, assuming important roles (e.g. super admin) and all vaults/treasuries are multisigs.

---

## 1. Governance / Super Admin

| Item | Description |
|------|-------------|
| **Purpose** | Highest privilege: grant/revoke roles, own admin on all core contracts. |
| **Roles** | `DEFAULT_ADMIN_ROLE` on: dreUSDManager, dreUSD, dreUSDOracle, dreWithdrawalNFT (both instances), dreUSDs, dreRewardsDistributor, dreAaveAdapter (and any other upgradeable/admin contracts). |
| **Notes** | Should be a timelocked or high-threshold multisig. Can also hold `UPGRADER_ROLE` or delegate it to a separate Upgrader multisig. |

---

## 2. Upgrader

| Item | Description |
|------|-------------|
| **Purpose** | Authorize implementation upgrades for UUPS proxies. |
| **Roles** | `UPGRADER_ROLE` on all upgradeable contracts (dreUSDManager, dreUSD, dreUSDOracle, dreWithdrawalNFT instances, dreUSDs, dreRewardsDistributor, dreAaveAdapter). |
| **Notes** | Can be the same multisig as Governance or a dedicated one (e.g. behind timelock). |

---

## 3. Treasury

| Item | Description |
|------|-------------|
| **Purpose** | Holds protocol-owned funds; executes withdrawal fills, admin withdrawals, and express debt payback. Also receives express withdrawal fees when set as express fee recipient. |
| **Roles** | `TREASURY_ROLE` on dreUSDManager. |
| **Actions** | `fillWithdrawal()`, `adminWithdraw(token, to, amount)`, `payExpressDebt(amount)`. Receives tokens when `adminWithdraw` is used to sweep to treasury. Receives express fees when configured as express fee recipient in `updateExpressWithdrawal(..., feeRecipient)`. |
| **Notes** | Primary protocol treasury multisig. **Express Fee Recipient** can be this same address—set Treasury as `feeRecipient` in `updateExpressWithdrawal`. |

---

## 4. Deposit / Custodian Vault

| Item | Description |
|------|-------------|
| **Purpose** | Receives all stablecoin from user mints (ERC20 mint, mintFromUsd, mintAndStake, etc.). |
| **Config** | Set via `updateVault(address)` (MODERATOR_ROLE) on dreUSDManager; stored as `custodianVault`. |
| **Notes** | Holds user-deposited stablecoin before it is moved elsewhere. Should be a multisig for custody and operational control. |

---

## 5. Express Payback Address *(not ours)*

| Item | Description |
|------|-------------|
| **Purpose** | Receives USDC when `payExpressDebt(amount)` is called (payback to express filler). |
| **Config** | Set via `updateExpressPaybackAddress(address)` (WITHDRAWAL_CONFIG_ROLE) on dreUSDManager; stored as `expressPaybackAddress`. |
| **Notes** | **Not our multisig.** This is our partner’s address (the entity that fills express withdrawals and is owed payback). We only configure it; we do not control this address. |

---

## 6. Moderator (single address)

| Item | Description |
|------|-------------|
| **Purpose** | Single multisig for all config: mint/deposit policy, withdrawal/express params, and oracle. |
| **Roles** | `MODERATOR_ROLE` on dreUSDManager; `WITHDRAWAL_CONFIG_ROLE` on dreUSDManager; `MODERATOR_ROLE` on dreUSDOracle. |
| **Actions** | *dreUSDManager (MODERATOR):* `setSanctionsList()`, `updateVault()`, `updateCustodianList()`, `setDailyFiatMintCap()`, `updateAllowedList()`. *dreUSDManager (WITHDRAWAL_CONFIG):* `updateExpressPaybackAddress()`, `updateExpressWithdrawal()`, `updateWithdrawal()`, `updateVaultAdapter()`. *dreUSDOracle:* `setOracle()`, `setStalenessThreshold()`, `removeOracle()`. |
| **Notes** | One address can hold all three roles (Moderator + Withdrawal Config + Oracle Moderator). |

---

## 7. Guardian

| Item | Description |
|------|-------------|
| **Purpose** | Freeze/unfreeze addresses on dreUSD (incident response, sanctions). |
| **Roles** | `GUARDIAN_ROLE` on dreUSD. |
| **Actions** | `freeze()`, `unfreeze()`. |
| **Notes** | Security/incident response; should be a small, fast multisig or trusted party. |

---

## 8. Pauser

| Item | Description |
|------|-------------|
| **Purpose** | Emergency pause of mint/withdrawal and (where applicable) staking rewards. |
| **Roles** | `PAUSER_ROLE` on dreUSDManager, dreUSDs, dreRewardsDistributor. |
| **Actions** | `pause()`, `unpause()`. |
| **Notes** | Can be same as Governance or Guardian for speed in emergencies. |

---

## Optional / Can Be EOA or Automation

- **Keeper** – `KEEPER_ROLE` on dreUSDManager; calls `mintFromUsd()`. Often an EOA or relayer/bot.
- **Express Operator** – `EXPRESS_OPERATOR_ROLE` on dreUSDManager; calls `fillExpressWithdrawals()`. Can be EOA or bot; payback goes to Express Payback Address (partner’s address, not ours).

---

## Summary Table

| # | Multisig | Primary use |
|---|----------|-------------|
| 1 | Governance / Super Admin | Admin on all contracts |
| 2 | Upgrader | Contract upgrades |
| 3 | Treasury | Treasury ops, withdrawal fills, payExpressDebt; also express fee recipient |
| 4 | Deposit / Custodian Vault | Receives user stablecoin from mints |
| 5 | Express Payback Address *(not ours)* | Partner’s address; receives express filler payback |
| 6 | Moderator | Mint/deposit policy + withdrawal/oracle config (single address) |
| 7 | Guardian | Freeze/unfreeze (dreUSD) |
| 8 | Pauser | Emergency pause |

**Express Fee Recipient** = Treasury (set Treasury as `feeRecipient` in `updateExpressWithdrawal`). **Moderator** holds MODERATOR_ROLE + WITHDRAWAL_CONFIG_ROLE on dreUSDManager and MODERATOR_ROLE on dreUSDOracle. Same physical multisig can hold other roles (e.g. Governance + Upgrader) to reduce signer sets.
