# Sanctions List Oracle

This project integrates with the **Chainalysis Sanctions Oracle** to comply with OFAC sanctions requirements. The oracle provides an on-chain list of sanctioned addresses that should be blocked from interacting with the protocol.

## Contract Addresses

The Chainalysis Sanctions List Oracle is deployed at the following addresses:

| Network          | Address                                      |
| ---------------- | -------------------------------------------- |
| Ethereum         | `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` |
| Polygon          | `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` |
| BNB Smart Chain  | `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` |
| Avalanche        | `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` |
| Optimism         | `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` |
| Arbitrum         | `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` |
| Fantom           | `0x40c57923924b5c5c5455c48d93317139addac8fb` |
| Celo             | `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` |
| Blast            | `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` |
| Base             | `0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B` |

## Usage

The `ISanctionsList` interface is used to check if an address is sanctioned:

```solidity
interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}
```

Before processing transactions, the protocol checks addresses against this oracle to ensure compliance with OFAC sanctions.

## Bridge and compose routing

Destination addresses for cross-chain sends (standard OFT or compose) are not pre-validated before credit. Blocked recipients can still be credited; their balance is then quarantined (transfers/sends revert). See **[BRIDGE_COMPLIANCE.md](./BRIDGE_COMPLIANCE.md)** for routing details, quarantine policy, and handling procedures for quarantined balances.

## References

- [Chainalysis Sanctions Oracle Documentation](https://developers.chainalysis.com/sanctions-screening/oracle/chainalysis-oracle/introduction#compatible-networks)

