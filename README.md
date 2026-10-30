# GEXI Smart Contracts

Public Sui Move smart contract source for the GEXI gaming ecosystem. This repository contains on-chain contracts only; application code, game clients, AI Studio and off-chain verification infrastructure are not included.

## Published package — Sui Testnet

| Field | Published information |
| --- | --- |
| Network | **Sui Testnet** |
| Package | `gexi_economy` |
| Published version | **8** |
| Package ID | [`0xc458c6b3f66aa0fb7899c909e6905240da4ef15d7c4a9da5d8d230a7941e81d3`](https://suiscan.xyz/testnet/object/0xc458c6b3f66aa0fb7899c909e6905240da4ef15d7c4a9da5d8d230a7941e81d3) |
| Publish transaction | [SuiScan](https://suiscan.xyz/testnet/tx/C2AiXNkqCihz2UzSiADznLH7SG1LpPmFXnhFy3obPMCf) |
| Published | October 30, 2026 |
| Toolchain | Sui CLI `1.82.1` |
| Source verification | [`Published.toml`](Published.toml) |

The package has been published and source-verified on **testnet**. Publication does not itself activate application integrations, treasury administration, or mainnet functionality.

## Source code

| File | Scope |
| --- | --- |
| [`sources/store.move`](sources/store.move) | Store payments and accounting |
| [`sources/rewards.move`](sources/rewards.move) | Reward vault and claims |
| [`sources/duels.move`](sources/duels.move) | Two-player escrow and settlement |
| [`sources/brawls.move`](sources/brawls.move) | Multiplayer escrow and settlement |
| [`gexi-token/`](gexi-token/) | Separately buildable, proposed mainnet token source; **not deployed to mainnet** |

## Build and verify

Use the published Sui toolchain and a testnet environment:

```bash
sui client switch --env testnet
sui move build
sui move test
sui client verify-source .
```

These commands build, test and verify; they do not publish or upgrade contracts. Source verification and unit tests are not an independent security audit.

## Security and license

Report vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md). The source is licensed under [Apache License 2.0](LICENSE), subject to [NOTICE](NOTICE). The license does not grant separate rights to GEXI trademarks.
