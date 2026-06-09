# Fiat Mint Reference Generation

This document describes how to generate the `mintRef` for the `mintFromUsd` function.

## Overview

The `mintRef` is a unique identifier for each fiat mint operation. It must be unique across all mints to prevent replay attacks. The contract will reject any mint request with a `mintRef` that has already been used.

## mintRef Generation

The `mintRef` should be generated as follows:

```javascript
mintRef = keccak256(
  abi.encodePacked(
    "DRE:FIAT_MINT:v1",            // domain tag to future-proof
    "|", custodianId,              // e.g., "ZEROCAP", "COINBASE", "CEFFU"
    "|", usdAccountId,             // the exact fiat account id
    "|", bankTxId,                 // wire/ACH reference from bank/custodian
    "|", timestamp,                // unix timestamp
    "|", amount,                   // usd amount as a string
    "|", nonceHex                  // 16 bytes hex, only if needed to disambiguate duplicates
  )
);
```

### Components

| Field | Description | Example |
|-------|-------------|---------|
| `domain tag` | Version prefix for future-proofing | `"DRE:FIAT_MINT:v1"` |
| `custodianId` | Identifier of the custodian | `"ZEROCAP"`, `"COINBASE"`, `"CEFFU"` |
| `usdAccountId` | The fiat account identifier | `"ACC-12345"` |
| `bankTxId` | Wire/ACH reference from bank | `"WIRE-2024-001234"` |
| `timestamp` | Unix timestamp of the deposit | `"1704067200"` |
| `amount` | USD amount as string | `"1000000.00"` |
| `nonceHex` | 16-byte hex nonce (optional) | `"a1b2c3d4e5f6g7h8"` |

### Example (JavaScript/TypeScript)

```typescript
import { ethers } from 'ethers';

function generateMintRef(
  custodianId: string,
  usdAccountId: string,
  bankTxId: string,
  timestamp: number,
  amount: string,
  nonce?: string
): string {
  const components = [
    "DRE:FIAT_MINT:v1",
    custodianId,
    usdAccountId,
    bankTxId,
    timestamp.toString(),
    amount,
  ];
  
  if (nonce) {
    components.push(nonce);
  }
  
  const packed = components.join("|");
  return ethers.keccak256(ethers.toUtf8Bytes(packed));
}

// Example usage
const mintRef = generateMintRef(
  "ZEROCAP",
  "ACC-12345",
  "WIRE-2024-001234",
  1704067200,
  "1000000.00"
);
```

## FiatMint Struct

```solidity
struct FiatMint {
    bytes32 mintRef;      // Unique reference generated as above
    address receiver;     // Address to mint dreUSD to
    uint256 usdAmount;    // USD amount in 2 decimals (e.g., 100000000 = $1,000,000.00)
    uint256 validUntil;   // Unix timestamp after which mint is invalid
    uint256 chainId;      // Chain ID to prevent cross-chain replay
}
```

**Note**: `usdAmount` uses 2 decimals (cents). For example:
- `100` = $1.00
- `100000000` = $1,000,000.00

A daily fiat mint cap (`dailyFiatMintCapUsd`) can be configured to limit total daily fiat mints. It is not set in `initialize` and defaults to 0 as a safety measure: **`mintFromUsd` and `mintRewards` are not callable until MODERATOR_ROLE calls `setDailyFiatMintCap(_cap)`**.

## Custodian Signature

The custodian must sign the following hash:

```solidity
bytes32 structHash = keccak256(abi.encode(
    mintRef,
    receiver,
    usdAmount,
    validUntil,
    chainId,
    contractAddress  // Address of the dreUSDManager contract instance
));
bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
```

**Important**: The `contractAddress` parameter binds the signature to a specific contract instance, preventing signature replay across different contract deployments on the same chain.

### Signing (JavaScript/TypeScript)

```typescript
import { ethers } from 'ethers';

async function signFiatMint(
  signer: ethers.Signer,
  mintRef: string,
  receiver: string,
  usdAmount: bigint,
  validUntil: number,
  chainId: number,
  contractAddress: string  // Address of the dreUSDManager contract instance
): Promise<string> {
  const structHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['bytes32', 'address', 'uint256', 'uint256', 'uint256', 'address'],
      [mintRef, receiver, usdAmount, validUntil, chainId, contractAddress]
    )
  );
  
  // Sign with EIP-191 prefix
  return await signer.signMessage(ethers.getBytes(structHash));
}
```

## Security Considerations

1. **Uniqueness**: Each `mintRef` MUST be unique. The contract maintains a mapping of used references.
2. **Expiration**: Set `validUntil` to a reasonable time window (e.g., 24-48 hours from creation).
3. **Chain ID**: Always include the correct `chainId` to prevent cross-chain replay attacks.
4. **Contract Address**: Always include the target contract address (`contractAddress`) to bind signatures to a specific contract instance and prevent replay across different deployments on the same chain.
5. **Custodian Key**: The custodian private key must be securely stored and rotated periodically.

## Flow

1. User initiates fiat deposit with custodian
2. Custodian verifies deposit and generates `FiatMint` struct
3. Custodian signs the struct hash
4. Keeper (backend service) calls `mintFromUsd(fiatMint, custodianSig)`
5. Contract verifies signature, checks `mintRef` uniqueness, and mints dreUSD

