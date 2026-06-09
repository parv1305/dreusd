# Bridge Compliance and Quarantine Policy

This document describes how sanctions and freeze interact with cross-chain (LayerZero OFT) routing, and how quarantined balances are handled.

## Bridge routing and recipient fields

Destination is determined by path:

- **Standard OFT send**: The outer `SendParam.to` is the destination recipient. The OFT burns on source and credits that address on destination via `_credit(to, amountLD, srcEid)`.
- **Compose send**: The outer `SendParam.to` is the compose receiver (e.g. hub composer contract). The final beneficiary is the inner recipient encoded in `SendParam.composeMsg`, decoded and used in `handleCompose` / `lzCompose`. So the address that actually receives tokens in a compose flow is the one derived from `composeMsg`, not the outer `to`.

In both cases the **destination address is not pre-validated for sanctions or freeze before cross-chain credit**. The OFT layer does not check the recipient against a sanctions list or freeze state before calling `_credit`. This is by design so that messages are not left in limbo (see below).

## Why destination is not validated before credit

Our OFT implementations (`dreUSD`, `dreShareOFT`) override `_credit` to mint (or, on the hub for shares, transfer) **without** running the usual address validation (`_validateAddress`). Reasons:

1. **Avoid stranded messages**: If we reverted `_credit` when the recipient is frozen/sanctioned, the LayerZero message would fail on destination. The source chain has already burned the tokens. That would strand value in the protocol/message layer with no clean way to refund or redirect without additional infrastructure.
2. **Consistent delivery**: We always complete the credit on destination so that the message is consumed and the system state is consistent. Any compliance enforcement then applies to **what the recipient can do with the balance** (transfer, bridge again, etc.), not to whether they receive the balance.


## Quarantine policy

We keep the current delivery behavior and explicitly document it:

1. **Credit is not conditional on sanctions/freeze.** Destination `_credit` mints (or credits) to the recipient without address validation so that messages are not stranded.
2. **Blocked recipients may still receive a balance** on a chain where they are credited (standard or compose path). That balance is **quarantined**: the token contract still enforces sanctions/freeze in `_update`, so any transfer or send from that address reverts. The tokens are effectively locked in that account until compliance state changes or a protocol-defined recovery mechanism exists.
3. **Compose path:** The same applies when the real beneficiary is the inner recipient from `composeMsg`. That address is not validated before credit; if it is blocked on the destination chain, the credited balance is quarantined there.

No change to the current smart contract behavior is required by this policy; it only formalizes and documents it.

## Handling procedures for quarantined balances

### dreUSD (and other mint-based OFTs)

- **Where it happens:** Any chain where dreUSD uses `_credit` that mints via `ERC20Upgradeable._update(address(0), _to, _amountLD)` and skips `_validateAddress`. The recipient can be the outer `SendParam.to` (standard) or the inner compose recipient decoded in `handleCompose`.
- **Quarantine:** Balance sits on an address that is frozen or sanctioned on that chain. All transfers and OFT sends from that address revert.
- **Procedures:**
  - **Unfreeze / delist:** If the address is later unfrozen or removed from the sanctions list on that chain, the user can transfer and use the balance normally.
  - **No in-contract recovery:** dreUSD does not expose a function to sweep or redirect quarantined balances. If such a recovery mechanism is added later (e.g. guardian-initiated move to a designated address), it will be documented here and in the contract NatSpec.
  - **Operational:** Operators should monitor for quarantined balances (e.g. balances on known frozen/sanctioned addresses) and handle according to internal policy (legal/compliance); the contract does not auto-redirect.

### dreShareOFT (spoke share OFT)

- **Where it happens:** On spoke chains, share OFT `_credit` mints to the destination address without validation. Standard and compose flows can credit a blocked address.
- **Quarantine:** Same as dreUSD: balance on a frozen/sanctioned address cannot be transferred or sent.
- **Procedures:** Same as dreUSD: rely on unfreeze/delist for the address to regain use; no current in-contract sweep of quarantined shares; operational handling per internal policy.

### dreShareOFTAdapter (hub share OFT adapter)

- **Where it happens:** On the hub, the share OFT is an **adapter** (lockbox). The adapter’s `_credit` does **not** mint; it transfers from the adapter’s balance to the recipient. It **tries** the transfer and, if it fails (e.g. recipient frozen/sanctioned or vault reverts), sends the tokens to `stuckFundsRecipient` instead.
- **Quarantine:** There is no quarantine on the hub for this path. Tokens go to `stuckFundsRecipient` instead of being locked in the adapter.
- **Procedures:**
  1. Set `stuckFundsRecipient` to a multisig or safe (not an EOA) so recovery is governed.
  2. Monitor `StuckFundsRecovered(to, amountLD, srcEid)`: `to` is the intended recipient that was blocked; the tokens have been sent to `stuckFundsRecipient`. Use off-chain records (e.g. source tx, compose payload) to associate the transfer with the original sender and intended receiver.
  3. Handle per policy, for example: return to the source-chain sender; or hold and send to the intended receiver (`to`) once that address is unfrozen or removed from the sanctions list.

### dreOVaultComposer (compose refund path)

- When refund to the original sender fails (e.g. sender is frozen/sanctioned), tokens and any native value are sent to the composer’s `stuckFundsRecipient`. No quarantine on the composer; procedures are as for the adapter’s stuck funds.

