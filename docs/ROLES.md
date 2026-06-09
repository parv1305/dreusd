# Roles Documentation

This document outlines all roles required for each contract in the dreUSD system.

## dreUSDManager

**Contract**: `contracts/dreUSDManager.sol`

### Roles

- **DEFAULT_ADMIN_ROLE**: Full administrative control, can grant/revoke all other roles
  - Grants: All roles during initialization
  - Functions: All admin functions via role management

- **UPGRADER_ROLE**: Authorizes contract upgrades
  - Functions: `_authorizeUpgrade()`

- **KEEPER_ROLE**: Processes fiat mints from custodian
  - Functions:
    - `mintFromUsd()`
    - `mintRewards()`

- **EXPRESS_OPERATOR_ROLE**: Operates the express withdrawal queue (6h); fills express positions
  - Functions:
    - `fillExpressWithdrawals()`

- **TREASURY_ROLE**: Manages treasury operations, withdrawal fills, and express debt payback
  - Functions:
    - `fillWithdrawal()`
    - `adminWithdraw()`
    - `payExpressDebt(amount)`

- **MODERATOR_ROLE**: Configures mint/deposit policy and compliance
  - Functions:
    - `updateVault()`
    - `updateCustodianList(address, bool)`
    - `setDailyFiatMintCap()` — must be called before `mintFromUsd()` or `mintRewards()` can succeed (cap defaults to 0)
    - `updateAllowedList(token, bool)`

- **WITHDRAWAL_CONFIG_ROLE**: Configures withdrawal queues and express parameters
  - Functions:
    - `updateExpressPaybackAddress()`
    - `updateExpressWithdrawal(maxLimit, feeBps, feeRecipient)`
    - `updateWithdrawal(waitingTime)`
    - `updateVaultAdapter()`

- **PAUSER_ROLE**: Pauses and unpauses mint and withdrawal operations
  - Functions:
    - `pause()`
    - `unpause()`

## dreUSD

**Contract**: `contracts/dreUSD.sol`

### Roles

- **DEFAULT_ADMIN_ROLE**: Full administrative control
  - Functions:
    - `setSanctionsList()`
    - `setDreUSDManager(address)` — sets the single contract allowed to call `mint()` and `burn()`

- **UPGRADER_ROLE**: Authorizes contract upgrades
  - Functions: `_authorizeUpgrade()`

- **dreUSDManager (single address)**: Only this address may mint and burn dreUSD
  - Set at initialization or via `setDreUSDManager(address)` (DEFAULT_ADMIN_ROLE)
  - Functions (callable only by the set address):
    - `mint()`
    - `burn()`
  - Note: Intended to be the `dreUSDManager` contract only; not a role (no grant/revoke)

- **GUARDIAN_ROLE**: Freezes and unfreezes addresses (enforced via `onlyGuardian` modifier)
  - Functions:
    - `freeze()`
    - `unfreeze()`

## dreUSDOracle

**Contract**: `contracts/dreUSDOracle.sol`

### Roles

- **DEFAULT_ADMIN_ROLE**: Full administrative control
  - Grants: All roles during initialization

- **UPGRADER_ROLE**: Authorizes contract upgrades
  - Functions: `_authorizeUpgrade()`

- **MODERATOR_ROLE**: Manages oracle configuration
  - Functions:
    - `setOracle()`
    - `setStalenessThreshold()`
    - `setDeviationThreshold()`
    - `setSequencerUptimeFeed()`
    - `setGracePeriod()`
    - `removeOracle()`

## dreRewardsDistributor

**Contract**: `contracts/dreRewardsDistributor.sol`

### Roles

- **DEFAULT_ADMIN_ROLE**: Full administrative control
  - Grants: All roles during initialization
  - Note: Vault address is immutable (set in constructor)

- **UPGRADER_ROLE**: Authorizes contract upgrades
  - Functions: `_authorizeUpgrade()`

- **MODERATOR_ROLE**: Manages reward distribution and vesting configuration
  - Functions:
    - `addRewards()` - Adds new rewards and vests them over the vest period (call after transferring dreUSD into the distributor)
  - Note: Typically granted to `dreUSDManager` contract so it can call `addRewards()` in `mintRewards()`

- **PAUSER_ROLE**: Pauses and unpauses reward claiming
  - Functions:
    - `pause()`
    - `unpause()`

