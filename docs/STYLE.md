# Code style

## Contract naming (intentional)

First-party contracts in this repo use **lower camelCase** names with the `dre` prefix (e.g. `dreUSDManager`, `dreWithdrawalNFT`, `dreUSDOracle`). This is intentional and not an oversight.

- **Convention:** Contract type names start with `dre` followed by CapWords-style suffix (e.g. `dreUSD`, `dreRewardsDistributor`).
- **Rationale:** Brand consistency and a clear distinction from third-party or library contracts.
- **Linting:** This diverges from the typical Solidity CapWords convention for contract names. If you use solhint or other tooling that enforces contract-name casing, disable or relax the contract-name rule (e.g. `contract-name-camelcase` / `contract-name-capwords`) for this project, or add a targeted suppression. Foundry’s built-in linter is configured in `foundry.toml`; see the `[lint]` section and `mixed_case_exceptions` if relevant.

Do not “fix” these names to CapWords (e.g. `DreUSDManager`) without an explicit decision to change the project convention.
