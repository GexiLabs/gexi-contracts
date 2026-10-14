module gexi_economy::duels {
    use std::bcs;
    use std::string::String;
    use std::vector;
    use gexi_economy::rewards::RewardsAdminCap;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::coin_registry::{Self, Currency};
    use sui::clock::{Self, Clock};
    use sui::dynamic_field;
    use sui::ed25519;
    use sui::event;
    use sui::object::UID;
    use sui::vec_set::{Self, VecSet};

    const E_SIGNATURE_INVALID: u64 = 200;
    const E_VOUCHER_EXPIRED: u64 = 201;
    const E_NONCE_USED: u64 = 202;
    const E_STAKE_MIN: u64 = 203;
    const E_STAKE_MAX: u64 = 204;
    const E_AUTO_PAYOUT_ALREADY_PROCESSED: u64 = 205;
    const E_LEGACY_VOUCHER_DISABLED: u64 = 206;
    const E_CLAIM_ALREADY_PROCESSED: u64 = 207;
    const E_DUEL_ADMIN_CAP_CREATION_DISABLED: u64 = 208;
    const E_LEGACY_BURN_PATH_DISABLED: u64 = 209;
    const E_CLAIM_TYPE_INVALID: u64 = 211;
    const E_ADMIN_WITHDRAW_DISABLED: u64 = 212;
    const E_LEGACY_AUTO_PAYOUT_DISABLED: u64 = 213;
    const E_INVALID_LIMITS: u64 = 214;
    const E_LEGACY_VERIFIER_ROTATION_DISABLED: u64 = 215;
    const E_VERIFIER_KEY_INVALID: u64 = 216;
    const E_STAKE_ROLE_INVALID: u64 = 217;
    const E_STAKE_POSITION_ACTIVE: u64 = 218;
    const E_CREATOR_STAKE_REQUIRED: u64 = 219;
    const E_DUEL_ALREADY_CLOSED: u64 = 220;
    const E_REFUND_POSITION_MISMATCH: u64 = 221;
    const E_WINNER_POSITIONS_REQUIRED: u64 = 222;
    const E_WINNER_AMOUNT_MISMATCH: u64 = 223;
    const E_WINNER_RECIPIENT_INVALID: u64 = 224;
    const E_REFUNDED_USER_REJOIN: u64 = 225;
    const E_DUEL_CREATOR_EXITED: u64 = 226;
    const E_LEGACY_STAKE_DISABLED: u64 = 227;
    const E_SELF_DUEL_WALLET: u64 = 228;
    const E_DUEL_TIMEOUT_INVALID: u64 = 229;
    const E_DUEL_TIMEOUT_MISMATCH: u64 = 230;
    const E_DUEL_TIMEOUT_NOT_REACHED: u64 = 231;
    const E_DUEL_TIMEOUT_REQUIRED: u64 = 232;
    const E_DUEL_NO_ACTIVE_STAKE: u64 = 233;
    const E_DUEL_SETTLEMENT_WINDOW_CLOSED: u64 = 234;
    const E_SETTLEMENT_OPPONENT_MISMATCH: u64 = 235;
    const E_DUEL_DIRECT_FUNDING_DISABLED: u64 = 236;
    const E_TERMINAL_REFUND_ACTIVE: u64 = 237;
    const E_LEGACY_ADMIN_CAP_DISABLED: u64 = 238;
    const E_LEGACY_PAYOUT_CAP_DISABLED: u64 = 239;
    const E_ADMIN_CAP_CONFIG_MISMATCH: u64 = 240;
    const E_PAYOUT_CAP_CONFIG_MISMATCH: u64 = 241;
    const E_ADMIN_CAP_V2_ALREADY_MINTED: u64 = 242;
    const E_PAYOUT_CAP_V2_ALREADY_MINTED: u64 = 243;
    const E_DUEL_PAUSED: u64 = 0;
    const MAX_SAFE_ENTRY_MIST: u64 = 9_223_372_036_854_775_807;
    const MIN_DUEL_TIMEOUT_MS: u64 = 30 * 60 * 1000;
    const MAX_DUEL_TIMEOUT_MS: u64 = 72 * 60 * 60 * 1000;

    public struct DuelClaimKey has copy, drop, store {
        user: address,
        duel_id: String,
        claim_type: u8,
    }

    /// Dynamic-field key for scalable nonce replay protection. The legacy
    /// VecSet remains in DuelConfig for object-layout compatibility only.
    public struct DuelNonceKey has copy, drop, store {
        nonce_key: u64,
    }

    public struct DuelNonceDomainKey has copy, drop, store {
        domain: u8,
        nonce_key: u64,
    }

    public struct DuelStakeKey has copy, drop, store {
        duel_id: String,
        role: u8,
    }

    public struct DuelStakePosition has copy, drop, store {
        owner: address,
        amount_mist: u64,
    }

    public struct DuelClosedKey has copy, drop, store {
        duel_id: String,
    }

    public struct DuelCreatorExitedKey has copy, drop, store {
        duel_id: String,
    }

    public struct DuelTimeoutKey has copy, drop, store {
        duel_id: String,
    }

    /// Marks a duel as being in a terminal refund flow. Unlike a normal
    /// challenger exit/refund, this permanently prevents a replacement
    /// challenger from being admitted while the paired terminal refunds are
    /// being redeemed.
    public struct DuelTerminalRefundKey has copy, drop, store {
        duel_id: String,
    }

    public struct DuelAdminCapV2MintedKey has copy, drop, store {
        marker: u8,
    }

    public struct DuelPayoutCapV2MintedKey has copy, drop, store {
        marker: u8,
    }

    fun assert_unexpired(expiry_ms: u64, clock: &Clock) {
        assert!(expiry_ms > clock::timestamp_ms(clock), E_VOUCHER_EXPIRED);
    }

    fun assert_valid_claim_type(claim_type: u8) {
        assert!(
            claim_type == CLAIM_TYPE_WINNER_PAYOUT
                || claim_type == CLAIM_TYPE_REFUND
                || claim_type == CLAIM_TYPE_TERMINAL_REFUND,
            E_CLAIM_TYPE_INVALID,
        );
    }

    fun mark_nonce_used<T>(cfg: &mut DuelConfig<T>, nonce_key: u64) {
        // Preserve replay protection for nonces consumed by pre-upgrade code,
        // while ensuring the O(N) legacy VecSet never grows again.
        assert!(!vec_set::contains(&cfg.used_nonces, &nonce_key), E_NONCE_USED);
        let key = DuelNonceKey { nonce_key };
        assert!(
            !dynamic_field::exists_with_type<DuelNonceKey, bool>(&cfg.id, key),
            E_NONCE_USED,
        );
        dynamic_field::add(&mut cfg.id, key, true);
    }

    fun mark_nonce_used_domain<T>(cfg: &mut DuelConfig<T>, domain: u8, nonce_key: u64) {
        assert!(!vec_set::contains(&cfg.used_nonces, &nonce_key), E_NONCE_USED);
        assert!(
            !dynamic_field::exists_with_type<DuelNonceKey, bool>(
                &cfg.id,
                DuelNonceKey { nonce_key },
            ),
            E_NONCE_USED,
        );
        let key = DuelNonceDomainKey { domain, nonce_key };
        assert!(
            !dynamic_field::exists_with_type<DuelNonceDomainKey, bool>(&cfg.id, key),
            E_NONCE_USED,
        );
        dynamic_field::add(&mut cfg.id, key, true);
    }

    fun assert_valid_role(role: u8) {
        assert!(role == ROLE_CREATOR || role == ROLE_CHALLENGER, E_STAKE_ROLE_INVALID);
    }

    fun record_stake_position<T>(
        cfg: &mut DuelConfig<T>,
        duel_id: String,
        role: u8,
        owner: address,
        amount_mist: u64,
    ) {
        assert_valid_role(role);
        assert!(
            !dynamic_field::exists_with_type<DuelClosedKey, bool>(
                &cfg.id,
                DuelClosedKey { duel_id },
            ),
            E_DUEL_ALREADY_CLOSED,
        );
        assert!(
            !dynamic_field::exists_with_type<DuelCreatorExitedKey, bool>(
                &cfg.id,
                DuelCreatorExitedKey { duel_id },
            ),
            E_DUEL_CREATOR_EXITED,
        );
        if (role == ROLE_CHALLENGER) {
            assert!(
                !dynamic_field::exists_with_type<DuelTerminalRefundKey, bool>(
                    &cfg.id,
                    DuelTerminalRefundKey { duel_id },
                ),
                E_TERMINAL_REFUND_ACTIVE,
            );
            assert!(
                dynamic_field::exists_with_type<DuelStakeKey, DuelStakePosition>(
                    &cfg.id,
                    DuelStakeKey { duel_id, role: ROLE_CREATOR },
                ),
                E_CREATOR_STAKE_REQUIRED,
            );
            let creator = dynamic_field::borrow<DuelStakeKey, DuelStakePosition>(
                &cfg.id,
                DuelStakeKey { duel_id, role: ROLE_CREATOR },
            );
            assert!(creator.owner != owner, E_SELF_DUEL_WALLET);
            assert!(
                !dynamic_field::exists_with_type<DuelClaimKey, bool>(
                    &cfg.id,
                    DuelClaimKey { user: owner, duel_id, claim_type: CLAIM_TYPE_REFUND },
                ),
                E_REFUNDED_USER_REJOIN,
            );
        };
        let key = DuelStakeKey { duel_id, role };
        assert!(
            !dynamic_field::exists_with_type<DuelStakeKey, DuelStakePosition>(&cfg.id, key),
            E_STAKE_POSITION_ACTIVE,
        );
        dynamic_field::add(&mut cfg.id, key, DuelStakePosition { owner, amount_mist });
    }

    fun bind_duel_timeout<T>(
        cfg: &mut DuelConfig<T>,
        duel_id: String,
        role: u8,
        refund_after_ms: u64,
        clock: &Clock,
    ) {
        let now_ms = clock::timestamp_ms(clock);
        let key = DuelTimeoutKey { duel_id };
        if (role == ROLE_CREATOR) {
            assert!(
                refund_after_ms >= now_ms + MIN_DUEL_TIMEOUT_MS
                    && refund_after_ms <= now_ms + MAX_DUEL_TIMEOUT_MS,
                E_DUEL_TIMEOUT_INVALID,
            );
            assert!(
                !dynamic_field::exists_with_type<DuelTimeoutKey, u64>(&cfg.id, key),
                E_DUEL_TIMEOUT_MISMATCH,
            );
            dynamic_field::add(&mut cfg.id, key, refund_after_ms);
            return
        };

        assert!(
            dynamic_field::exists_with_type<DuelTimeoutKey, u64>(&cfg.id, key),
            E_DUEL_TIMEOUT_REQUIRED,
        );
        let bound = *dynamic_field::borrow<DuelTimeoutKey, u64>(&cfg.id, key);
        assert!(bound == refund_after_ms, E_DUEL_TIMEOUT_MISMATCH);
        assert!(now_ms < bound, E_DUEL_TIMEOUT_NOT_REACHED);
    }

    fun assert_duel_settlement_window_open<T>(cfg: &DuelConfig<T>, duel_id: String, clock: &Clock) {
        let key = DuelTimeoutKey { duel_id };
        if (dynamic_field::exists_with_type<DuelTimeoutKey, u64>(&cfg.id, key)) {
            let refund_after_ms = *dynamic_field::borrow<DuelTimeoutKey, u64>(&cfg.id, key);
            assert!(clock::timestamp_ms(clock) < refund_after_ms, E_DUEL_SETTLEMENT_WINDOW_CLOSED);
        };
    }

    fun consume_settlement_liability<T>(
        cfg: &mut DuelConfig<T>,
        duel_id: String,
        claim_type: u8,
        recipient: address,
        amount_mist: u64,
    ) {
        assert_valid_claim_type(claim_type);
        assert!(
            !dynamic_field::exists_with_type<DuelClosedKey, bool>(
                &cfg.id,
                DuelClosedKey { duel_id },
            ),
            E_DUEL_ALREADY_CLOSED,
        );

        let creator_key = DuelStakeKey { duel_id, role: ROLE_CREATOR };
        let challenger_key = DuelStakeKey { duel_id, role: ROLE_CHALLENGER };
        let has_creator = dynamic_field::exists_with_type<DuelStakeKey, DuelStakePosition>(&cfg.id, creator_key);
        let has_challenger = dynamic_field::exists_with_type<DuelStakeKey, DuelStakePosition>(&cfg.id, challenger_key);

        if (claim_type == CLAIM_TYPE_WINNER_PAYOUT) {
            assert!(has_creator && has_challenger, E_WINNER_POSITIONS_REQUIRED);
            let creator = *dynamic_field::borrow<DuelStakeKey, DuelStakePosition>(&cfg.id, creator_key);
            let challenger = *dynamic_field::borrow<DuelStakeKey, DuelStakePosition>(&cfg.id, challenger_key);
            assert!(creator.amount_mist + challenger.amount_mist == amount_mist, E_WINNER_AMOUNT_MISMATCH);
            assert!(
                recipient == creator.owner || recipient == challenger.owner,
                E_WINNER_RECIPIENT_INVALID,
            );
            dynamic_field::remove<DuelStakeKey, DuelStakePosition>(&mut cfg.id, creator_key);
            dynamic_field::remove<DuelStakeKey, DuelStakePosition>(&mut cfg.id, challenger_key);
            dynamic_field::add(&mut cfg.id, DuelClosedKey { duel_id }, true);
            return
        };

        if (claim_type == CLAIM_TYPE_TERMINAL_REFUND) {
            let terminal_key = DuelTerminalRefundKey { duel_id };
            if (!dynamic_field::exists_with_type<DuelTerminalRefundKey, bool>(&cfg.id, terminal_key)) {
                dynamic_field::add(&mut cfg.id, terminal_key, true);
            };
        };

        let creator_matches = if (has_creator) {
            let position = dynamic_field::borrow<DuelStakeKey, DuelStakePosition>(&cfg.id, creator_key);
            position.owner == recipient && position.amount_mist == amount_mist
        } else {
            false
        };
        let challenger_matches = if (has_challenger) {
            let position = dynamic_field::borrow<DuelStakeKey, DuelStakePosition>(&cfg.id, challenger_key);
            position.owner == recipient && position.amount_mist == amount_mist
        } else {
            false
        };
        assert!(creator_matches != challenger_matches, E_REFUND_POSITION_MISMATCH);
        if (creator_matches) {
            dynamic_field::remove<DuelStakeKey, DuelStakePosition>(&mut cfg.id, creator_key);
            dynamic_field::add(&mut cfg.id, DuelCreatorExitedKey { duel_id }, true);
        } else {
            dynamic_field::remove<DuelStakeKey, DuelStakePosition>(&mut cfg.id, challenger_key);
        };
        let creator_remaining = dynamic_field::exists_with_type<DuelStakeKey, DuelStakePosition>(&cfg.id, creator_key);
        let challenger_remaining = dynamic_field::exists_with_type<DuelStakeKey, DuelStakePosition>(&cfg.id, challenger_key);
        if (!creator_remaining && !challenger_remaining) {
            dynamic_field::add(&mut cfg.id, DuelClosedKey { duel_id }, true);
            let timeout_key = DuelTimeoutKey { duel_id };
            if (dynamic_field::exists_with_type<DuelTimeoutKey, u64>(&cfg.id, timeout_key)) {
                dynamic_field::remove<DuelTimeoutKey, u64>(&mut cfg.id, timeout_key);
            };
        };
    }

    /// Bind a settlement authorization to the opposing wallet from the match
    /// state that produced it. Refunds allow that opponent position to have
    /// disappeared already (the other participant may have refunded first),
    /// but if another position is currently active it must be the signed one.
    fun assert_settlement_opponent<T>(
        cfg: &DuelConfig<T>,
        duel_id: String,
        recipient: address,
        expected_opponent: address,
        require_opponent: bool,
    ) {
        let creator_key = DuelStakeKey { duel_id, role: ROLE_CREATOR };
        let challenger_key = DuelStakeKey { duel_id, role: ROLE_CHALLENGER };
        let has_creator = dynamic_field::exists_with_type<DuelStakeKey, DuelStakePosition>(&cfg.id, creator_key);
        let has_challenger = dynamic_field::exists_with_type<DuelStakeKey, DuelStakePosition>(&cfg.id, challenger_key);
        if (require_opponent) {
            assert!(has_creator && has_challenger, E_WINNER_POSITIONS_REQUIRED);
        };

        if (has_creator) {
            let creator = dynamic_field::borrow<DuelStakeKey, DuelStakePosition>(&cfg.id, creator_key);
            if (recipient == creator.owner) {
                if (has_challenger) {
                    let challenger = dynamic_field::borrow<DuelStakeKey, DuelStakePosition>(&cfg.id, challenger_key);
                    assert!(expected_opponent == challenger.owner, E_SETTLEMENT_OPPONENT_MISMATCH);
                };
                return
            };
        };
        if (has_challenger) {
            let challenger = dynamic_field::borrow<DuelStakeKey, DuelStakePosition>(&cfg.id, challenger_key);
            if (recipient == challenger.owner) {
                if (has_creator) {
                    let creator = dynamic_field::borrow<DuelStakeKey, DuelStakePosition>(&cfg.id, creator_key);
                    assert!(expected_opponent == creator.owner, E_SETTLEMENT_OPPONENT_MISMATCH);
                };
                return
            };
        };
        if (require_opponent) {
            abort E_WINNER_RECIPIENT_INVALID
        } else {
            abort E_REFUND_POSITION_MISMATCH
        }
    }

    fun mark_entitlement_paid<T>(
        cfg: &mut DuelConfig<T>,
        user: address,
        duel_id: String,
        claim_type: u8,
    ) {
        let claim_key = DuelClaimKey { user, duel_id, claim_type };
        assert!(
            !dynamic_field::exists_with_type<DuelClaimKey, bool>(&cfg.id, claim_key),
            E_CLAIM_ALREADY_PROCESSED,
        );
        dynamic_field::add(&mut cfg.id, claim_key, true);
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun claim_duel_payout_v3<T>(
        cfg: &mut DuelConfig<T>,
        duel_id: String,
        claim_type: u8,
        amount_mist: u64,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Kept only for compatibility with the previously published API.
        // New deployments must use v4 so winner commission is destroyed through the
        // burn-only Currency object rather than transferred to an address.
        abort E_LEGACY_BURN_PATH_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun claim_duel_payout_v4<T>(
        cfg: &mut DuelConfig<T>,
        currency: &mut Currency<T>,
        duel_id: String,
        claim_type: u8,
        amount_mist: u64,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Retained for package-upgrade ABI compatibility. V5 binds winner
        // authorization to the currently staked opponent.
        abort E_LEGACY_VOUCHER_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun claim_duel_payout_v5<T>(
        cfg: &mut DuelConfig<T>,
        currency: &mut Currency<T>,
        duel_id: String,
        claim_type: u8,
        amount_mist: u64,
        opponent: address,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        abort E_LEGACY_VOUCHER_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun claim_duel_payout_v6<T>(
        cfg: &mut DuelConfig<T>,
        currency: &mut Currency<T>,
        duel_id: String,
        claim_type: u8,
        amount_mist: u64,
        opponent: address,
        developer_revenue_recipient: address,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        abort E_LEGACY_VOUCHER_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun claim_duel_payout_v7<T>(
        cfg: &mut DuelConfig<T>,
        currency: &mut Currency<T>,
        duel_id: String,
        claim_type: u8,
        amount_mist: u64,
        opponent: address,
        developer_revenue_recipient: address,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_not_paused(cfg);
        assert_unexpired(expiry_ms, clock);
        assert_valid_claim_type(claim_type);
        assert_duel_settlement_window_open(cfg, duel_id, clock);
        let user = tx_context::sender(ctx);
        let mut message = b"GEXI_DUEL_V7";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&user));
        vector::append(&mut message, bcs::to_bytes(&duel_id));
        vector::append(&mut message, bcs::to_bytes(&claim_type));
        vector::append(&mut message, bcs::to_bytes(&amount_mist));
        vector::append(&mut message, bcs::to_bytes(&opponent));
        vector::append(&mut message, bcs::to_bytes(&developer_revenue_recipient));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(&signature, &cfg.verifier_pubkey, &message), E_SIGNATURE_INVALID);
        assert_settlement_opponent(cfg, duel_id, user, opponent, claim_type == CLAIM_TYPE_WINNER_PAYOUT);
        consume_settlement_liability(cfg, duel_id, claim_type, user, amount_mist);
        mark_entitlement_paid(cfg, user, duel_id, claim_type);
        mark_nonce_used_domain(cfg, 2, nonce_key);

        let (payout_amount, developer_amount, burn_amount) = competitive_split(amount_mist, claim_type);
        let out = coin::from_balance(balance::split(&mut cfg.vault, payout_amount), ctx);
        transfer::public_transfer(out, user);
        if (developer_amount > 0) {
            let developer_coin = coin::from_balance(balance::split(&mut cfg.vault, developer_amount), ctx);
            transfer::public_transfer(developer_coin, developer_revenue_recipient);
        };
        if (burn_amount > 0) {
            let burn_coin = coin::from_balance(balance::split(&mut cfg.vault, burn_amount), ctx);
            coin_registry::burn(currency, burn_coin);
        };

        event::emit(DuelPayoutClaimed { user, duel_id, amount_mist: payout_amount, nonce_key, claim_type });
        event::emit(DuelPayoutClaimedV2 {
            config_id: object::id_address(cfg),
            user,
            duel_id,
            amount_mist: payout_amount,
            nonce_key,
            claim_type,
        });
        event::emit(DuelCommissionSplit {
            config_id: object::id_address(cfg),
            user,
            duel_id,
            gross_amount_mist: amount_mist,
            payout_amount_mist: payout_amount,
            developer_share_mist: developer_amount,
            burn_mist: burn_amount,
            developer_revenue_recipient,
            claim_type,
        });
    }

    #[test]
    fun current_clock_accepts_unexpired() {
        let mut ctx = tx_context::dummy();
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 1000);
        assert_unexpired(1001, &clock);
        clock::destroy_for_testing(clock);
    }

    #[test]
    #[expected_failure(abort_code = E_VOUCHER_EXPIRED)]
    fun expiry_boundary_is_closed() {
        let mut ctx = tx_context::dummy();
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 1000);
        assert_unexpired(1000, &clock);
        clock::destroy_for_testing(clock);
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_VOUCHER_DISABLED)]
    fun legacy_v2_cannot_bypass_clock() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        claim_duel_payout_v2(&mut cfg, std::string::utf8(b"fixture"), 1, 0, 0, 0, vector[], &mut ctx);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_VOUCHER_EXPIRED)]
    fun current_clock_rejects_expired_in_same_epoch() {
        let mut ctx = tx_context::dummy();
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 1001);
        assert_unexpired(1000, &clock);
        clock::destroy_for_testing(clock);
    }
    const CLAIM_TYPE_WINNER_PAYOUT: u8 = 1;
    const CLAIM_TYPE_REFUND: u8 = 2;
    const CLAIM_TYPE_TERMINAL_REFUND: u8 = 3;
    const ROLE_CREATOR: u8 = 0;
    const ROLE_CHALLENGER: u8 = 1;
    public struct DuelAdminCap has key, store {
        id: UID,
    }

    public struct DuelAdminCapV2 has key, store {
        id: UID,
        config_id: address,
    }

    /// Separate settlement authority. Configuration administration alone
    /// cannot move vault assets through the automatic payout path.
    public struct DuelPayoutCap has key, store {
        id: UID,
    }

    public struct DuelPayoutCapV2 has key, store {
        id: UID,
        config_id: address,
    }

    public struct DUELS has drop {}

    public struct DuelConfig<phantom T> has key {
        id: UID,
        vault: Balance<T>,
        verifier_pubkey: vector<u8>,
        used_nonces: VecSet<u64>,
        paused: bool,
        min_entry_mist: u64,
        max_entry_mist: u64,
    }

    public struct DuelStakeLocked has copy, drop {
        user: address,
        duel_id: String,
        amount_mist: u64,
        role: u8,
    }

    /// Canonical-config-bound stake evidence for current application flows.
    public struct DuelStakeLockedV2 has copy, drop {
        config_id: address,
        user: address,
        duel_id: String,
        amount_mist: u64,
        role: u8,
        refund_after_ms: u64,
    }

    public struct DuelPayoutClaimed has copy, drop {
        user: address,
        duel_id: String,
        amount_mist: u64,
        nonce_key: u64,
        claim_type: u8,
    }

    public struct DuelPayoutClaimedV2 has copy, drop {
        config_id: address,
        user: address,
        duel_id: String,
        amount_mist: u64,
        nonce_key: u64,
        claim_type: u8,
    }

    /// Current competitive settlement economics. Winner payouts always keep
    /// 90% of the gross pot, 2% is transferred to the developer revenue
    /// recipient and the remaining 8% is irreversibly burned. Refunds carry
    /// no commission and therefore emit zero developer/burn shares.
    public struct DuelCommissionSplit has copy, drop {
        config_id: address,
        user: address,
        duel_id: String,
        gross_amount_mist: u64,
        payout_amount_mist: u64,
        developer_share_mist: u64,
        burn_mist: u64,
        developer_revenue_recipient: address,
        claim_type: u8,
    }

    public struct DuelAutoPaid has copy, drop {
        user: address,
        duel_id: String,
        payout_id: String,
        amount_mist: u64,
        claim_type: u8,
    }

    public struct DuelAutoPaidV2 has copy, drop {
        config_id: address,
        user: address,
        duel_id: String,
        payout_id: String,
        amount_mist: u64,
        claim_type: u8,
    }

    public struct DuelTimeoutRefunded has copy, drop {
        config_id: address,
        duel_id: String,
        total_refund_mist: u64,
        creator_refunded: bool,
        challenger_refunded: bool,
    }

    fun burn_commission(total_amount: u64, claim_type: u8): (u64, u64) {
        assert_valid_claim_type(claim_type);
        if (claim_type != CLAIM_TYPE_WINNER_PAYOUT) return (total_amount, 0);
        let burn_amount = total_amount / 10;
        (total_amount - burn_amount, burn_amount)
    }

    fun competitive_split(total_amount: u64, claim_type: u8): (u64, u64, u64) {
        assert_valid_claim_type(claim_type);
        if (claim_type != CLAIM_TYPE_WINNER_PAYOUT) return (total_amount, 0, 0);
        let commission_amount = total_amount / 10;
        let developer_amount = commission_amount / 5;
        let burn_amount = commission_amount - developer_amount;
        let payout_amount = total_amount - commission_amount;
        (payout_amount, developer_amount, burn_amount)
    }

    #[test]
    fun competitive_winner_split_is_90_2_8() {
        let (payout_amount, developer_amount, burn_amount) = competitive_split(1_000, CLAIM_TYPE_WINNER_PAYOUT);
        assert!(payout_amount == 900, 910);
        assert!(developer_amount == 20, 911);
        assert!(burn_amount == 80, 912);
    }

    #[test]
    fun non_winner_claim_has_no_commission_split() {
        let (payout_amount, developer_amount, burn_amount) = competitive_split(1_000, CLAIM_TYPE_REFUND);
        assert!(payout_amount == 1_000, 913);
        assert!(developer_amount == 0, 914);
        assert!(burn_amount == 0, 915);
    }

    fun assert_not_paused<T>(cfg: &DuelConfig<T>) {
        assert!(!cfg.paused, E_DUEL_PAUSED);
    }

    fun assert_admin_cap_v2_binding<T>(cap: &DuelAdminCapV2, cfg: &DuelConfig<T>) {
        assert!(cap.config_id == object::id_address(cfg), E_ADMIN_CAP_CONFIG_MISMATCH);
    }

    fun assert_payout_cap_v2_binding<T>(cap: &DuelPayoutCapV2, cfg: &DuelConfig<T>) {
        assert!(cap.config_id == object::id_address(cfg), E_PAYOUT_CAP_CONFIG_MISMATCH);
    }

    fun init(_witness: DUELS, ctx: &mut TxContext) {
        let admin_cap = DuelAdminCap { id: object::new(ctx) };
        let payout_cap = DuelPayoutCap { id: object::new(ctx) };
        let sender = tx_context::sender(ctx);
        transfer::transfer(admin_cap, sender);
        transfer::transfer(payout_cap, sender);
    }

    #[test_only]
    public fun duel_admin_cap_for_testing(ctx: &mut TxContext): DuelAdminCap {
        DuelAdminCap { id: object::new(ctx) }
    }

    #[test_only]
    public fun destroy_duel_admin_cap_for_testing(cap: DuelAdminCap) {
        let DuelAdminCap { id } = cap;
        id.delete();
    }

    #[test_only]
    public fun duel_payout_cap_for_testing(ctx: &mut TxContext): DuelPayoutCap {
        DuelPayoutCap { id: object::new(ctx) }
    }

    #[test_only]
    public fun destroy_duel_payout_cap_for_testing(cap: DuelPayoutCap) {
        let DuelPayoutCap { id } = cap;
        id.delete();
    }

    #[test_only]
    public fun duel_admin_cap_v2_for_testing<T>(cfg: &DuelConfig<T>, ctx: &mut TxContext): DuelAdminCapV2 {
        DuelAdminCapV2 { id: object::new(ctx), config_id: object::id_address(cfg) }
    }

    #[test_only]
    public fun destroy_duel_admin_cap_v2_for_testing(cap: DuelAdminCapV2) {
        let DuelAdminCapV2 { id, config_id: _ } = cap;
        id.delete();
    }

    #[test_only]
    public fun duel_payout_cap_v2_for_testing<T>(cfg: &DuelConfig<T>, ctx: &mut TxContext): DuelPayoutCapV2 {
        DuelPayoutCapV2 { id: object::new(ctx), config_id: object::id_address(cfg) }
    }

    #[test_only]
    public fun destroy_duel_payout_cap_v2_for_testing(cap: DuelPayoutCapV2) {
        let DuelPayoutCapV2 { id, config_id: _ } = cap;
        id.delete();
    }

    #[test]
    fun init_bootstraps_separate_duel_caps() {
        let deployer = @0xA11CE;
        let mut scenario = sui::test_scenario::begin(deployer);
        init(DUELS {}, scenario.ctx());
        scenario.next_tx(deployer);
        let admin_cap = scenario.take_from_sender<DuelAdminCap>();
        let payout_cap = scenario.take_from_sender<DuelPayoutCap>();
        scenario.return_to_sender(admin_cap);
        scenario.return_to_sender(payout_cap);
        scenario.end();
    }

    #[test]
    #[allow(lint(abort_without_constant))]
    fun nonce_marker_does_not_grow_legacy_vecset() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        mark_nonce_used(&mut cfg, 42);
        assert!(vec_set::length(&cfg.used_nonces) == 0, 999);
        assert!(
            dynamic_field::exists_with_type<DuelNonceKey, bool>(
                &cfg.id,
                DuelNonceKey { nonce_key: 42 },
            ),
            998,
        );
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_NONCE_USED)]
    fun nonce_replay_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        mark_nonce_used(&mut cfg, 7);
        mark_nonce_used(&mut cfg, 7);
        transfer::share_object(cfg);
    }

    #[test]
    fun nonce_domains_allow_same_numeric_nonce() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        mark_nonce_used_domain(&mut cfg, 1, 77);
        mark_nonce_used_domain(&mut cfg, 2, 77);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_NONCE_USED)]
    fun nonce_replay_is_rejected_within_domain() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        mark_nonce_used_domain(&mut cfg, 2, 77);
        mark_nonce_used_domain(&mut cfg, 2, 77);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_NONCE_USED)]
    fun legacy_vecset_nonce_remains_rejected_after_upgrade() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::singleton(9), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        mark_nonce_used(&mut cfg, 9);
        transfer::share_object(cfg);
    }

    #[test]
    #[allow(lint(abort_without_constant))]
    fun challenger_refund_then_new_challenger_then_winner_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-reopen");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x2, 100);
        mark_entitlement_paid(&mut cfg, @0x2, duel_id, CLAIM_TYPE_REFUND);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x3, 100);
        assert_settlement_opponent(&cfg, duel_id, @0x3, @0x1, true);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_WINNER_PAYOUT, @0x3, 200);
        mark_entitlement_paid(&mut cfg, @0x3, duel_id, CLAIM_TYPE_WINNER_PAYOUT);
        assert!(
            dynamic_field::exists_with_type<DuelClosedKey, bool>(
                &cfg.id,
                DuelClosedKey { duel_id },
            ),
            997,
        );
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_TERMINAL_REFUND_ACTIVE)]
    fun terminal_refund_blocks_replacement_challenger() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-terminal-refund");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_TERMINAL_REFUND, @0x2, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x3, 100);
        transfer::share_object(cfg);
    }

    #[test]
    fun terminal_refund_allows_second_original_participant_refund() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-terminal-pair");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_TERMINAL_REFUND, @0x2, 100);
        assert_settlement_opponent(&cfg, duel_id, @0x1, @0x2, false);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_TERMINAL_REFUND, @0x1, 100);
        assert!(
            dynamic_field::exists_with_type<DuelClosedKey, bool>(
                &cfg.id,
                DuelClosedKey { duel_id },
            ),
            996,
        );
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_SETTLEMENT_OPPONENT_MISMATCH)]
    fun stale_winner_opponent_is_rejected_after_challenger_replacement() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-stale-opponent");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x2, 100);
        mark_entitlement_paid(&mut cfg, @0x2, duel_id, CLAIM_TYPE_REFUND);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x3, 100);
        // This models the old A/B winner authorization after B has exited and
        // C has taken the challenger position. The patched settlement rejects
        // it before either current stake position can be consumed.
        assert_settlement_opponent(&cfg, duel_id, @0x1, @0x2, true);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_SETTLEMENT_OPPONENT_MISMATCH)]
    fun stale_creator_refund_is_rejected_after_challenger_replacement() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-stale-refund");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x2, 100);
        mark_entitlement_paid(&mut cfg, @0x2, duel_id, CLAIM_TYPE_REFUND);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x3, 100);
        // A refund authorization issued while B was the challenger must not be
        // reusable once C owns that live position.
        assert_settlement_opponent(&cfg, duel_id, @0x1, @0x2, false);
        transfer::share_object(cfg);
    }

    #[test]
    fun second_refund_accepts_snapshot_of_already_exited_opponent() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-refund-pair");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        // Both refund authorizations were issued for the same A/B state.
        assert_settlement_opponent(&cfg, duel_id, @0x1, @0x2, false);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x1, 100);
        assert_settlement_opponent(&cfg, duel_id, @0x2, @0x1, false);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x2, 100);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_REFUND_POSITION_MISMATCH)]
    fun duplicate_refund_is_rejected_after_position_consumed() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-refund-once");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x2, 100);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_REFUND_POSITION_MISMATCH)]
    fun refund_wrong_amount_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-refund-amount");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x2, 99);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_REFUND_POSITION_MISMATCH)]
    fun refund_wrong_recipient_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-refund-user");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x9, 100);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_WINNER_POSITIONS_REQUIRED)]
    fun winner_without_two_active_stakes_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-one-stake");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_WINNER_PAYOUT, @0x1, 200);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_WINNER_AMOUNT_MISMATCH)]
    fun winner_gross_amount_must_equal_active_stakes() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-winner-amount");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_WINNER_PAYOUT, @0x1, 199);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_WINNER_RECIPIENT_INVALID)]
    fun winner_must_be_an_active_participant() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-winner-user");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_WINNER_PAYOUT, @0x9, 200);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_DUEL_ALREADY_CLOSED)]
    fun refund_after_winner_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-winner-then-refund");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_WINNER_PAYOUT, @0x1, 200);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x2, 100);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_WINNER_POSITIONS_REQUIRED)]
    fun winner_after_creator_refund_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-creator-refund");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x1, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_WINNER_PAYOUT, @0x2, 200);
        transfer::share_object(cfg);
    }

    #[test]
    fun both_participants_can_refund_terminal_duel() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-both-refund");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x1, 100);
        mark_entitlement_paid(&mut cfg, @0x1, duel_id, CLAIM_TYPE_REFUND);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x2, 100);
        mark_entitlement_paid(&mut cfg, @0x2, duel_id, CLAIM_TYPE_REFUND);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_REFUNDED_USER_REJOIN)]
    fun refunded_challenger_cannot_rejoin_same_duel() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-no-rejoin");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        consume_settlement_liability(&mut cfg, duel_id, CLAIM_TYPE_REFUND, @0x2, 100);
        mark_entitlement_paid(&mut cfg, @0x2, duel_id, CLAIM_TYPE_REFUND);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_SELF_DUEL_WALLET)]
    fun same_wallet_cannot_hold_both_duel_roles() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-self-wallet");
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x1, 100);
        transfer::share_object(cfg);
    }

    #[test]
    fun expired_duel_refunds_active_stakes_without_verifier() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: true,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-timeout-refund");
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 1_000);
        let refund_after_ms = 1_000 + MIN_DUEL_TIMEOUT_MS;
        bind_duel_timeout(&mut cfg, duel_id, ROLE_CREATOR, refund_after_ms, &clock);
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        record_stake_position(&mut cfg, duel_id, ROLE_CHALLENGER, @0x2, 100);
        balance::join(&mut cfg.vault, coin::into_balance(coin::mint_for_testing<u8>(200, &mut ctx)));
        clock::set_for_testing(&mut clock, refund_after_ms);
        refund_expired_duel(&mut cfg, duel_id, &clock, &mut ctx);
        assert!(balance::value(&cfg.vault) == 0, E_DUEL_TIMEOUT_MISMATCH);
        assert!(
            dynamic_field::exists_with_type<DuelClosedKey, bool>(
                &cfg.id,
                DuelClosedKey { duel_id },
            ),
            E_DUEL_TIMEOUT_MISMATCH,
        );
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_DUEL_TIMEOUT_NOT_REACHED)]
    fun timeout_refund_cannot_run_early() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-timeout-early");
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 1_000);
        let refund_after_ms = 1_000 + MIN_DUEL_TIMEOUT_MS;
        bind_duel_timeout(&mut cfg, duel_id, ROLE_CREATOR, refund_after_ms, &clock);
        record_stake_position(&mut cfg, duel_id, ROLE_CREATOR, @0x1, 100);
        balance::join(&mut cfg.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        clock::set_for_testing(&mut clock, refund_after_ms - 1);
        refund_expired_duel(&mut cfg, duel_id, &clock, &mut ctx);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_DUEL_SETTLEMENT_WINDOW_CLOSED)]
    fun signed_duel_settlement_closes_at_timeout_deadline() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-timeout-boundary");
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 1_000);
        let refund_after_ms = 1_000 + MIN_DUEL_TIMEOUT_MS;
        bind_duel_timeout(&mut cfg, duel_id, ROLE_CREATOR, refund_after_ms, &clock);
        clock::set_for_testing(&mut clock, refund_after_ms);
        assert_duel_settlement_window_open(&cfg, duel_id, &clock);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_CLAIM_ALREADY_PROCESSED)]
    fun same_entitlement_cannot_be_paid_twice() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        let duel_id = std::string::utf8(b"duel-entitlement");
        mark_entitlement_paid(&mut cfg, @0x1, duel_id, CLAIM_TYPE_WINNER_PAYOUT);
        mark_entitlement_paid(&mut cfg, @0x1, duel_id, CLAIM_TYPE_WINNER_PAYOUT);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_CLAIM_TYPE_INVALID)]
    fun unknown_claim_type_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        consume_settlement_liability(
            &mut cfg,
            std::string::utf8(b"duel-invalid"),
            255,
            @0x1,
            100,
        );
        transfer::share_object(cfg);
    }
    #[allow(lint(public_entry))]
    public entry fun create_duels<T>(
        _: &DuelAdminCap,
        verifier_pubkey: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(vector::length(&verifier_pubkey) == 32, E_VERIFIER_KEY_INVALID);
        let cfg = DuelConfig<T> {
            id: object::new(ctx),
            vault: balance::zero<T>(),
            verifier_pubkey,
            used_nonces: vec_set::empty<u64>(),
            paused: false,
            min_entry_mist: 20_000_000_000,
            max_entry_mist: 1_000_000_000_000,
        };
        transfer::share_object(cfg);
    }

    #[allow(lint(public_entry))]
    public entry fun create_duel_admin_cap(
        _: &RewardsAdminCap,
        _ctx: &mut TxContext,
    ) {
        // Retained only for package upgrade compatibility. Allowing a
        // RewardsAdminCap to mint fresh DuelAdminCaps couples two otherwise
        // separate authority domains and lets a reward-admin compromise
        // escalate into duel administration.
        abort E_DUEL_ADMIN_CAP_CREATION_DISABLED
    }

    #[test]
    #[expected_failure(abort_code = E_DUEL_ADMIN_CAP_CREATION_DISABLED)]
    fun reward_admin_cannot_create_duel_admin_cap() {
        let mut ctx = tx_context::dummy();
        let reward_admin = gexi_economy::rewards::rewards_admin_cap_for_testing(&mut ctx);
        create_duel_admin_cap(&reward_admin, &mut ctx);
        gexi_economy::rewards::destroy_rewards_admin_cap_for_testing(reward_admin);
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun lock_stake<T>(
        cfg: &mut DuelConfig<T>,
        payment: Coin<T>,
        duel_id: String,
        role: u8,
        ctx: &mut TxContext,
    ) {
        // Retained for compatibility with the previously published ABI.
        // New deployments must authenticate stake-position creation with v2.
        abort E_LEGACY_STAKE_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun lock_stake_v2<T>(
        cfg: &mut DuelConfig<T>,
        payment: Coin<T>,
        duel_id: String,
        role: u8,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Retained for package-upgrade ABI compatibility. Current stake locking
        // uses v3 so every duel has an on-chain timeout escape hatch.
        abort E_LEGACY_STAKE_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun lock_stake_v3<T>(
        cfg: &mut DuelConfig<T>,
        payment: Coin<T>,
        duel_id: String,
        role: u8,
        refund_after_ms: u64,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_not_paused(cfg);
        assert_unexpired(expiry_ms, clock);
        assert_valid_role(role);
        let paid = coin::value(&payment);
        assert!(paid >= cfg.min_entry_mist, E_STAKE_MIN);
        assert!(paid <= cfg.max_entry_mist, E_STAKE_MAX);
        let user = tx_context::sender(ctx);
        let mut message = b"GEXI_DUEL_STAKE_V3";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&user));
        vector::append(&mut message, bcs::to_bytes(&duel_id));
        vector::append(&mut message, bcs::to_bytes(&role));
        vector::append(&mut message, bcs::to_bytes(&paid));
        vector::append(&mut message, bcs::to_bytes(&refund_after_ms));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(
            ed25519::ed25519_verify(&signature, &cfg.verifier_pubkey, &message),
            E_SIGNATURE_INVALID,
        );
        mark_nonce_used_domain(cfg, 1, nonce_key);
        bind_duel_timeout(cfg, duel_id, role, refund_after_ms, clock);
        record_stake_position(cfg, duel_id, role, user, paid);

        balance::join(&mut cfg.vault, coin::into_balance(payment));

        event::emit(DuelStakeLocked {
            user,
            duel_id,
            amount_mist: paid,
            role,
        });
        event::emit(DuelStakeLockedV2 {
            config_id: object::id_address(cfg),
            user,
            duel_id,
            amount_mist: paid,
            role,
            refund_after_ms,
        });
    }

    /// Permissionless timeout safety valve. It remains available while paused
    /// and never needs the verifier or a payout/admin capability.
    #[allow(lint(public_entry))]
    public entry fun refund_expired_duel<T>(
        cfg: &mut DuelConfig<T>,
        duel_id: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(
            !dynamic_field::exists_with_type<DuelClosedKey, bool>(
                &cfg.id,
                DuelClosedKey { duel_id },
            ),
            E_DUEL_ALREADY_CLOSED,
        );
        let timeout_key = DuelTimeoutKey { duel_id };
        assert!(
            dynamic_field::exists_with_type<DuelTimeoutKey, u64>(&cfg.id, timeout_key),
            E_DUEL_TIMEOUT_REQUIRED,
        );
        let refund_after_ms = *dynamic_field::borrow<DuelTimeoutKey, u64>(&cfg.id, timeout_key);
        assert!(clock::timestamp_ms(clock) >= refund_after_ms, E_DUEL_TIMEOUT_NOT_REACHED);

        let creator_key = DuelStakeKey { duel_id, role: ROLE_CREATOR };
        let challenger_key = DuelStakeKey { duel_id, role: ROLE_CHALLENGER };
        let has_creator = dynamic_field::exists_with_type<DuelStakeKey, DuelStakePosition>(&cfg.id, creator_key);
        let has_challenger = dynamic_field::exists_with_type<DuelStakeKey, DuelStakePosition>(&cfg.id, challenger_key);
        assert!(has_creator || has_challenger, E_DUEL_NO_ACTIVE_STAKE);

        let mut total_refund_mist = 0;
        if (has_creator) {
            let creator = dynamic_field::remove<DuelStakeKey, DuelStakePosition>(&mut cfg.id, creator_key);
            total_refund_mist = total_refund_mist + creator.amount_mist;
            let refund = coin::from_balance(balance::split(&mut cfg.vault, creator.amount_mist), ctx);
            transfer::public_transfer(refund, creator.owner);
        };
        if (has_challenger) {
            let challenger = dynamic_field::remove<DuelStakeKey, DuelStakePosition>(&mut cfg.id, challenger_key);
            total_refund_mist = total_refund_mist + challenger.amount_mist;
            let refund = coin::from_balance(balance::split(&mut cfg.vault, challenger.amount_mist), ctx);
            transfer::public_transfer(refund, challenger.owner);
        };

        dynamic_field::remove<DuelTimeoutKey, u64>(&mut cfg.id, timeout_key);
        dynamic_field::add(&mut cfg.id, DuelClosedKey { duel_id }, true);
        event::emit(DuelTimeoutRefunded {
            config_id: object::id_address(cfg),
            duel_id,
            total_refund_mist,
            creator_refunded: has_creator,
            challenger_refunded: has_challenger,
        });
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun fund_vault<T>(cfg: &mut DuelConfig<T>, coins: Coin<T>) {
        // Duel custody is liability-backed. Every coin entering the vault must
        // be paired with a stake position created by lock_stake_v3; arbitrary
        // top-ups have no safe owner/refund semantics and can become stranded.
        // Keep this entry point only for published-ABI compatibility.
        abort E_DUEL_DIRECT_FUNDING_DISABLED
    }

    #[test]
    #[expected_failure(abort_code = E_DUEL_DIRECT_FUNDING_DISABLED)]
    fun direct_duel_vault_funding_is_disabled() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        let payment = coin::mint_for_testing<u8>(50, &mut ctx);
        fund_vault(&mut cfg, payment);
        transfer::share_object(cfg);
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun claim_duel_payout<T>(
        cfg: &mut DuelConfig<T>,
        duel_id: String,
        claim_type: u8,
        amount_mist: u64,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        ctx: &mut TxContext,
    ) {
        // Kept only for upgrade compatibility; current claims use v4.
        abort E_LEGACY_VOUCHER_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun claim_duel_payout_v2<T>(
        cfg: &mut DuelConfig<T>,
        duel_id: String,
        claim_type: u8,
        amount_mist: u64,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        ctx: &mut TxContext,
    ) {
        // Kept only for upgrade compatibility; current claims use v4.
        abort E_LEGACY_VOUCHER_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun mint_duel_admin_cap_v2<T>(
        _: &DuelAdminCap,
        cfg: &mut DuelConfig<T>,
        ctx: &mut TxContext,
    ) {
        let marker = DuelAdminCapV2MintedKey { marker: 1 };
        assert!(
            !dynamic_field::exists_with_type<DuelAdminCapV2MintedKey, bool>(&cfg.id, marker),
            E_ADMIN_CAP_V2_ALREADY_MINTED,
        );
        dynamic_field::add(&mut cfg.id, marker, true);
        transfer::transfer(
            DuelAdminCapV2 {
                id: object::new(ctx),
                config_id: object::id_address(cfg),
            },
            tx_context::sender(ctx),
        );
    }

    #[allow(lint(public_entry))]
    public entry fun mint_duel_payout_cap_v2<T>(
        _: &DuelPayoutCap,
        cfg: &mut DuelConfig<T>,
        ctx: &mut TxContext,
    ) {
        let marker = DuelPayoutCapV2MintedKey { marker: 1 };
        assert!(
            !dynamic_field::exists_with_type<DuelPayoutCapV2MintedKey, bool>(&cfg.id, marker),
            E_PAYOUT_CAP_V2_ALREADY_MINTED,
        );
        dynamic_field::add(&mut cfg.id, marker, true);
        transfer::transfer(
            DuelPayoutCapV2 {
                id: object::new(ctx),
                config_id: object::id_address(cfg),
            },
            tx_context::sender(ctx),
        );
    }

    public entry fun retire_duel_admin_cap(cap: DuelAdminCap) {
        let DuelAdminCap { id } = cap;
        id.delete();
    }

    public entry fun retire_duel_payout_cap(cap: DuelPayoutCap) {
        let DuelPayoutCap { id } = cap;
        id.delete();
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun set_paused<T>(_: &DuelAdminCap, cfg: &mut DuelConfig<T>, paused: bool) {
        abort E_LEGACY_ADMIN_CAP_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun set_limits<T>(_: &DuelAdminCap, cfg: &mut DuelConfig<T>, min_entry_mist: u64, max_entry_mist: u64) {
        abort E_LEGACY_ADMIN_CAP_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun set_paused_v2<T>(cap: &DuelAdminCapV2, cfg: &mut DuelConfig<T>, paused: bool) {
        assert_admin_cap_v2_binding(cap, cfg);
        cfg.paused = paused;
    }

    #[allow(lint(public_entry))]
    public entry fun set_limits_v2<T>(
        cap: &DuelAdminCapV2,
        cfg: &mut DuelConfig<T>,
        min_entry_mist: u64,
        max_entry_mist: u64,
    ) {
        assert_admin_cap_v2_binding(cap, cfg);
        // Two simultaneously active stakes must always be addable without u64 overflow.
        assert!(
            min_entry_mist > 0
                && min_entry_mist <= max_entry_mist
                && max_entry_mist <= MAX_SAFE_ENTRY_MIST,
            E_INVALID_LIMITS,
        );
        cfg.min_entry_mist = min_entry_mist;
        cfg.max_entry_mist = max_entry_mist;
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_LIMITS)]
    fun invalid_limits_are_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        let admin = duel_admin_cap_v2_for_testing(&cfg, &mut ctx);
        set_limits_v2(&admin, &mut cfg, 1000, 20);
        transfer::share_object(cfg);
        destroy_duel_admin_cap_v2_for_testing(admin);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_LIMITS)]
    fun zero_minimum_stake_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        let admin = duel_admin_cap_v2_for_testing(&cfg, &mut ctx);
        set_limits_v2(&admin, &mut cfg, 0, 1000);
        transfer::share_object(cfg);
        destroy_duel_admin_cap_v2_for_testing(admin);
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_ADMIN_CAP_DISABLED)]
    fun legacy_admin_cap_cannot_pause_config() {
        let mut ctx = tx_context::dummy();
        let admin = DuelAdminCap { id: object::new(&mut ctx) };
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        set_paused(&admin, &mut cfg, true);
        transfer::share_object(cfg);
        destroy_duel_admin_cap_for_testing(admin);
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_ADMIN_CAP_DISABLED)]
    fun legacy_admin_cap_cannot_change_limits() {
        let mut ctx = tx_context::dummy();
        let admin = DuelAdminCap { id: object::new(&mut ctx) };
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        set_limits(&admin, &mut cfg, 20, 500);
        transfer::share_object(cfg);
        destroy_duel_admin_cap_for_testing(admin);
    }

    #[test]
    fun bound_admin_cap_controls_own_config() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        let admin = duel_admin_cap_v2_for_testing(&cfg, &mut ctx);
        set_paused_v2(&admin, &mut cfg, true);
        assert!(cfg.paused, 995);
        set_limits_v2(&admin, &mut cfg, 25, 500);
        assert!(cfg.min_entry_mist == 25 && cfg.max_entry_mist == 500, 994);
        transfer::share_object(cfg);
        destroy_duel_admin_cap_v2_for_testing(admin);
    }

    #[test]
    fun legacy_caps_can_be_retired() {
        let mut ctx = tx_context::dummy();
        let admin = DuelAdminCap { id: object::new(&mut ctx) };
        let payout = DuelPayoutCap { id: object::new(&mut ctx) };
        retire_duel_admin_cap(admin);
        retire_duel_payout_cap(payout);
    }

    #[test]
    #[expected_failure(abort_code = E_ADMIN_CAP_CONFIG_MISMATCH)]
    fun bound_admin_cap_cannot_control_another_config() {
        let mut ctx = tx_context::dummy();
        let cfg_a = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        let admin = duel_admin_cap_v2_for_testing(&cfg_a, &mut ctx);
        let mut cfg_b = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        set_paused_v2(&admin, &mut cfg_b, true);
        transfer::share_object(cfg_a);
        transfer::share_object(cfg_b);
        destroy_duel_admin_cap_v2_for_testing(admin);
    }

    #[test]
    #[expected_failure(abort_code = E_ADMIN_CAP_V2_ALREADY_MINTED)]
    fun admin_cap_v2_mints_once_per_config() {
        let mut ctx = tx_context::dummy();
        let legacy = DuelAdminCap { id: object::new(&mut ctx) };
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        mint_duel_admin_cap_v2(&legacy, &mut cfg, &mut ctx);
        mint_duel_admin_cap_v2(&legacy, &mut cfg, &mut ctx);
        transfer::share_object(cfg);
        destroy_duel_admin_cap_for_testing(legacy);
    }

    #[test]
    #[expected_failure(abort_code = E_PAYOUT_CAP_V2_ALREADY_MINTED)]
    fun payout_cap_v2_mints_once_per_config() {
        let mut ctx = tx_context::dummy();
        let legacy = DuelPayoutCap { id: object::new(&mut ctx) };
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        mint_duel_payout_cap_v2(&legacy, &mut cfg, &mut ctx);
        mint_duel_payout_cap_v2(&legacy, &mut cfg, &mut ctx);
        transfer::share_object(cfg);
        destroy_duel_payout_cap_for_testing(legacy);
    }

    #[test]
    #[expected_failure(abort_code = E_PAYOUT_CAP_CONFIG_MISMATCH)]
    fun bound_payout_cap_cannot_control_another_config() {
        let mut ctx = tx_context::dummy();
        let cfg_a = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        let cap = duel_payout_cap_v2_for_testing(&cfg_a, &mut ctx);
        let cfg_b = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        assert_payout_cap_v2_binding(&cap, &cfg_b);
        transfer::share_object(cfg_a);
        transfer::share_object(cfg_b);
        destroy_duel_payout_cap_v2_for_testing(cap);
    }

    #[test]
    fun payout_nonce_domain_three_isolated_from_claim_nonce() {
        let mut ctx = tx_context::dummy();
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        mark_nonce_used_domain(&mut cfg, 2, 91);
        mark_nonce_used_domain(&mut cfg, 3, 91);
        transfer::share_object(cfg);
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun set_verifier<T>(
        _: &DuelAdminCap,
        cfg: &mut DuelConfig<T>,
        verifier_pubkey: vector<u8>,
    ) {
        // The verifier is immutable after config creation. Rotation requires a
        // reviewed package/governance change rather than hot admin authority.
        abort E_LEGACY_VERIFIER_ROTATION_DISABLED
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_VERIFIER_ROTATION_DISABLED)]
    fun duel_admin_alone_cannot_rotate_verifier() {
        let mut ctx = tx_context::dummy();
        let admin = DuelAdminCap { id: object::new(&mut ctx) };
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 20, max_entry_mist: 1000,
        };
        set_verifier(&admin, &mut cfg, vector[]);
        transfer::share_object(cfg);
        destroy_duel_admin_cap_for_testing(admin);
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_withdraw<T>(
        _: &DuelAdminCap,
        cfg: &mut DuelConfig<T>,
        amount: u64,
        to: address,
        ctx: &mut TxContext,
    ) {
        // Stakes in this vault are player liabilities. The contract cannot
        // safely distinguish arbitrary "surplus" from unsettled stake without
        // migrating all historical liabilities, so retain the ABI and disable
        // direct custody withdrawal. Settlement/burn paths remain available.
        abort E_ADMIN_WITHDRAW_DISABLED
    }

    #[test]
    #[expected_failure(abort_code = E_ADMIN_WITHDRAW_DISABLED)]
    fun duel_admin_cannot_withdraw_stake_backing() {
        let mut ctx = tx_context::dummy();
        let admin = DuelAdminCap { id: object::new(&mut ctx) };
        let mut cfg = DuelConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
            min_entry_mist: 0, max_entry_mist: 1000,
        };
        admin_withdraw(&admin, &mut cfg, 0, @0x1, &mut ctx);
        transfer::share_object(cfg);
        destroy_duel_admin_cap_for_testing(admin);
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_auto_payout<T>(
        _: &DuelAdminCap,
        cfg: &mut DuelConfig<T>,
        payout_id: String,
        duel_id: String,
        claim_type: u8,
        amount: u64,
        to: address,
        ctx: &mut TxContext,
    ) {
        abort E_LEGACY_BURN_PATH_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_auto_payout_burn<T>(
        _: &DuelAdminCap,
        cfg: &mut DuelConfig<T>,
        payout_id: String,
        duel_id: String,
        claim_type: u8,
        amount: u64,
        to: address,
        treasury: &mut TreasuryCap<T>,
        ctx: &mut TxContext,
    ) {
        abort E_LEGACY_AUTO_PAYOUT_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_auto_payout_burn_v2<T>(
        _: &DuelAdminCap,
        cfg: &mut DuelConfig<T>,
        payout_id: String,
        duel_id: String,
        claim_type: u8,
        amount: u64,
        to: address,
        currency: &mut Currency<T>,
        ctx: &mut TxContext,
    ) {
        abort E_LEGACY_AUTO_PAYOUT_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_auto_payout_burn_v3<T>(
        _: &DuelPayoutCap,
        cfg: &mut DuelConfig<T>,
        payout_id: String,
        duel_id: String,
        claim_type: u8,
        amount: u64,
        to: address,
        currency: &mut Currency<T>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Retained for package-upgrade ABI compatibility. V4 binds winner
        // authorization to the currently staked opponent.
        abort E_LEGACY_AUTO_PAYOUT_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun admin_auto_payout_burn_v4<T>(
        _: &DuelPayoutCap,
        cfg: &mut DuelConfig<T>,
        payout_id: String,
        duel_id: String,
        claim_type: u8,
        amount: u64,
        to: address,
        opponent: address,
        currency: &mut Currency<T>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        abort E_LEGACY_AUTO_PAYOUT_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_auto_payout_burn_v5<T>(
        _: &DuelPayoutCap,
        cfg: &mut DuelConfig<T>,
        payout_id: String,
        duel_id: String,
        claim_type: u8,
        amount: u64,
        to: address,
        opponent: address,
        developer_revenue_recipient: address,
        currency: &mut Currency<T>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        abort E_LEGACY_PAYOUT_CAP_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun admin_auto_payout_burn_v6<T>(
        cap: &DuelPayoutCapV2,
        cfg: &mut DuelConfig<T>,
        payout_id: String,
        duel_id: String,
        claim_type: u8,
        amount: u64,
        to: address,
        opponent: address,
        developer_revenue_recipient: address,
        currency: &mut Currency<T>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_payout_cap_v2_binding(cap, cfg);
        assert_not_paused(cfg);
        assert_unexpired(expiry_ms, clock);
        assert_valid_claim_type(claim_type);
        assert_duel_settlement_window_open(cfg, duel_id, clock);
        let mut message = b"GEXI_DUEL_AUTO_V4";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&payout_id));
        vector::append(&mut message, bcs::to_bytes(&duel_id));
        vector::append(&mut message, bcs::to_bytes(&claim_type));
        vector::append(&mut message, bcs::to_bytes(&amount));
        vector::append(&mut message, bcs::to_bytes(&to));
        vector::append(&mut message, bcs::to_bytes(&opponent));
        vector::append(&mut message, bcs::to_bytes(&developer_revenue_recipient));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(
            ed25519::ed25519_verify(&signature, &cfg.verifier_pubkey, &message),
            E_SIGNATURE_INVALID,
        );
        assert_settlement_opponent(cfg, duel_id, to, opponent, claim_type == CLAIM_TYPE_WINNER_PAYOUT);
        consume_settlement_liability(cfg, duel_id, claim_type, to, amount);
        assert!(
            !dynamic_field::exists_with_type<String, bool>(&cfg.id, payout_id),
            E_AUTO_PAYOUT_ALREADY_PROCESSED
        );

        dynamic_field::add(&mut cfg.id, payout_id, true);
        mark_entitlement_paid(cfg, to, duel_id, claim_type);
        mark_nonce_used_domain(cfg, 3, nonce_key);

        let (payout_amount, developer_amount, burn_amount) = competitive_split(amount, claim_type);
        let out = coin::from_balance(balance::split(&mut cfg.vault, payout_amount), ctx);
        transfer::public_transfer(out, to);
        if (developer_amount > 0) {
            let developer_coin = coin::from_balance(balance::split(&mut cfg.vault, developer_amount), ctx);
            transfer::public_transfer(developer_coin, developer_revenue_recipient);
        };
        if (burn_amount > 0) {
            let burn_coin = coin::from_balance(balance::split(&mut cfg.vault, burn_amount), ctx);
            coin_registry::burn(currency, burn_coin);
        };

        event::emit(DuelAutoPaid {
            user: to,
            duel_id,
            payout_id,
            amount_mist: payout_amount,
            claim_type,
        });
        event::emit(DuelAutoPaidV2 {
            config_id: object::id_address(cfg),
            user: to,
            duel_id,
            payout_id,
            amount_mist: payout_amount,
            claim_type,
        });
        event::emit(DuelCommissionSplit {
            config_id: object::id_address(cfg),
            user: to,
            duel_id,
            gross_amount_mist: amount,
            payout_amount_mist: payout_amount,
            developer_share_mist: developer_amount,
            burn_mist: burn_amount,
            developer_revenue_recipient,
            claim_type,
        });
    }
}
