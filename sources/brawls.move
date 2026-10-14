module gexi_economy::brawls {
    use std::bcs;
    use std::string::String;
    use std::vector;
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::coin_registry::{Self, Currency};
    use sui::dynamic_field;
    use sui::ed25519;
    use sui::event;
    use sui::object::UID;

    const E_SIGNATURE_INVALID: u64 = 300;
    const E_AUTH_EXPIRED: u64 = 301;
    const E_BRAWLS_PAUSED: u64 = 302;
    const E_VERIFIER_KEY_INVALID: u64 = 303;
    const E_INVALID_LIMITS: u64 = 304;
    const E_INVALID_BRAWL_ID: u64 = 305;
    const E_BRAWL_ID_ALREADY_USED: u64 = 306;
    const E_ENTRY_FEE_INVALID: u64 = 307;
    const E_PARTICIPANT_LIMITS_INVALID: u64 = 308;
    const E_END_TIME_INVALID: u64 = 309;
    const E_CONFIG_MISMATCH: u64 = 310;
    const E_BRAWL_SETTLED: u64 = 311;
    const E_BRAWL_ENDED: u64 = 312;
    const E_BRAWL_FULL: u64 = 313;
    const E_ALREADY_JOINED: u64 = 314;
    const E_NONCE_USED: u64 = 315;
    const E_NOT_ENOUGH_PARTICIPANTS: u64 = 316;
    const E_WINNER_INVALID: u64 = 317;
    const E_DRAW_WINNERS_INVALID: u64 = 318;
    const E_DRAW_WINNER_DUPLICATE: u64 = 319;
    const E_VAULT_LIABILITY_MISMATCH: u64 = 320;
    const E_TIMEOUT_NOT_REACHED: u64 = 321;
    const E_ADMIN_WITHDRAW_DISABLED: u64 = 322;
    const E_VERIFIER_ROTATION_DISABLED: u64 = 323;
    const E_PARTICIPANT_COUNT_MISMATCH: u64 = 324;
    const E_SETTLEMENT_TOO_EARLY: u64 = 325;
    const E_RESULT_COMMITMENT_INVALID: u64 = 326;
    const E_ADMIN_CONFIG_MISMATCH: u64 = 327;
    const E_SETTLEMENT_WINDOW_CLOSED: u64 = 328;
    const E_LEGACY_BRAWL_FACTORY_DISABLED: u64 = 329;
    const E_CANCEL_REASON_INVALID: u64 = 330;
    const E_ROSTER_LOCKED: u64 = 331;
    const E_LEGACY_SETTLEMENT_DISABLED: u64 = 332;
    #[allow(unused_const)]
    const E_TEST_TIMEOUT_NOT_SETTLED: u64 = 390;
    #[allow(unused_const)]
    const E_TEST_TIMEOUT_RESOLUTION_MISMATCH: u64 = 391;
    #[allow(unused_const)]
    const E_TEST_TIMEOUT_VAULT_NOT_EMPTY: u64 = 392;

    const RESOLUTION_OPEN: u8 = 0;
    const RESOLUTION_WINNER: u8 = 1;
    const RESOLUTION_DRAW: u8 = 2;
    const RESOLUTION_VOID: u8 = 3;
    const RESOLUTION_TIMEOUT_REFUND: u8 = 4;

    const MAX_PARTICIPANTS_HARD: u8 = 10;
    const MAX_BRAWL_DURATION_MS: u64 = 86_400_000;
    const REFUND_GRACE_MS: u64 = 30 * 60 * 1000;
    const MAX_REFERENCE_BYTES: u64 = 128;
    // max u64 / MAX_PARTICIPANTS_HARD, rounded down.
    const MAX_SAFE_ENTRY_MIST: u64 = 1_844_674_407_370_955_161;

    public struct BrawlAdminCap has key, store {
        id: UID,
        config_id: address,
    }

    public struct BrawlFactoryCap has key, store {
        id: UID,
    }

    public struct BRAWLS has drop {}

    public struct BrawlConfig<phantom T> has key {
        id: UID,
        verifier_pubkey: vector<u8>,
        paused: bool,
        min_entry_mist: u64,
        max_entry_mist: u64,
    }

    public struct Brawl<phantom T> has key {
        id: UID,
        config_id: address,
        brawl_id: String,
        creator: address,
        entry_fee_mist: u64,
        min_participants: u8,
        max_participants: u8,
        ends_at_ms: u64,
        refund_after_ms: u64,
        vault: Balance<T>,
        participants: vector<address>,
        settled: bool,
        resolution_type: u8,
    }

    public struct BrawlCreateKey has copy, drop, store {
        brawl_id: String,
    }

    public struct BrawlNonceKey has copy, drop, store {
        nonce_key: u64,
    }

    public struct BrawlNonceDomainKey has copy, drop, store {
        domain: u8,
        nonce_key: u64,
    }

    public struct BrawlRosterLockKey has copy, drop, store {
        marker: u8,
    }

    public struct BrawlCreated has copy, drop {
        config_id: address,
        brawl_object_id: address,
        brawl_id: String,
        creator: address,
        entry_fee_mist: u64,
        min_participants: u8,
        max_participants: u8,
        ends_at_ms: u64,
        refund_after_ms: u64,
    }

    public struct BrawlJoined has copy, drop {
        brawl_object_id: address,
        brawl_id: String,
        user: address,
        amount_mist: u64,
        participant_count: u8,
    }

    public struct BrawlSettled has copy, drop {
        brawl_object_id: address,
        brawl_id: String,
        resolution_type: u8,
        winners: vector<address>,
        gross_pot_mist: u64,
        payout_mist: u64,
        burn_mist: u64,
        result_commitment: vector<u8>,
    }

    public struct BrawlSettledV2 has copy, drop {
        brawl_object_id: address,
        brawl_id: String,
        resolution_type: u8,
        winners: vector<address>,
        gross_pot_mist: u64,
        payout_mist: u64,
        developer_share_mist: u64,
        burn_mist: u64,
        developer_revenue_recipient: address,
        result_commitment: vector<u8>,
    }

    public struct BrawlRosterLocked has copy, drop {
        brawl_object_id: address,
        brawl_id: String,
        participant_count: u8,
    }

    fun assert_unexpired(expiry_ms: u64, clock: &Clock) {
        assert!(expiry_ms > clock::timestamp_ms(clock), E_AUTH_EXPIRED);
    }

    fun assert_not_paused<T>(cfg: &BrawlConfig<T>) {
        assert!(!cfg.paused, E_BRAWLS_PAUSED);
    }

    fun assert_reference(value: &String) {
        let len = vector::length(value.as_bytes());
        assert!(len > 0 && len <= MAX_REFERENCE_BYTES, E_INVALID_BRAWL_ID);
    }

    fun assert_config_binding<T>(cfg: &BrawlConfig<T>, brawl: &Brawl<T>) {
        assert!(brawl.config_id == object::id_address(cfg), E_CONFIG_MISMATCH);
    }

    fun assert_admin_binding<T>(cap: &BrawlAdminCap, cfg: &BrawlConfig<T>) {
        assert!(cap.config_id == object::id_address(cfg), E_ADMIN_CONFIG_MISMATCH);
    }

    fun contains_participant<T>(brawl: &Brawl<T>, user: address): bool {
        vector::contains(&brawl.participants, &user)
    }

    fun participant_count<T>(brawl: &Brawl<T>): u8 {
        vector::length(&brawl.participants) as u8
    }

    fun is_roster_locked<T>(brawl: &Brawl<T>): bool {
        dynamic_field::exists_with_type<BrawlRosterLockKey, bool>(
            &brawl.id,
            BrawlRosterLockKey { marker: 1 },
        )
    }

    fun mark_roster_locked<T>(brawl: &mut Brawl<T>) {
        let key = BrawlRosterLockKey { marker: 1 };
        assert!(!dynamic_field::exists_with_type<BrawlRosterLockKey, bool>(&brawl.id, key), E_ROSTER_LOCKED);
        dynamic_field::add(&mut brawl.id, key, true);
    }

    fun gross_pot<T>(brawl: &Brawl<T>): u64 {
        brawl.entry_fee_mist * (participant_count(brawl) as u64)
    }

    fun competitive_split(gross: u64): (u64, u64, u64) {
        let commission_mist = gross / 10;
        let developer_share_mist = commission_mist / 5;
        let burn_mist = commission_mist - developer_share_mist;
        let payout_mist = gross - commission_mist;
        (payout_mist, developer_share_mist, burn_mist)
    }

    #[test]
    fun competitive_split_is_90_2_8() {
        let (payout_mist, developer_share_mist, burn_mist) = competitive_split(1_000);
        assert!(payout_mist == 900, 910);
        assert!(developer_share_mist == 20, 911);
        assert!(burn_mist == 80, 912);
    }

    fun assert_vault_matches_liability<T>(brawl: &Brawl<T>) {
        assert!(balance::value(&brawl.vault) == gross_pot(brawl), E_VAULT_LIABILITY_MISMATCH);
    }

    fun mark_nonce_used<T>(brawl: &mut Brawl<T>, nonce_key: u64) {
        let key = BrawlNonceKey { nonce_key };
        assert!(
            !dynamic_field::exists_with_type<BrawlNonceKey, bool>(&brawl.id, key),
            E_NONCE_USED,
        );
        dynamic_field::add(&mut brawl.id, key, true);
    }

    fun mark_nonce_used_domain<T>(brawl: &mut Brawl<T>, domain: u8, nonce_key: u64) {
        // Respect every nonce consumed by pre-upgrade code, then isolate new
        // nonces by authorization domain so independent join/result allocators
        // cannot invalidate one another.
        assert!(
            !dynamic_field::exists_with_type<BrawlNonceKey, bool>(
                &brawl.id,
                BrawlNonceKey { nonce_key },
            ),
            E_NONCE_USED,
        );
        let key = BrawlNonceDomainKey { domain, nonce_key };
        assert!(
            !dynamic_field::exists_with_type<BrawlNonceDomainKey, bool>(&brawl.id, key),
            E_NONCE_USED,
        );
        dynamic_field::add(&mut brawl.id, key, true);
    }

    fun legacy_settlement_disabled() {
        abort E_LEGACY_SETTLEMENT_DISABLED
    }

    fun mark_settled<T>(brawl: &mut Brawl<T>, resolution_type: u8) {
        assert!(!brawl.settled, E_BRAWL_SETTLED);
        brawl.settled = true;
        brawl.resolution_type = resolution_type;
    }

    fun validate_draw_winners<T>(brawl: &Brawl<T>, winners: &vector<address>) {
        let count = vector::length(winners);
        assert!(count >= 2 && count <= vector::length(&brawl.participants), E_DRAW_WINNERS_INVALID);
        let mut i = 0;
        while (i < count) {
            let winner = *vector::borrow(winners, i);
            assert!(contains_participant(brawl, winner), E_WINNER_INVALID);
            let mut j = i + 1;
            while (j < count) {
                assert!(winner != *vector::borrow(winners, j), E_DRAW_WINNER_DUPLICATE);
                j = j + 1;
            };
            i = i + 1;
        };
    }

    fun assert_result_commitment(result_commitment: &vector<u8>) {
        assert!(vector::length(result_commitment) == 32, E_RESULT_COMMITMENT_INVALID);
    }

    fun assert_settlement_window_open<T>(brawl: &Brawl<T>, clock: &Clock) {
        assert!(clock::timestamp_ms(clock) < brawl.refund_after_ms, E_SETTLEMENT_WINDOW_CLOSED);
    }

    fun assert_settlement_ready<T>(brawl: &Brawl<T>, expected_participant_count: u8, clock: &Clock) {
        assert!(!brawl.settled, E_BRAWL_SETTLED);
        assert_settlement_window_open(brawl, clock);
        let count = participant_count(brawl);
        assert!(count == expected_participant_count, E_PARTICIPANT_COUNT_MISMATCH);
        assert!(count >= brawl.min_participants, E_NOT_ENOUGH_PARTICIPANTS);
        assert!(
            is_roster_locked(brawl) || count == brawl.max_participants || clock::timestamp_ms(clock) >= brawl.ends_at_ms,
            E_SETTLEMENT_TOO_EARLY,
        );
        assert_vault_matches_liability(brawl);
    }

    fun assert_void_settlement_ready<T>(brawl: &Brawl<T>, expected_participant_count: u8, clock: &Clock) {
        assert!(!brawl.settled, E_BRAWL_SETTLED);
        assert_settlement_window_open(brawl, clock);
        let count = participant_count(brawl);
        assert!(count == expected_participant_count, E_PARTICIPANT_COUNT_MISMATCH);
        assert!(
            is_roster_locked(brawl) || count == brawl.max_participants || clock::timestamp_ms(clock) >= brawl.ends_at_ms,
            E_SETTLEMENT_TOO_EARLY,
        );
        assert_vault_matches_liability(brawl);
    }

    fun verify_join_signature<T>(
        cfg: &BrawlConfig<T>,
        brawl: &Brawl<T>,
        user: address,
        amount_mist: u64,
        nonce_key: u64,
        expiry_ms: u64,
        signature: &vector<u8>,
    ) {
        let mut message = b"GEXI_BRAWL_JOIN_V1";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&object::id_address(brawl)));
        vector::append(&mut message, bcs::to_bytes(&user));
        vector::append(&mut message, bcs::to_bytes(&brawl.brawl_id));
        vector::append(&mut message, bcs::to_bytes(&amount_mist));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(signature, &cfg.verifier_pubkey, &message), E_SIGNATURE_INVALID);
    }

    fun verify_winner_signature<T>(
        cfg: &BrawlConfig<T>,
        brawl: &Brawl<T>,
        winner: address,
        expected_participant_count: u8,
        result_commitment: &vector<u8>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: &vector<u8>,
    ) {
        let mut message = b"GEXI_BRAWL_SETTLE_WINNER_V1";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&object::id_address(brawl)));
        vector::append(&mut message, bcs::to_bytes(&brawl.brawl_id));
        vector::append(&mut message, bcs::to_bytes(&winner));
        vector::append(&mut message, bcs::to_bytes(&expected_participant_count));
        vector::append(&mut message, bcs::to_bytes(result_commitment));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(signature, &cfg.verifier_pubkey, &message), E_SIGNATURE_INVALID);
    }

    fun verify_winner_signature_v2<T>(
        cfg: &BrawlConfig<T>,
        brawl: &Brawl<T>,
        winner: address,
        developer_revenue_recipient: address,
        expected_participant_count: u8,
        result_commitment: &vector<u8>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: &vector<u8>,
    ) {
        let mut message = b"GEXI_BRAWL_SETTLE_WINNER_V2";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&object::id_address(brawl)));
        vector::append(&mut message, bcs::to_bytes(&brawl.brawl_id));
        vector::append(&mut message, bcs::to_bytes(&winner));
        vector::append(&mut message, bcs::to_bytes(&developer_revenue_recipient));
        vector::append(&mut message, bcs::to_bytes(&expected_participant_count));
        vector::append(&mut message, bcs::to_bytes(result_commitment));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(signature, &cfg.verifier_pubkey, &message), E_SIGNATURE_INVALID);
    }

    fun verify_draw_signature<T>(
        cfg: &BrawlConfig<T>,
        brawl: &Brawl<T>,
        winners: &vector<address>,
        expected_participant_count: u8,
        result_commitment: &vector<u8>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: &vector<u8>,
    ) {
        let mut message = b"GEXI_BRAWL_SETTLE_DRAW_V1";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&object::id_address(brawl)));
        vector::append(&mut message, bcs::to_bytes(&brawl.brawl_id));
        vector::append(&mut message, bcs::to_bytes(winners));
        vector::append(&mut message, bcs::to_bytes(&expected_participant_count));
        vector::append(&mut message, bcs::to_bytes(result_commitment));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(signature, &cfg.verifier_pubkey, &message), E_SIGNATURE_INVALID);
    }

    fun verify_draw_signature_v2<T>(
        cfg: &BrawlConfig<T>,
        brawl: &Brawl<T>,
        winners: &vector<address>,
        developer_revenue_recipient: address,
        expected_participant_count: u8,
        result_commitment: &vector<u8>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: &vector<u8>,
    ) {
        let mut message = b"GEXI_BRAWL_SETTLE_DRAW_V2";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&object::id_address(brawl)));
        vector::append(&mut message, bcs::to_bytes(&brawl.brawl_id));
        vector::append(&mut message, bcs::to_bytes(winners));
        vector::append(&mut message, bcs::to_bytes(&developer_revenue_recipient));
        vector::append(&mut message, bcs::to_bytes(&expected_participant_count));
        vector::append(&mut message, bcs::to_bytes(result_commitment));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(signature, &cfg.verifier_pubkey, &message), E_SIGNATURE_INVALID);
    }

    fun verify_void_signature<T>(
        cfg: &BrawlConfig<T>,
        brawl: &Brawl<T>,
        expected_participant_count: u8,
        result_commitment: &vector<u8>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: &vector<u8>,
    ) {
        let mut message = b"GEXI_BRAWL_SETTLE_VOID_V1";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&object::id_address(brawl)));
        vector::append(&mut message, bcs::to_bytes(&brawl.brawl_id));
        vector::append(&mut message, bcs::to_bytes(&expected_participant_count));
        vector::append(&mut message, bcs::to_bytes(result_commitment));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(signature, &cfg.verifier_pubkey, &message), E_SIGNATURE_INVALID);
    }

    fun verify_cancel_signature<T>(
        cfg: &BrawlConfig<T>,
        brawl: &Brawl<T>,
        expected_participant_count: u8,
        result_commitment: &vector<u8>,
        cancel_reason: u8,
        nonce_key: u64,
        expiry_ms: u64,
        signature: &vector<u8>,
    ) {
        assert!(cancel_reason == 1 || cancel_reason == 2, E_CANCEL_REASON_INVALID);
        let mut message = b"GEXI_BRAWL_CANCEL_V1";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&object::id_address(brawl)));
        vector::append(&mut message, bcs::to_bytes(&brawl.brawl_id));
        vector::append(&mut message, bcs::to_bytes(&expected_participant_count));
        vector::append(&mut message, bcs::to_bytes(result_commitment));
        vector::append(&mut message, bcs::to_bytes(&cancel_reason));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(signature, &cfg.verifier_pubkey, &message), E_SIGNATURE_INVALID);
    }

    fun verify_roster_lock_signature<T>(
        cfg: &BrawlConfig<T>,
        brawl: &Brawl<T>,
        expected_participant_count: u8,
        nonce_key: u64,
        expiry_ms: u64,
        signature: &vector<u8>,
    ) {
        let mut message = b"GEXI_BRAWL_LOCK_ROSTER_V1";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&object::id_address(brawl)));
        vector::append(&mut message, bcs::to_bytes(&brawl.brawl_id));
        vector::append(&mut message, bcs::to_bytes(&expected_participant_count));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(signature, &cfg.verifier_pubkey, &message), E_SIGNATURE_INVALID);
    }

    fun init(_witness: BRAWLS, ctx: &mut TxContext) {
        transfer::transfer(BrawlFactoryCap { id: object::new(ctx) }, tx_context::sender(ctx));
    }

    #[allow(unused_variable, unused_type_parameter, lint(public_entry))]
    public entry fun create_brawls<T>(
        verifier_pubkey: vector<u8>,
        ctx: &mut TxContext,
    ) {
        // Kept only for package-upgrade ABI compatibility. Fresh deployments
        // create the canonical config through the one-time factory capability.
        abort E_LEGACY_BRAWL_FACTORY_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun create_brawls_v2<T>(
        _: &BrawlFactoryCap,
        verifier_pubkey: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(vector::length(&verifier_pubkey) == 32, E_VERIFIER_KEY_INVALID);
        let cfg = BrawlConfig<T> {
            id: object::new(ctx),
            verifier_pubkey,
            paused: false,
            min_entry_mist: 20_000_000_000,
            max_entry_mist: 1_000_000_000_000,
        };
        let config_id = object::id_address(&cfg);
        transfer::transfer(
            BrawlAdminCap { id: object::new(ctx), config_id },
            tx_context::sender(ctx),
        );
        transfer::share_object(cfg);
    }

    public entry fun destroy_brawl_factory_cap(cap: BrawlFactoryCap) {
        let BrawlFactoryCap { id } = cap;
        id.delete();
    }

    #[allow(lint(public_entry))]
    public entry fun create_brawl_v1<T>(
        cfg: &mut BrawlConfig<T>,
        payment: Coin<T>,
        brawl_id: String,
        min_participants: u8,
        max_participants: u8,
        ends_at_ms: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_not_paused(cfg);
        assert_unexpired(expiry_ms, clock);
        assert_reference(&brawl_id);
        let now_ms = clock::timestamp_ms(clock);
        assert!(
            ends_at_ms > now_ms
                && ends_at_ms <= now_ms + MAX_BRAWL_DURATION_MS
                && ends_at_ms <= 18_446_744_073_707_551_615 - REFUND_GRACE_MS,
            E_END_TIME_INVALID,
        );
        assert!(
            min_participants >= 2
                && min_participants <= max_participants
                && max_participants <= MAX_PARTICIPANTS_HARD,
            E_PARTICIPANT_LIMITS_INVALID,
        );
        let amount_mist = coin::value(&payment);
        assert!(amount_mist >= cfg.min_entry_mist && amount_mist <= cfg.max_entry_mist, E_ENTRY_FEE_INVALID);
        let creator = tx_context::sender(ctx);
        let mut message = b"GEXI_BRAWL_CREATE_V1";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&creator));
        vector::append(&mut message, bcs::to_bytes(&brawl_id));
        vector::append(&mut message, bcs::to_bytes(&amount_mist));
        vector::append(&mut message, bcs::to_bytes(&min_participants));
        vector::append(&mut message, bcs::to_bytes(&max_participants));
        vector::append(&mut message, bcs::to_bytes(&ends_at_ms));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(&signature, &cfg.verifier_pubkey, &message), E_SIGNATURE_INVALID);

        let create_key = BrawlCreateKey { brawl_id };
        assert!(
            !dynamic_field::exists_with_type<BrawlCreateKey, bool>(&cfg.id, create_key),
            E_BRAWL_ID_ALREADY_USED,
        );
        dynamic_field::add(&mut cfg.id, create_key, true);

        let refund_after_ms = ends_at_ms + REFUND_GRACE_MS;
        let mut brawl = Brawl<T> {
            id: object::new(ctx),
            config_id: object::id_address(cfg),
            brawl_id,
            creator,
            entry_fee_mist: amount_mist,
            min_participants,
            max_participants,
            ends_at_ms,
            refund_after_ms,
            vault: coin::into_balance(payment),
            participants: vector[creator],
            settled: false,
            resolution_type: RESOLUTION_OPEN,
        };
        let brawl_object_id = object::id_address(&brawl);
        event::emit(BrawlCreated {
            config_id: object::id_address(cfg),
            brawl_object_id,
            brawl_id,
            creator,
            entry_fee_mist: amount_mist,
            min_participants,
            max_participants,
            ends_at_ms,
            refund_after_ms,
        });
        transfer::share_object(brawl);
    }

    #[allow(lint(public_entry))]
    public entry fun join_brawl_v1<T>(
        cfg: &BrawlConfig<T>,
        brawl: &mut Brawl<T>,
        payment: Coin<T>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_not_paused(cfg);
        assert_config_binding(cfg, brawl);
        assert_unexpired(expiry_ms, clock);
        assert!(!brawl.settled, E_BRAWL_SETTLED);
        assert!(!is_roster_locked(brawl), E_ROSTER_LOCKED);
        assert!(clock::timestamp_ms(clock) < brawl.ends_at_ms, E_BRAWL_ENDED);
        assert!(participant_count(brawl) < brawl.max_participants, E_BRAWL_FULL);
        let user = tx_context::sender(ctx);
        assert!(!contains_participant(brawl, user), E_ALREADY_JOINED);
        let amount_mist = coin::value(&payment);
        assert!(amount_mist == brawl.entry_fee_mist, E_ENTRY_FEE_INVALID);
        verify_join_signature(cfg, brawl, user, amount_mist, nonce_key, expiry_ms, &signature);
        mark_nonce_used_domain(brawl, 1, nonce_key);
        vector::push_back(&mut brawl.participants, user);
        balance::join(&mut brawl.vault, coin::into_balance(payment));
        event::emit(BrawlJoined {
            brawl_object_id: object::id_address(brawl),
            brawl_id: brawl.brawl_id,
            user,
            amount_mist,
            participant_count: participant_count(brawl),
        });
    }

    /// Freezes the paid online roster before gameplay starts. Once locked, no
    /// previously issued join authorization can add a late stake, and the exact
    /// roster may settle before the generic Brawl end time.
    #[allow(lint(public_entry))]
    public entry fun lock_online_roster_v1<T>(
        cfg: &BrawlConfig<T>,
        brawl: &mut Brawl<T>,
        expected_participant_count: u8,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        _ctx: &mut TxContext,
    ) {
        assert_not_paused(cfg);
        assert_config_binding(cfg, brawl);
        assert_unexpired(expiry_ms, clock);
        assert!(!brawl.settled, E_BRAWL_SETTLED);
        assert_settlement_window_open(brawl, clock);
        let count = participant_count(brawl);
        assert!(count == expected_participant_count, E_PARTICIPANT_COUNT_MISMATCH);
        assert!(count >= brawl.min_participants, E_NOT_ENOUGH_PARTICIPANTS);
        assert!(!is_roster_locked(brawl), E_ROSTER_LOCKED);
        assert_vault_matches_liability(brawl);
        verify_roster_lock_signature(
            cfg,
            brawl,
            expected_participant_count,
            nonce_key,
            expiry_ms,
            &signature,
        );
        mark_nonce_used_domain(brawl, 2, nonce_key);
        mark_roster_locked(brawl);
        event::emit(BrawlRosterLocked {
            brawl_object_id: object::id_address(brawl),
            brawl_id: brawl.brawl_id,
            participant_count: count,
        });
    }

    #[allow(lint(public_entry))]
    public entry fun settle_winner_v1<T>(
        cfg: &BrawlConfig<T>,
        brawl: &mut Brawl<T>,
        currency: &mut Currency<T>,
        winner: address,
        expected_participant_count: u8,
        result_commitment: vector<u8>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        legacy_settlement_disabled()
    }

    #[allow(lint(public_entry))]
    public entry fun settle_winner_v2<T>(
        cfg: &BrawlConfig<T>,
        brawl: &mut Brawl<T>,
        currency: &mut Currency<T>,
        winner: address,
        developer_revenue_recipient: address,
        expected_participant_count: u8,
        result_commitment: vector<u8>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_not_paused(cfg);
        assert_config_binding(cfg, brawl);
        assert_unexpired(expiry_ms, clock);
        assert_result_commitment(&result_commitment);
        assert_settlement_ready(brawl, expected_participant_count, clock);
        assert!(contains_participant(brawl, winner), E_WINNER_INVALID);
        verify_winner_signature_v2(
            cfg,
            brawl,
            winner,
            developer_revenue_recipient,
            expected_participant_count,
            &result_commitment,
            nonce_key,
            expiry_ms,
            &signature,
        );
        mark_nonce_used_domain(brawl, 3, nonce_key);
        let gross = gross_pot(brawl);
        let (payout_mist, developer_share_mist, burn_mist) = competitive_split(gross);
        mark_settled(brawl, RESOLUTION_WINNER);
        let payout = coin::from_balance(balance::split(&mut brawl.vault, payout_mist), ctx);
        transfer::public_transfer(payout, winner);
        if (developer_share_mist > 0) {
            let developer_coin = coin::from_balance(balance::split(&mut brawl.vault, developer_share_mist), ctx);
            transfer::public_transfer(developer_coin, developer_revenue_recipient);
        };
        if (burn_mist > 0) {
            let burn_coin = coin::from_balance(balance::split(&mut brawl.vault, burn_mist), ctx);
            coin_registry::burn(currency, burn_coin);
        };
        assert!(balance::value(&brawl.vault) == 0, E_VAULT_LIABILITY_MISMATCH);
        event::emit(BrawlSettled {
            brawl_object_id: object::id_address(brawl),
            brawl_id: brawl.brawl_id,
            resolution_type: RESOLUTION_WINNER,
            winners: vector[winner],
            gross_pot_mist: gross,
            payout_mist,
            burn_mist,
            result_commitment,
        });
        event::emit(BrawlSettledV2 {
            brawl_object_id: object::id_address(brawl),
            brawl_id: brawl.brawl_id,
            resolution_type: RESOLUTION_WINNER,
            winners: vector[winner],
            gross_pot_mist: gross,
            payout_mist,
            developer_share_mist,
            burn_mist,
            developer_revenue_recipient,
            result_commitment,
        });
    }

    #[allow(lint(public_entry))]
    public entry fun settle_draw_v1<T>(
        cfg: &BrawlConfig<T>,
        brawl: &mut Brawl<T>,
        currency: &mut Currency<T>,
        winners: vector<address>,
        expected_participant_count: u8,
        result_commitment: vector<u8>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        legacy_settlement_disabled()
    }

    #[allow(lint(public_entry))]
    public entry fun settle_draw_v2<T>(
        cfg: &BrawlConfig<T>,
        brawl: &mut Brawl<T>,
        currency: &mut Currency<T>,
        winners: vector<address>,
        developer_revenue_recipient: address,
        expected_participant_count: u8,
        result_commitment: vector<u8>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_not_paused(cfg);
        assert_config_binding(cfg, brawl);
        assert_unexpired(expiry_ms, clock);
        assert_result_commitment(&result_commitment);
        assert_settlement_ready(brawl, expected_participant_count, clock);
        validate_draw_winners(brawl, &winners);
        verify_draw_signature_v2(
            cfg,
            brawl,
            &winners,
            developer_revenue_recipient,
            expected_participant_count,
            &result_commitment,
            nonce_key,
            expiry_ms,
            &signature,
        );
        mark_nonce_used_domain(brawl, 4, nonce_key);
        let gross = gross_pot(brawl);
        let (payout_mist, developer_share_mist, burn_mist) = competitive_split(gross);
        let winner_count = vector::length(&winners);
        let base_share = payout_mist / (winner_count as u64);
        let remainder = payout_mist % (winner_count as u64);
        mark_settled(brawl, RESOLUTION_DRAW);
        let mut i = 0;
        while (i < winner_count) {
            let winner = *vector::borrow(&winners, i);
            let share = base_share + if ((i as u64) < remainder) 1 else 0;
            let payout = coin::from_balance(balance::split(&mut brawl.vault, share), ctx);
            transfer::public_transfer(payout, winner);
            i = i + 1;
        };
        if (developer_share_mist > 0) {
            let developer_coin = coin::from_balance(balance::split(&mut brawl.vault, developer_share_mist), ctx);
            transfer::public_transfer(developer_coin, developer_revenue_recipient);
        };
        if (burn_mist > 0) {
            let burn_coin = coin::from_balance(balance::split(&mut brawl.vault, burn_mist), ctx);
            coin_registry::burn(currency, burn_coin);
        };
        assert!(balance::value(&brawl.vault) == 0, E_VAULT_LIABILITY_MISMATCH);
        event::emit(BrawlSettled {
            brawl_object_id: object::id_address(brawl),
            brawl_id: brawl.brawl_id,
            resolution_type: RESOLUTION_DRAW,
            winners,
            gross_pot_mist: gross,
            payout_mist,
            burn_mist,
            result_commitment,
        });
        event::emit(BrawlSettledV2 {
            brawl_object_id: object::id_address(brawl),
            brawl_id: brawl.brawl_id,
            resolution_type: RESOLUTION_DRAW,
            winners,
            gross_pot_mist: gross,
            payout_mist,
            developer_share_mist,
            burn_mist,
            developer_revenue_recipient,
            result_commitment,
        });
    }

    fun refund_all<T>(
        brawl: &mut Brawl<T>,
        resolution_type: u8,
        result_commitment: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(!brawl.settled, E_BRAWL_SETTLED);
        assert_vault_matches_liability(brawl);
        let gross = gross_pot(brawl);
        mark_settled(brawl, resolution_type);
        let count = vector::length(&brawl.participants);
        let mut i = 0;
        while (i < count) {
            let user = *vector::borrow(&brawl.participants, i);
            let refund = coin::from_balance(balance::split(&mut brawl.vault, brawl.entry_fee_mist), ctx);
            transfer::public_transfer(refund, user);
            i = i + 1;
        };
        assert!(balance::value(&brawl.vault) == 0, E_VAULT_LIABILITY_MISMATCH);
        event::emit(BrawlSettled {
            brawl_object_id: object::id_address(brawl),
            brawl_id: brawl.brawl_id,
            resolution_type,
            winners: vector[],
            gross_pot_mist: gross,
            payout_mist: gross,
            burn_mist: 0,
            result_commitment,
        });
    }

    #[allow(lint(public_entry))]
    public entry fun settle_void_v1<T>(
        cfg: &BrawlConfig<T>,
        brawl: &mut Brawl<T>,
        expected_participant_count: u8,
        result_commitment: vector<u8>,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_config_binding(cfg, brawl);
        assert_unexpired(expiry_ms, clock);
        assert_result_commitment(&result_commitment);
        assert_void_settlement_ready(brawl, expected_participant_count, clock);
        verify_void_signature(
            cfg,
            brawl,
            expected_participant_count,
            &result_commitment,
            nonce_key,
            expiry_ms,
            &signature,
        );
        mark_nonce_used_domain(brawl, 5, nonce_key);
        refund_all(brawl, RESOLUTION_VOID, result_commitment, ctx);
    }

    /// Verifier-authorized early cancellation for online matchmaking. This is a
    /// separate signature domain from result settlement so a normal void voucher
    /// can never be replayed to cancel a live multi-player Brawl before ends_at.
    #[allow(lint(public_entry))]
    public entry fun settle_cancel_v1<T>(
        cfg: &BrawlConfig<T>,
        brawl: &mut Brawl<T>,
        expected_participant_count: u8,
        result_commitment: vector<u8>,
        cancel_reason: u8,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_config_binding(cfg, brawl);
        assert_unexpired(expiry_ms, clock);
        assert_result_commitment(&result_commitment);
        assert!(!brawl.settled, E_BRAWL_SETTLED);
        assert_settlement_window_open(brawl, clock);
        assert!(participant_count(brawl) == expected_participant_count, E_PARTICIPANT_COUNT_MISMATCH);
        assert_vault_matches_liability(brawl);
        verify_cancel_signature(
            cfg,
            brawl,
            expected_participant_count,
            &result_commitment,
            cancel_reason,
            nonce_key,
            expiry_ms,
            &signature,
        );
        mark_nonce_used_domain(brawl, 6, nonce_key);
        refund_all(brawl, RESOLUTION_VOID, result_commitment, ctx);
    }

    /// Permissionless safety valve: if the result oracle/backend is unavailable,
    /// anybody can return every active participant's exact stake after the fixed
    /// settlement grace period. Pausing the module never blocks this escape hatch.
    #[allow(lint(public_entry))]
    public entry fun refund_expired_brawl<T>(
        cfg: &BrawlConfig<T>,
        brawl: &mut Brawl<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_config_binding(cfg, brawl);
        assert!(!brawl.settled, E_BRAWL_SETTLED);
        assert!(clock::timestamp_ms(clock) >= brawl.refund_after_ms, E_TIMEOUT_NOT_REACHED);
        refund_all(brawl, RESOLUTION_TIMEOUT_REFUND, vector[], ctx);
    }

    #[allow(lint(public_entry))]
    public entry fun set_paused<T>(cap: &BrawlAdminCap, cfg: &mut BrawlConfig<T>, paused: bool) {
        assert_admin_binding(cap, cfg);
        cfg.paused = paused;
    }

    #[allow(lint(public_entry))]
    public entry fun set_limits<T>(
        cap: &BrawlAdminCap,
        cfg: &mut BrawlConfig<T>,
        min_entry_mist: u64,
        max_entry_mist: u64,
    ) {
        assert_admin_binding(cap, cfg);
        assert!(
            min_entry_mist > 0
                && min_entry_mist <= max_entry_mist
                && max_entry_mist <= MAX_SAFE_ENTRY_MIST,
            E_INVALID_LIMITS,
        );
        cfg.min_entry_mist = min_entry_mist;
        cfg.max_entry_mist = max_entry_mist;
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun set_verifier<T>(cap: &BrawlAdminCap, cfg: &mut BrawlConfig<T>, verifier_pubkey: vector<u8>) {
        assert_admin_binding(cap, cfg);
        abort E_VERIFIER_ROTATION_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_withdraw<T>(
        cap: &BrawlAdminCap,
        brawl: &mut Brawl<T>,
        amount: u64,
        to: address,
        ctx: &mut TxContext,
    ) {
        assert!(cap.config_id == brawl.config_id, E_ADMIN_CONFIG_MISMATCH);
        abort E_ADMIN_WITHDRAW_DISABLED
    }

    #[test_only]
    public fun brawl_admin_cap_for_testing<T>(cfg: &BrawlConfig<T>, ctx: &mut TxContext): BrawlAdminCap {
        BrawlAdminCap { id: object::new(ctx), config_id: object::id_address(cfg) }
    }

    #[test_only]
    public fun destroy_brawl_admin_cap_for_testing(cap: BrawlAdminCap) {
        let BrawlAdminCap { id, config_id: _ } = cap;
        id.delete();
    }

    #[test_only]
    fun test_config(ctx: &mut TxContext): BrawlConfig<u8> {
        BrawlConfig<u8> {
            id: object::new(ctx),
            verifier_pubkey: vector[],
            paused: false,
            min_entry_mist: 20,
            max_entry_mist: 1000,
        }
    }

    #[test_only]
    fun test_brawl(ctx: &mut TxContext, cfg: &BrawlConfig<u8>, entry_fee: u64): Brawl<u8> {
        Brawl<u8> {
            id: object::new(ctx),
            config_id: object::id_address(cfg),
            brawl_id: std::string::utf8(b"test-brawl"),
            creator: @0x1,
            entry_fee_mist: entry_fee,
            min_participants: 2,
            max_participants: 10,
            ends_at_ms: 10_000,
            refund_after_ms: 20_000,
            vault: balance::zero(),
            participants: vector[@0x1],
            settled: false,
            resolution_type: RESOLUTION_OPEN,
        }
    }

    #[test_only]
    fun add_test_participant(brawl: &mut Brawl<u8>, user: address, amount: u64, ctx: &mut TxContext) {
        assert!(!contains_participant(brawl, user), E_ALREADY_JOINED);
        vector::push_back(&mut brawl.participants, user);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(amount, ctx)));
    }

    #[test]
    fun create_config_bootstraps_admin_and_consumes_factory_cap() {
        let deployer = @0xA11CE;
        let mut scenario = sui::test_scenario::begin(deployer);
        init(BRAWLS {}, scenario.ctx());
        scenario.next_tx(deployer);
        let factory = scenario.take_from_sender<BrawlFactoryCap>();
        create_brawls_v2<u8>(&factory, vector[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], scenario.ctx());
        scenario.next_tx(deployer);
        let cap = scenario.take_from_sender<BrawlAdminCap>();
        let cfg = scenario.take_shared<BrawlConfig<u8>>();
        scenario.return_to_sender(cap);
        destroy_brawl_factory_cap(factory);
        sui::test_scenario::return_shared(cfg);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_BRAWL_FACTORY_DISABLED)]
    fun permissionless_legacy_brawl_factory_is_disabled() {
        let mut ctx = tx_context::dummy();
        create_brawls<u8>(vector[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], &mut ctx);
    }

    #[test]
    #[expected_failure(abort_code = E_ALREADY_JOINED)]
    fun duplicate_participant_is_rejected() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        add_test_participant(&mut brawl, @0x2, 100, &mut ctx);
        add_test_participant(&mut brawl, @0x2, 100, &mut ctx);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_DRAW_WINNER_DUPLICATE)]
    fun draw_duplicate_winner_is_rejected() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        add_test_participant(&mut brawl, @0x2, 100, &mut ctx);
        validate_draw_winners(&brawl, &vector[@0x1, @0x1]);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_WINNER_INVALID)]
    fun draw_nonparticipant_is_rejected() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        add_test_participant(&mut brawl, @0x2, 100, &mut ctx);
        validate_draw_winners(&brawl, &vector[@0x1, @0x9]);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_NOT_ENOUGH_PARTICIPANTS)]
    fun winner_requires_minimum_participants() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 10_000);
        assert_settlement_ready(&brawl, 1, &clock);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_VAULT_LIABILITY_MISMATCH)]
    fun settlement_rejects_underfunded_vault() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        vector::push_back(&mut brawl.participants, @0x2);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(199, &mut ctx)));
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 10_000);
        assert_settlement_ready(&brawl, 2, &clock);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_NONCE_USED)]
    fun nonce_replay_is_rejected() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        mark_nonce_used(&mut brawl, 42);
        mark_nonce_used(&mut brawl, 42);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_BRAWL_SETTLED)]
    fun settlement_is_single_use() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        mark_settled(&mut brawl, RESOLUTION_VOID);
        mark_settled(&mut brawl, RESOLUTION_WINNER);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_PARTICIPANT_COUNT_MISMATCH)]
    fun stale_settlement_participant_count_is_rejected() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        add_test_participant(&mut brawl, @0x2, 100, &mut ctx);
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 10_000);
        assert_settlement_ready(&brawl, 1, &clock);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_SETTLEMENT_TOO_EARLY)]
    fun under_capacity_brawl_cannot_settle_early() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        add_test_participant(&mut brawl, @0x2, 100, &mut ctx);
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 9_999);
        assert_settlement_ready(&brawl, 2, &clock);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    fun locked_online_roster_can_settle_under_capacity() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        add_test_participant(&mut brawl, @0x2, 100, &mut ctx);
        mark_roster_locked(&mut brawl);
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 9_999);
        assert!(is_roster_locked(&brawl), E_TEST_TIMEOUT_NOT_SETTLED);
        assert_settlement_ready(&brawl, 2, &clock);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_ROSTER_LOCKED)]
    fun locked_online_roster_rejects_late_join() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        add_test_participant(&mut brawl, @0x2, 100, &mut ctx);
        mark_roster_locked(&mut brawl);
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 9_999);
        let payment = coin::mint_for_testing<u8>(100, &mut ctx);
        join_brawl_v1(&cfg, &mut brawl, payment, 777, 10_000, vector[], &clock, &mut ctx);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_CONFIG_MISMATCH)]
    fun brawl_cannot_use_another_config() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let other = test_config(&mut ctx);
        let brawl = test_brawl(&mut ctx, &cfg, 100);
        assert_config_binding(&other, &brawl);
        transfer::share_object(cfg);
        transfer::share_object(other);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_LIMITS)]
    fun unsafe_entry_limit_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = test_config(&mut ctx);
        let admin = brawl_admin_cap_for_testing(&cfg, &mut ctx);
        set_limits(&admin, &mut cfg, 20, MAX_SAFE_ENTRY_MIST + 1);
        transfer::share_object(cfg);
        destroy_brawl_admin_cap_for_testing(admin);
    }

    #[test]
    #[expected_failure(abort_code = E_VERIFIER_ROTATION_DISABLED)]
    fun admin_cannot_rotate_verifier() {
        let mut ctx = tx_context::dummy();
        let mut cfg = test_config(&mut ctx);
        let admin = brawl_admin_cap_for_testing(&cfg, &mut ctx);
        set_verifier(&admin, &mut cfg, vector[]);
        transfer::share_object(cfg);
        destroy_brawl_admin_cap_for_testing(admin);
    }

    #[test]
    #[expected_failure(abort_code = E_ADMIN_WITHDRAW_DISABLED)]
    fun admin_cannot_withdraw_brawl_stakes() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let admin = brawl_admin_cap_for_testing(&cfg, &mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        admin_withdraw(&admin, &mut brawl, 100, @0x9, &mut ctx);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
        destroy_brawl_admin_cap_for_testing(admin);
    }

    #[test]
    #[expected_failure(abort_code = E_ADMIN_CONFIG_MISMATCH)]
    fun admin_cap_cannot_control_another_config() {
        let mut ctx = tx_context::dummy();
        let cfg_a = test_config(&mut ctx);
        let admin_a = brawl_admin_cap_for_testing(&cfg_a, &mut ctx);
        let mut cfg_b = test_config(&mut ctx);
        set_paused(&admin_a, &mut cfg_b, true);
        transfer::share_object(cfg_a);
        transfer::share_object(cfg_b);
        destroy_brawl_admin_cap_for_testing(admin_a);
    }

    #[test]
    #[expected_failure(abort_code = E_BRAWLS_PAUSED)]
    fun paused_brawls_block_competitive_settlement_gate() {
        let mut ctx = tx_context::dummy();
        let mut cfg = test_config(&mut ctx);
        cfg.paused = true;
        assert_not_paused(&cfg);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_TIMEOUT_NOT_REACHED)]
    fun timeout_refund_cannot_run_early() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 19_999);
        refund_expired_brawl(&cfg, &mut brawl, &clock, &mut ctx);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_SETTLEMENT_TOO_EARLY)]
    fun generic_void_cannot_cancel_single_participant_before_end() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 9_999);
        assert_void_settlement_ready(&brawl, 1, &clock);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_SETTLEMENT_WINDOW_CLOSED)]
    fun signed_settlement_closes_at_timeout_refund_deadline() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        add_test_participant(&mut brawl, @0x2, 100, &mut ctx);
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, brawl.refund_after_ms);
        assert_settlement_ready(&brawl, 2, &clock);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    fun timeout_refund_returns_all_liability() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        balance::join(&mut brawl.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        add_test_participant(&mut brawl, @0x2, 100, &mut ctx);
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 20_000);
        refund_expired_brawl(&cfg, &mut brawl, &clock, &mut ctx);
        assert!(brawl.settled, E_TEST_TIMEOUT_NOT_SETTLED);
        assert!(brawl.resolution_type == RESOLUTION_TIMEOUT_REFUND, E_TEST_TIMEOUT_RESOLUTION_MISMATCH);
        assert!(balance::value(&brawl.vault) == 0, E_TEST_TIMEOUT_VAULT_NOT_EMPTY);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_SETTLEMENT_DISABLED)]
    fun legacy_settlement_gate_is_disabled() {
        legacy_settlement_disabled();
    }

    #[test]
    fun nonce_domains_allow_same_numeric_nonce() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        mark_nonce_used_domain(&mut brawl, 1, 42);
        mark_nonce_used_domain(&mut brawl, 3, 42);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }

    #[test]
    #[expected_failure(abort_code = E_NONCE_USED)]
    fun nonce_replay_is_rejected_within_domain() {
        let mut ctx = tx_context::dummy();
        let cfg = test_config(&mut ctx);
        let mut brawl = test_brawl(&mut ctx, &cfg, 100);
        mark_nonce_used_domain(&mut brawl, 3, 42);
        mark_nonce_used_domain(&mut brawl, 3, 42);
        transfer::share_object(cfg);
        transfer::share_object(brawl);
    }
}
