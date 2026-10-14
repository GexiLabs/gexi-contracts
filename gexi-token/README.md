# GEXI Token

GEXI is the utility token designed for the GEXI gaming ecosystem on Sui. This directory makes the source code of the **proposed mainnet token** publicly available for transparency and technical review.

GEXI currently operates on **Sui Testnet**. The mainnet token package is part of the planned launch and is not yet deployed.

## Token overview

| Property | Specification |
| --- | --- |
| Name | Gexi |
| Symbol | GEXI |
| Blockchain | Sui |
| Decimals | 9 |
| Initial supply | 100,000,000 GEXI |
| Supply policy | Burn-only after initial creation |

## Token design

The Move package uses Sui's `coin_registry` framework to create the token. Its initial creation mints **100 million GEXI** to the publishing account and permanently removes the authority to mint additional tokens. Token metadata is finalized as part of this process.

The token package defines the asset and its supply controls. Allocation custody, token distribution, and vesting are separate parts of the planned mainnet launch and are not implemented by this package.

## Source code and verification

The independently buildable Move package includes [`sources/gexi.move`](sources/gexi.move), [`Move.toml`](Move.toml), and [`Move.lock`](Move.lock). Developers can verify its behavior using the [Sui CLI](https://docs.sui.io/guides/developer/getting-started/get-sui):

```bash
sui move test --path gexi-token
```

The Store, Rewards, Duel, and Brawl economy modules are maintained separately at the [repository root](../). The current published economy contracts belong to Sui Testnet; a mainnet deployment will use the new mainnet GEXI token type.

For the broader platform and proposed token distribution, see the [GEXI Whitepaper](https://gexi.io/whitepaper).
