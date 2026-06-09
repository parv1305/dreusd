# dreVault — USDC forwarding pipeline

`dreVault` is a non-upgradeable holding contract that receives USDC (or any configured ERC20) and forwards the **full balance** to a fixed downstream address when Chainlink Automation runs `performUpkeep`.

Use it to route mint proceeds from `dreUSDManager` through one or two on-chain hops before funds reach a corporate wallet (e.g. Utila).

---

## Architecture

```text
User USDC/USDT
       │
       ▼
  dreUSDManager  (mint / mintFrom / mintAndStake)
       │  safeTransfer → custodianVault
       ▼
  dreVault (hop 1)  ──performUpkeep──►  dreVault (hop 2)  ──performUpkeep──►  Utila wallet
```

- **Hop 1** receives stablecoin from the manager (`custodianVault`).
- **Hop 2** receives USDC from hop 1 and forwards to the corporate wallet.
- Each hop is a **separate** `dreVault` deployment and a **separate** Chainlink Automation upkeep.

For a single hop (manager → corporate wallet), deploy only one `dreVault` and set `forwardVault` to the Utila address.

---

## Contract

| Item | Detail |
|------|--------|
| Contract | `contracts/dreVault.sol` |
| Interface | `contracts/interfaces/IdreVault.sol` |
| Token | Immutable ERC20 (`token`), typically USDC (6 decimals) |
| Forward target | Immutable `forwardVault` (another `dreVault` or EOA/multisig) |
| Owner | dre governance multisig (`Ownable`); only owner may call recovery functions |
| Automation | `checkUpkeep` → `true` when `token.balanceOf(this) > 0`; `performUpkeep` transfers entire balance to `forwardVault` |

`performUpkeep` is **permissionless** (any caller). That is acceptable because funds always go to the immutable `forwardVault`; early forwarding does not change the destination.

The configured `token` (e.g. USDC) can **only** leave the contract via `performUpkeep` to `forwardVault`, not via owner recovery.

---

## Owner recovery (governance only)

| Function | Purpose |
|----------|---------|
| `recoverToken(token, recipient)` | Sweep any ERC20 **except** the immutable `token` (e.g. mistaken USDT transfer) |
| `recoverEther(recipient)` | Sweep ETH sent by mistake (`receive()` accepts ETH for this path) |

Both functions are `onlyOwner`. Set `_owner` at deploy to the dre governance multisig.

---

## Deployment

### Constructor

```solidity
new dreVault(
    address token,         // USDC on the target chain
    address forwardVault,  // hop-2 dreVault or Utila corporate wallet
    address owner          // dre governance multisig
);
```

Revert `ZeroAddress()` if `token` or `forwardVault` is zero. `owner` must be non-zero (OpenZeppelin `Ownable`).

### Two-hop example

```solidity
address usdc = /* chain USDC */;
address governance = /* dre multisig */;

dreVault hop2 = new dreVault(usdc, utilaCorporateWallet, governance);
dreVault hop1 = new dreVault(usdc, address(hop2), governance);
```

### Single-hop example

```solidity
dreVault vault = new dreVault(usdc, utilaCorporateWallet, governance);
```

### Foundry script (two-hop)

`script/vault/DeployDreVaults.s.sol` deploys hop 2 first, then hop 1 with `forwardVault = address(hop2)`.

| Config field | Meaning |
|--------------|---------|
| `usdc` | ERC20 forwarded through the pipeline (Base Sepolia: `0x4BFf12Dec183b102E74275df6Bd07598b5650496`) |
| `vault2ForwardVault` | Hop 2 destination (Utila corporate wallet); Base Sepolia set in `Config.sol`, mainnet `address(0)` until configured |

Owner is `Config.defaultAdmin` for the chain. Requires `PRIVATE_KEY` in the environment.

```bash
forge script script/vault/DeployDreVaults.s.sol:DeployDreVaults \
  --rpc-url $RPC_URL \
  --broadcast
```

After deploy, set `dreUSDManager.updateVault(<hop1 address>)`.

---

## Wiring dreUSDManager

Mint flows send stablecoin to `custodianVault` (see `docs/FUND_FLOWS_AND_CUSTODY.md`).

1. Deploy hop 1 (and hop 2 if used).
2. Grant **MODERATOR_ROLE** on `dreUSDManager` to the ops multisig (if not already).
3. Call **`updateVault(address(hop1))`** so `custodianVault` is hop 1.

After this, every `mint()`, `mintFrom()`, and `mintAndStake()` that deposits USDC/USDT routes funds to hop 1 in the same transaction.

No change is required inside `dreVault` for inbound transfers; ERC20 `transfer` / `transferFrom` to the vault address is enough.

---

## Chainlink Automation

Register **one upkeep per `dreVault` instance**.

| Upkeep | Target contract | When it runs |
|--------|-----------------|--------------|
| Hop 1 | `address(hop1)` | After manager sends USDC to hop 1 |
| Hop 2 | `address(hop2)` | After hop 1 `performUpkeep` sends USDC to hop 2 |

### Suggested registration

- **Target contract:** the `dreVault` address for that hop.
- **Check data / perform data:** empty (`0x`); the contract ignores both.
- **Logic:** custom logic implementing `checkUpkeep` / `performUpkeep` on the vault (standard Automation-compatible consumer pattern).

`checkUpkeep` returns `upkeepNeeded = true` whenever the vault holds a non-zero token balance. Fund the upkeep with LINK (or the chain’s billing token) per Chainlink docs for your network.

### Operational order

1. User mints → USDC lands on hop 1.
2. Hop 1 upkeep runs → USDC moves to hop 2 (or Utila if single hop).
3. Hop 2 upkeep runs (if applicable) → USDC moves to Utila wallet.

If hop 1 runs before hop 2 has been deployed, ensure `forwardVault` was set correctly at construction; it cannot be changed later.

---

## Addresses checklist

| Role | Set where | Notes |
|------|-----------|--------|
| USDC token | `dreVault` constructor `_token` | Must match `dreUSDManager.usdc` for USDC mint path |
| Hop 1 vault | `dreUSDManager.updateVault` | `custodianVault` |
| Hop 2 vault | Hop 1 constructor `_forwardVault` | Immutable |
| Utila wallet | `Config.vault2ForwardVault` → hop 2 constructor `_forwardVault` | Immutable after deploy; set in `Config.sol` per chain |
| Governance multisig | Constructor `_owner` on each `dreVault` | `recoverToken` / `recoverEther` |
| Automation upkeeps | Chainlink UI / registrar | One per vault instance |

---

## Events and errors

| Name | When |
|------|------|
| `UsdcForwarded(to, amount)` | Successful `performUpkeep` |
| `TokenRecovered(token, recipient, amount)` | Successful `recoverToken` |
| `EtherRecovered(recipient, amount)` | Successful `recoverEther` |
| `ZeroAddress()` | Zero `token`, `forwardVault`, or recovery `recipient` |
| `NothingToForward()` | `performUpkeep` with zero balance |
| `ConfiguredTokenNotRecoverable()` | `recoverToken` called with immutable `token` |

---

## Related docs

- [FUND_FLOWS_AND_CUSTODY.md](./FUND_FLOWS_AND_CUSTODY.md) — where `custodianVault` fits in mint flows
- [DEPLOYMENT.md](./DEPLOYMENT.md) — system deploy and setup scripts
- [ROLES.md](./ROLES.md) — `MODERATOR_ROLE` for `updateVault`