- **Public Functions** (no role required):
  - `claimVested()` - Transfers vested dreUSD from distributor to vault (callable only by the vault, to keep vault _virtualBalance in sync)
  - Note: Typically called by `dreUSDs` vault contract or anyone

## dreAaveAdapter

**Contract**: `contracts/dreAaveAdapter.sol`

### Roles

- **DEFAULT_ADMIN_ROLE**: Full administrative control
  - Functions:
    - `setVault()`
    - `recoverToken()`
    - `setDreUSDManager(address)` — sets the single contract allowed to call `withdraw()`

- **UPGRADER_ROLE**: Authorizes contract upgrades
  - Functions: `_authorizeUpgrade()`

- **dreUSDManager (single address)**: Only this address may withdraw from the Aave vault
  - Set in `initialize(..., manager)` or via `setDreUSDManager(address)` (DEFAULT_ADMIN_ROLE)
  - Functions (callable only by the set address):
    - `withdraw()`
  - Note: Intended to be the `dreUSDManager` contract only; not a role (no grant/revoke)

## dreWithdrawalNFT

**Contract**: `contracts/dreWithdrawalNFT.sol`

### Roles

- **DEFAULT_ADMIN_ROLE**: Full administrative control
  - Grants: All roles during initialization
  - Functions: `setDreUSD()`, `setDreUSDManager(address)` — sets the single contract allowed to call `mint()` and `burn()`

- **UPGRADER_ROLE**: Authorizes contract upgrades
  - Functions: `_authorizeUpgrade()`

- **dreUSDManager (single address)**: Only this address may mint and burn withdrawal positions
  - Set via `setDreUSDManager(address)` (DEFAULT_ADMIN_ROLE)
  - Functions (callable only by the set address):
    - `mint()`
    - `burn()`
  - Note: Intended to be the `dreUSDManager` contract only; not a role (no grant/revoke)

## dreWithdrawalNFT (express queue)

**Contract**: `contracts/dreWithdrawalNFT.sol` (same contract, second instance for express queue)

### Roles

- Same as standard dreWithdrawalNFT above. **dreUSDManager** is set per instance via `setDreUSDManager(address)` (DEFAULT_ADMIN_ROLE); only that address may call `mint()` and `burn()`.

## dreUSDs

**Contract**: `contracts/dreUSDs.sol`

### Roles

- **DEFAULT_ADMIN_ROLE**: Full administrative control
  - Functions: `setRewardsDistributor()`, `withdrawExcessDreUSD(address)` (recover donated dreUSD above _virtualBalance)

- **UPGRADER_ROLE**: Authorizes contract upgrades
  - Functions: `_authorizeUpgrade()`

- **PAUSER_ROLE**: Pauses and unpauses deposit and withdraw operations
  - Functions:
    - `pause()`
    - `unpause()`

## Role Assignment Summary

### Typical Assignments

- **dreUSDManager contract** must be set as the single allowed caller for privileged functions (not roles; cannot be granted to multiple addresses):
  - **dreUSD**: `setDreUSDManager(manager)` so only the manager can call `mint()` and `burn()`
  - **dreAaveAdapter**: `setDreUSDManager(manager)` (or set in adapter `initialize`) so only the manager can call `withdraw()`
  - **dreWithdrawalNFT** (both instances): `setDreUSDManager(manager)` on each so only the manager can call `mint()` and `burn()`
- **dreUSDManager** receives `MODERATOR_ROLE` on `dreRewardsDistributor` during setup so it can call `addRewards()` in `mintRewards()`

- **dreUSDs** (or anyone) can call:
  - `claimVested()` on `dreRewardsDistributor` (callable only by the vault)

- **Default Admin** typically receives:
  - `DEFAULT_ADMIN_ROLE` on all contracts
  - `UPGRADER_ROLE` on all contracts
  - `MODERATOR_ROLE` on `dreUSDManager` and `dreUSDOracle` during initialization
  - `PAUSER_ROLE` on `dreUSDManager`, `dreUSDs`, and `dreRewardsDistributor` during initialization

- **Single compliance source (spoke chains):** dreShareOFT uses immutable dreUSD address (same across all chains) for all transfer validation; no local sanctions/freeze state. Compliance is enforced solely via dreUSD.validateAddress(...).