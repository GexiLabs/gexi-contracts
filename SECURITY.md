# Security

Please report security vulnerabilities privately through GitHub Security Advisories rather than opening a public issue.

Private keys, signing secrets, mnemonics, deployment credentials and environment files must never be committed to this repository.

## Trust and upgrade invariants

- The off-chain verifier is a critical security boundary. Production verifier keys must be held in hardened custody (HSM/KMS or threshold/MPC), with signing audit logs and least-privilege access. A verifier compromise can authorize an incorrect competitive result even though the Move package still enforces participant, amount, replay, escrow and timeout invariants.
- Security-sensitive authorization semantics must never be changed behind an existing signature domain. Introduce a new entry-point/signature domain (for example the Duel V7/V4 domains) or pause issuance and wait for every old authorization to expire before activating changed semantics.
- Canonical config object IDs must be pinned by the application. Clients and indexers must not trust arbitrary objects discovered only by struct type.
- Config-bound V2 administration/payout capabilities must be minted once for the canonical configs, then the legacy module-global migration/root capabilities must be retired on-chain.
- Package upgrades must be controlled by multisig/MPC governance rather than a single hot key. Do not make the package immutable unless governance explicitly approves that irreversible action.
