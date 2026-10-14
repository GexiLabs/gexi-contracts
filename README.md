# GEXI Economy Contracts

GEXI is an arcade gaming platform. This repository contains the Sui Move contracts for its on-chain economy. The web application, game clients, scoring/verifier services, and signing infrastructure are maintained separately.

## GEXI Token

The [`gexi-token/`](gexi-token/) directory contains the independently buildable Sui Move source for the **proposed mainnet GEXI token**. It defines an initial supply of **100,000,000 GEXI**, **9 decimals**, and a **burn-only supply policy** after token creation.

The GEXI platform currently operates on **Sui Testnet**; the mainnet token has not yet been deployed. Token allocation, vesting, and distribution require separate launch arrangements. See the [GEXI Token overview](gexi-token/README.md) and [GEXI Whitepaper](https://gexi.io/whitepaper) for further details.

## Modules

| Move source | Scope |
| --- | --- |
| `sources/store.move` | Store payment accounting and configuration-bound event-funding routes |
| `sources/rewards.move` | Rewards vault, authorizations, claims, payouts, and recovery |
| `sources/duels.move` | Two-player escrow, settlement evidence, refunds, and timeouts |
| `sources/brawls.move` | Multiplayer escrow, settlement, cancellation, and timeout refunds |

## Build and test

Install the [Sui CLI](https://docs.sui.io/guides/developer/getting-started/get-sui) with a compatible toolchain, then run:

```bash
sui move build
sui move test
sui move test --path gexi-token
```

The package manifest is `Move.toml`. `Move.lock` records the resolved dependencies, while `Published.toml` contains publication metadata for verifying deployed package source. To check a published package against the local source, configure the corresponding Sui network and toolchain, then run:

```bash
sui client verify-source .
```

Source verification compares the local build with the package recorded in `Published.toml`; it does not publish or upgrade a package. For more information, see the [Sui source-verification documentation](https://docs.sui.io/develop/manage-packages/source-verification).

## Contract architecture

- Administrative and payout operations use configuration-bound capabilities. Legacy global capabilities remain for explicit migration and retirement paths.
- Duel authorizations bind participant roles, amounts, the canonical configuration, and the refund deadline. Settlement enforces on-chain replay and timeout conditions.
- Rewards and Store operations use configuration-bound capabilities and canonical configuration IDs. Emergency Rewards recovery requires a paused vault and a delay.
- Brawl settlement, cancellation, and timeout handling use distinct authorization paths.
- Store purchase events and payment accounting are on-chain. Application entitlements, such as tickets, are fulfilled and reconciled by the application layer.
- Brawl factory initialization becomes one-time after its `BrawlFactoryCap` is destroyed; configuration creation alone does not consume that capability.
- Competitive scoring, off-chain verification, and signing keys are outside this repository. Integrations must enforce canonical configuration IDs and manage package upgrade capabilities appropriately.

Please consult the Move source for the complete behavior of each entry point and [`SECURITY.md`](SECURITY.md) for vulnerability reporting and operational security requirements.

## License

The source code and documentation are licensed under the **[Apache License, Version 2.0](LICENSE)**. GEXI names, logos, and trademarks are not separately licensed under this grant. The software is provided **AS IS**, without warranty.
