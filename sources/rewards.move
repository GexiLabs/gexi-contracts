module gexi_economy::rewards {
    use std::bcs;
    use std::string::String;
    use std::vector;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::dynamic_field;
    use sui::ed25519;
    use sui::event;
    use sui::object::UID;
    use sui::vec_set::{Self, VecSet};

    const E_VOUCHER_SIGNATURE_INVALID: u64 = 100;
    const E_VOUCHER_EXPIRED: u64 = 102;
    const E_VOUCHER_NONCE_USED: u64 = 103;
    const E_AUTO_PAYOUT_ALREADY_PROCESSED: u64 = 104;
    const E_LEGACY_VOUCHER_DISABLED: u64 = 105;
    const E_REWARD_ALREADY_CLAIMED: u64 = 106;
    const E_ADMIN_WITHDRAW_DISABLED: u64 = 107;
    const E_LEGACY_AUTO_PAYOUT_DISABLED: u64 = 108;
    const E_LEGACY_VERIFIER_ROTATION_DISABLED: u64 = 109;
    const E_VERIFIER_KEY_INVALID: u64 = 110;
    const E_RECOVERY_REQUIRES_PAUSE: u64 = 111;
    const E_RECOVERY_NOT_SCHEDULED: u64 = 112;
    const E_RECOVERY_DELAY_ACTIVE: u64 = 113;
    const E_RECOVERY_ALREADY_SCHEDULED: u64 = 114;
    const E_RECOVERY_EMPTY: u64 = 115;
    const E_LEGACY_RECOVERY_DISABLED: u64 = 116;
    const E_RECOVERY_BALANCE_CHANGED: u64 = 117;
    const E_REWARD_CAP_CONFIG_MISMATCH: u64 = 118;
    const E_LEGACY_UNBOUND_CAP_DISABLED: u64 = 119;
    const E_REWARDS_PAUSED: u64 = 0;
    const RECOVERY_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1000;
    const NONCE_DOMAIN_MANUAL_CLAIM: u8 = 1;
    const NONCE_DOMAIN_AUTO_PAYOUT: u8 = 2;

    public struct RewardClaimKey has copy, drop, store {
        user: address,
        task_id: String,
    }

    /// Dynamic-field key for scalable nonce replay protection. `used_nonces`
    /// remains in RewardConfig only for compatibility with already-created
    /// configs; new claims no longer append to that O(N) VecSet.
    public struct RewardNonceKey has copy, drop, store {
        nonce_key: u64,
    }

    /// Current replay key. Domain separation lets independent signed flows use
    /// the same numeric nonce without colliding, while legacy markers remain
    /// globally reserved for backward-compatible replay protection.
    public struct RewardNonceDomainKey has copy, drop, store {
        domain: u8,
        nonce_key: u64,
    }

    public struct RewardRecoveryKey has copy, drop, store {}

    /// Current recovery plans snapshot both the recipient and the exact vault
    /// balance. This prevents the recovery authority from changing either at
    /// execution time after the seven-day review window has started.
    public struct RewardRecoveryPlanKey has copy, drop, store {}

    public struct RewardAdminCapV2MintedKey has copy, drop, store {}
    public struct RewardPayoutCapV2MintedKey has copy, drop, store {}
    public struct RewardRecoveryCapV2MintedKey has copy, drop, store {}

    public struct RewardRecoveryPlan has copy, drop, store {
        unlock_ms: u64,
        to: address,
        amount_mist: u64,
    }

    fun assert_unexpired(expiry_ms: u64, clock: &Clock) {
        assert!(expiry_ms > clock::timestamp_ms(clock), E_VOUCHER_EXPIRED);
    }

    fun mark_nonce_used<T>(cfg: &mut RewardConfig<T>, domain: u8, nonce_key: u64) {
        // Any nonce consumed by legacy code remains globally reserved.
        assert!(!vec_set::contains(&cfg.used_nonces, &nonce_key), E_VOUCHER_NONCE_USED);
        assert!(
            !dynamic_field::exists_with_type<RewardNonceKey, bool>(
                &cfg.id,
                RewardNonceKey { nonce_key },
            ),
            E_VOUCHER_NONCE_USED
        );
        let key = RewardNonceDomainKey { domain, nonce_key };
        assert!(
            !dynamic_field::exists_with_type<RewardNonceDomainKey, bool>(&cfg.id, key),
            E_VOUCHER_NONCE_USED,
        );
        dynamic_field::add(&mut cfg.id, key, true);
    }

    /// Consume the economic reward entitlement independently from the signed
    /// transaction nonce. Manual claims and automatic payouts must both use
    /// this same typed key so issuing two valid authorizations for one logical
    /// reward cannot pay it twice.
    fun mark_entitlement_used<T>(cfg: &mut RewardConfig<T>, user: address, entitlement_id: String) {
        let claim_key = RewardClaimKey { user, task_id: entitlement_id };
        assert!(
            !dynamic_field::exists_with_type<RewardClaimKey, bool>(&cfg.id, claim_key),
            E_REWARD_ALREADY_CLAIMED,
        );
        dynamic_field::add(&mut cfg.id, claim_key, true);
    }

    #[allow(lint(public_entry))]
    public entry fun claim_reward_v3<T>(
        cfg: &mut RewardConfig<T>,
        task_id: String,
        amount_mist: u64,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_not_paused(cfg);
        assert_unexpired(expiry_ms, clock);
        let user = tx_context::sender(ctx);
        let mut message = b"GEXI_REWARD_V3";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&user));
        vector::append(&mut message, bcs::to_bytes(&task_id));
        vector::append(&mut message, bcs::to_bytes(&amount_mist));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(ed25519::ed25519_verify(&signature, &cfg.verifier_pubkey, &message), E_VOUCHER_SIGNATURE_INVALID);
        mark_entitlement_used(cfg, user, task_id);
        mark_nonce_used(cfg, NONCE_DOMAIN_MANUAL_CLAIM, nonce_key);
        let out = coin::from_balance(balance::split(&mut cfg.vault, amount_mist), ctx);
        transfer::public_transfer(out, user);
        event::emit(RewardClaimed { user, task_id, amount_mist, nonce_key });
        event::emit(RewardClaimedV2 {
            config_id: object::id_address(cfg),
            user,
            entitlement_id: task_id,
            amount_mist,
            nonce_key,
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
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        claim_reward_v2(&mut cfg, std::string::utf8(b"fixture"), 0, 0, 0, vector[], &mut ctx);
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

    #[test]
    #[allow(lint(abort_without_constant))]
    fun nonce_marker_does_not_grow_legacy_vecset() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        mark_nonce_used(&mut cfg, NONCE_DOMAIN_MANUAL_CLAIM, 42);
        assert!(vec_set::length(&cfg.used_nonces) == 0, 999);
        assert!(
            dynamic_field::exists_with_type<RewardNonceDomainKey, bool>(
                &cfg.id,
                RewardNonceDomainKey { domain: NONCE_DOMAIN_MANUAL_CLAIM, nonce_key: 42 },
            ),
            998,
        );
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_VOUCHER_NONCE_USED)]
    fun nonce_replay_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        mark_nonce_used(&mut cfg, NONCE_DOMAIN_MANUAL_CLAIM, 7);
        mark_nonce_used(&mut cfg, NONCE_DOMAIN_MANUAL_CLAIM, 7);
        transfer::share_object(cfg);
    }

    #[test]
    fun nonce_domains_allow_same_numeric_nonce() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        mark_nonce_used(&mut cfg, NONCE_DOMAIN_MANUAL_CLAIM, 77);
        mark_nonce_used(&mut cfg, NONCE_DOMAIN_AUTO_PAYOUT, 77);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_VOUCHER_NONCE_USED)]
    fun legacy_vecset_nonce_remains_rejected_after_upgrade() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::singleton(9), paused: false,
        };
        mark_nonce_used(&mut cfg, NONCE_DOMAIN_MANUAL_CLAIM, 9);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_VOUCHER_NONCE_USED)]
    fun legacy_dynamic_nonce_remains_rejected_after_upgrade() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        dynamic_field::add(&mut cfg.id, RewardNonceKey { nonce_key: 11 }, true);
        mark_nonce_used(&mut cfg, NONCE_DOMAIN_AUTO_PAYOUT, 11);
        transfer::share_object(cfg);
    }

    public struct RewardsAdminCap has key, store {
        id: UID,
    }

    /// Separate settlement authority. Holding RewardsAdminCap alone is not
    /// sufficient to transfer vault assets through automatic payouts.
    public struct RewardsPayoutCap has key, store {
        id: UID,
    }

    /// Offline incident-recovery authority. It cannot move funds immediately:
    /// the config must be paused and a fixed on-chain delay must first elapse.
    public struct RewardsRecoveryCap has key, store {
        id: UID,
    }

    /// Upgrade-safe config-scoped authorities. Legacy root caps remain valid
    /// only for creating configs and minting these bound capabilities.
    public struct RewardsAdminCapV2 has key, store {
        id: UID,
        config_id: address,
    }

    public struct RewardsPayoutCapV2 has key, store {
        id: UID,
        config_id: address,
    }

    public struct RewardsRecoveryCapV2 has key, store {
        id: UID,
        config_id: address,
    }

    public struct REWARDS has drop {}

    public struct RewardConfig<phantom T> has key {
        id: UID,
        vault: Balance<T>,
        verifier_pubkey: vector<u8>,
        used_nonces: VecSet<u64>,
        paused: bool,
    }

    public struct RewardClaimed has copy, drop {
        user: address,
        task_id: String,
        amount_mist: u64,
        nonce_key: u64,
    }

    public struct RewardClaimedV2 has copy, drop {
        config_id: address,
        user: address,
        entitlement_id: String,
        amount_mist: u64,
        nonce_key: u64,
    }

    public struct RewardAutoPaid has copy, drop {
        user: address,
        payout_id: String,
        amount_mist: u64,
    }

    public struct RewardAutoPaidV2 has copy, drop {
        config_id: address,
        user: address,
        payout_id: String,
        entitlement_id: String,
        amount_mist: u64,
    }

    public struct RewardVaultRecovered has copy, drop {
        to: address,
        amount_mist: u64,
    }

    public struct RewardVaultRecoveryScheduledV2 has copy, drop {
        config_id: address,
        to: address,
        amount_mist: u64,
        unlock_ms: u64,
    }

    public struct RewardVaultRecoveryCancelledV2 has copy, drop {
        config_id: address,
        to: address,
        amount_mist: u64,
        unlock_ms: u64,
    }

    public struct RewardVaultRecoveredV2 has copy, drop {
        config_id: address,
        to: address,
        amount_mist: u64,
    }

    fun assert_not_paused<T>(cfg: &RewardConfig<T>) {
        assert!(!cfg.paused, E_REWARDS_PAUSED);
    }

    fun assert_admin_binding<T>(cap: &RewardsAdminCapV2, cfg: &RewardConfig<T>) {
        assert!(cap.config_id == object::id_address(cfg), E_REWARD_CAP_CONFIG_MISMATCH);
    }

    public(package) fun assert_admin_binding_v2<T>(cap: &RewardsAdminCapV2, cfg: &RewardConfig<T>) {
        assert_admin_binding(cap, cfg);
    }

    fun assert_payout_binding<T>(cap: &RewardsPayoutCapV2, cfg: &RewardConfig<T>) {
        assert!(cap.config_id == object::id_address(cfg), E_REWARD_CAP_CONFIG_MISMATCH);
    }

    fun assert_recovery_binding<T>(cap: &RewardsRecoveryCapV2, cfg: &RewardConfig<T>) {
        assert!(cap.config_id == object::id_address(cfg), E_REWARD_CAP_CONFIG_MISMATCH);
    }

    fun init(_witness: REWARDS, ctx: &mut TxContext) {
        let admin_cap = RewardsAdminCap { id: object::new(ctx) };
        let payout_cap = RewardsPayoutCap { id: object::new(ctx) };
        let recovery_cap = RewardsRecoveryCap { id: object::new(ctx) };
        let sender = tx_context::sender(ctx);
        transfer::transfer(admin_cap, sender);
        transfer::transfer(payout_cap, sender);
        transfer::transfer(recovery_cap, sender);
    }

    /// Permanently consume legacy protocol-wide roots after every intended
    /// config has received its bound V2 authority. These functions mint
    /// nothing and return no replacement capability.
    #[allow(lint(public_entry))]
    public entry fun retire_legacy_rewards_admin_cap(cap: RewardsAdminCap) {
        let RewardsAdminCap { id } = cap;
        id.delete();
    }

    #[allow(lint(public_entry))]
    public entry fun retire_legacy_rewards_payout_cap(cap: RewardsPayoutCap) {
        let RewardsPayoutCap { id } = cap;
        id.delete();
    }

    #[allow(lint(public_entry))]
    public entry fun retire_legacy_rewards_recovery_cap(cap: RewardsRecoveryCap) {
        let RewardsRecoveryCap { id } = cap;
        id.delete();
    }

    #[test_only]
    public fun rewards_admin_cap_for_testing(ctx: &mut TxContext): RewardsAdminCap {
        RewardsAdminCap { id: object::new(ctx) }
    }

    #[test_only]
    public fun destroy_rewards_admin_cap_for_testing(cap: RewardsAdminCap) {
        let RewardsAdminCap { id } = cap;
        id.delete();
    }

    #[test_only]
    public fun rewards_payout_cap_for_testing(ctx: &mut TxContext): RewardsPayoutCap {
        RewardsPayoutCap { id: object::new(ctx) }
    }

    #[test_only]
    public fun destroy_rewards_payout_cap_for_testing(cap: RewardsPayoutCap) {
        let RewardsPayoutCap { id } = cap;
        id.delete();
    }

    #[test_only]
    public fun rewards_admin_cap_v2_for_testing<T>(
        cfg: &RewardConfig<T>,
        ctx: &mut TxContext,
    ): RewardsAdminCapV2 {
        RewardsAdminCapV2 { id: object::new(ctx), config_id: object::id_address(cfg) }
    }

    #[test_only]
    public fun destroy_rewards_admin_cap_v2_for_testing(cap: RewardsAdminCapV2) {
        let RewardsAdminCapV2 { id, config_id: _ } = cap;
        id.delete();
    }

    #[test_only]
    public fun reward_vault_balance_for_testing<T>(cfg: &RewardConfig<T>): u64 {
        balance::value(&cfg.vault)
    }

    #[test_only]
    public fun reward_config_for_testing(ctx: &mut TxContext): RewardConfig<u8> {
        RewardConfig<u8> {
            id: object::new(ctx),
            vault: balance::zero(),
            verifier_pubkey: vector[],
            used_nonces: vec_set::empty(),
            paused: false,
        }
    }

    #[test_only]
    public fun share_reward_config_for_testing(cfg: RewardConfig<u8>) {
        transfer::share_object(cfg);
    }

    #[test]
    fun init_bootstraps_separate_reward_caps() {
        let deployer = @0xA11CE;
        let mut scenario = sui::test_scenario::begin(deployer);
        init(REWARDS {}, scenario.ctx());
        scenario.next_tx(deployer);
        let admin_cap = scenario.take_from_sender<RewardsAdminCap>();
        let payout_cap = scenario.take_from_sender<RewardsPayoutCap>();
        let recovery_cap = scenario.take_from_sender<RewardsRecoveryCap>();
        scenario.return_to_sender(admin_cap);
        scenario.return_to_sender(payout_cap);
        scenario.return_to_sender(recovery_cap);
        scenario.end();
    }

    #[test]
    fun legacy_reward_roots_can_be_retired_without_replacement() {
        let mut ctx = tx_context::dummy();
        retire_legacy_rewards_admin_cap(RewardsAdminCap { id: object::new(&mut ctx) });
        retire_legacy_rewards_payout_cap(RewardsPayoutCap { id: object::new(&mut ctx) });
        retire_legacy_rewards_recovery_cap(RewardsRecoveryCap { id: object::new(&mut ctx) });
    }

    #[test]
    #[expected_failure(abort_code = E_RECOVERY_REQUIRES_PAUSE)]
    fun reward_recovery_requires_pause() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        let recovery = RewardsRecoveryCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&cfg),
        };
        let clock = clock::create_for_testing(&mut ctx);
        schedule_paused_vault_recovery_v3(&recovery, &mut cfg, @0x9, &clock);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        let RewardsRecoveryCapV2 { id, config_id: _ } = recovery;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_RECOVERY_DELAY_ACTIVE)]
    fun reward_recovery_delay_is_enforced() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: true,
        };
        balance::join(&mut cfg.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        let recovery = RewardsRecoveryCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&cfg),
        };
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 1_000);
        schedule_paused_vault_recovery_v3(&recovery, &mut cfg, @0x9, &clock);
        clock::set_for_testing(&mut clock, 1_000 + RECOVERY_DELAY_MS - 1);
        recover_paused_vault_v3(&recovery, &mut cfg, &clock, &mut ctx);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        let RewardsRecoveryCapV2 { id, config_id: _ } = recovery;
        id.delete();
    }

    #[test]
    fun delayed_reward_recovery_drains_only_paused_vault() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: true,
        };
        balance::join(&mut cfg.vault, coin::into_balance(coin::mint_for_testing<u8>(100, &mut ctx)));
        let recovery = RewardsRecoveryCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&cfg),
        };
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 1_000);
        schedule_paused_vault_recovery_v3(&recovery, &mut cfg, @0x9, &clock);
        clock::set_for_testing(&mut clock, 1_000 + RECOVERY_DELAY_MS);
        recover_paused_vault_v3(&recovery, &mut cfg, &clock, &mut ctx);
        assert!(balance::value(&cfg.vault) == 0, E_RECOVERY_EMPTY);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        let RewardsRecoveryCapV2 { id, config_id: _ } = recovery;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_REWARD_CAP_CONFIG_MISMATCH)]
    fun bound_reward_admin_rejects_other_config() {
        let mut ctx = tx_context::dummy();
        let cfg_a = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        let mut cfg_b = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        let admin = RewardsAdminCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&cfg_a),
        };
        set_paused_v2(&admin, &mut cfg_b, true);
        transfer::share_object(cfg_a);
        transfer::share_object(cfg_b);
        let RewardsAdminCapV2 { id, config_id: _ } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_UNBOUND_CAP_DISABLED)]
    fun legacy_unbound_reward_admin_is_disabled() {
        let mut ctx = tx_context::dummy();
        let admin = RewardsAdminCap { id: object::new(&mut ctx) };
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        set_paused(&admin, &mut cfg, true);
        transfer::share_object(cfg);
        destroy_rewards_admin_cap_for_testing(admin);
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_RECOVERY_DISABLED)]
    fun legacy_reward_recovery_schedule_is_disabled() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: true,
        };
        let recovery = RewardsRecoveryCap { id: object::new(&mut ctx) };
        let clock = clock::create_for_testing(&mut ctx);
        schedule_paused_vault_recovery(&recovery, &mut cfg, &clock);
        clock::destroy_for_testing(clock);
        transfer::share_object(cfg);
        let RewardsRecoveryCap { id } = recovery;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_REWARDS_PAUSED)]
    fun paused_reward_vault_rejects_late_funding() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: true,
        };
        let payment = coin::mint_for_testing<u8>(100, &mut ctx);
        fund_vault(&mut cfg, payment);
        transfer::share_object(cfg);
    }



    #[allow(lint(public_entry))]
    public entry fun create_rewards<T>(
        _: &RewardsAdminCap,
        verifier_pubkey: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(vector::length(&verifier_pubkey) == 32, E_VERIFIER_KEY_INVALID);
        let cfg = RewardConfig<T> {
            id: object::new(ctx),
            vault: balance::zero<T>(),
            verifier_pubkey,
            used_nonces: vec_set::empty<u64>(),
            paused: false,
        };
        transfer::share_object(cfg);
    }

    /// Mint config-scoped authorities for an already-created RewardConfig.
    /// Each legacy root may only mint the matching authority domain.
    #[allow(lint(public_entry))]
    public entry fun bind_rewards_admin_v2<T>(
        _: &RewardsAdminCap,
        cfg: &mut RewardConfig<T>,
        ctx: &mut TxContext,
    ) {
        let key = RewardAdminCapV2MintedKey {};
        assert!(
            !dynamic_field::exists_with_type<RewardAdminCapV2MintedKey, bool>(&cfg.id, key),
            E_LEGACY_UNBOUND_CAP_DISABLED,
        );
        dynamic_field::add(&mut cfg.id, key, true);
        transfer::transfer(
            RewardsAdminCapV2 { id: object::new(ctx), config_id: object::id_address(cfg) },
            tx_context::sender(ctx),
        );
    }

    #[allow(lint(public_entry))]
    public entry fun bind_rewards_payout_v2<T>(
        _: &RewardsPayoutCap,
        cfg: &mut RewardConfig<T>,
        ctx: &mut TxContext,
    ) {
        let key = RewardPayoutCapV2MintedKey {};
        assert!(
            !dynamic_field::exists_with_type<RewardPayoutCapV2MintedKey, bool>(&cfg.id, key),
            E_LEGACY_UNBOUND_CAP_DISABLED,
        );
        dynamic_field::add(&mut cfg.id, key, true);
        transfer::transfer(
            RewardsPayoutCapV2 { id: object::new(ctx), config_id: object::id_address(cfg) },
            tx_context::sender(ctx),
        );
    }

    #[allow(lint(public_entry))]
    public entry fun bind_rewards_recovery_v2<T>(
        _: &RewardsRecoveryCap,
        cfg: &mut RewardConfig<T>,
        ctx: &mut TxContext,
    ) {
        let key = RewardRecoveryCapV2MintedKey {};
        assert!(
            !dynamic_field::exists_with_type<RewardRecoveryCapV2MintedKey, bool>(&cfg.id, key),
            E_LEGACY_UNBOUND_CAP_DISABLED,
        );
        dynamic_field::add(&mut cfg.id, key, true);
        transfer::transfer(
            RewardsRecoveryCapV2 { id: object::new(ctx), config_id: object::id_address(cfg) },
            tx_context::sender(ctx),
        );
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun claim_reward<T>(
        cfg: &mut RewardConfig<T>,
        task_id: String,
        amount_mist: u64,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        ctx: &mut TxContext,
    ) {
        // Kept only for upgrade compatibility; current claims use v3.
        abort E_LEGACY_VOUCHER_DISABLED
    }

    /// Domain-separated claim format. New issuers must use this entry point;
    /// the legacy function remains only for package-upgrade compatibility.
    #[allow(unused_variable, lint(public_entry))]
    public entry fun claim_reward_v2<T>(
        cfg: &mut RewardConfig<T>,
        task_id: String,
        amount_mist: u64,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        ctx: &mut TxContext,
    ) {
        // Kept only for upgrade compatibility; current claims use v3.
        abort E_LEGACY_VOUCHER_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun fund_vault<T>(cfg: &mut RewardConfig<T>, coins: Coin<T>) {
        // A paused vault can have a reviewed recovery snapshot in flight. New
        // deposits during that window would otherwise bypass the seven-day
        // review delay and be swept with the already-scheduled recovery.
        assert_not_paused(cfg);
        balance::join(&mut cfg.vault, coin::into_balance(coins));
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun set_paused<T>(_: &RewardsAdminCap, cfg: &mut RewardConfig<T>, paused: bool) {
        abort E_LEGACY_UNBOUND_CAP_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun set_paused_v2<T>(cap: &RewardsAdminCapV2, cfg: &mut RewardConfig<T>, paused: bool) {
        assert_admin_binding(cap, cfg);
        cfg.paused = paused;
        if (!paused && dynamic_field::exists_with_type<RewardRecoveryKey, u64>(&cfg.id, RewardRecoveryKey {})) {
            dynamic_field::remove<RewardRecoveryKey, u64>(&mut cfg.id, RewardRecoveryKey {});
        };
        if (!paused && dynamic_field::exists_with_type<RewardRecoveryPlanKey, RewardRecoveryPlan>(
            &cfg.id,
            RewardRecoveryPlanKey {},
        )) {
            let plan = dynamic_field::remove<RewardRecoveryPlanKey, RewardRecoveryPlan>(
                &mut cfg.id,
                RewardRecoveryPlanKey {},
            );
            event::emit(RewardVaultRecoveryCancelledV2 {
                config_id: object::id_address(cfg),
                to: plan.to,
                amount_mist: plan.amount_mist,
                unlock_ms: plan.unlock_ms,
            });
        };
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun schedule_paused_vault_recovery<T>(
        _: &RewardsRecoveryCap,
        cfg: &mut RewardConfig<T>,
        clock: &Clock,
    ) {
        // Retained for package-upgrade ABI compatibility. V1 did not bind the
        // recipient or the amount being reviewed during the delay window.
        abort E_LEGACY_RECOVERY_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun schedule_paused_vault_recovery_v2<T>(
        _: &RewardsRecoveryCap,
        cfg: &mut RewardConfig<T>,
        to: address,
        clock: &Clock,
    ) {
        abort E_LEGACY_UNBOUND_CAP_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun schedule_paused_vault_recovery_v3<T>(
        cap: &RewardsRecoveryCapV2,
        cfg: &mut RewardConfig<T>,
        to: address,
        clock: &Clock,
    ) {
        assert_recovery_binding(cap, cfg);
        assert!(cfg.paused, E_RECOVERY_REQUIRES_PAUSE);
        assert!(
            !dynamic_field::exists_with_type<RewardRecoveryKey, u64>(&cfg.id, RewardRecoveryKey {})
                && !dynamic_field::exists_with_type<RewardRecoveryPlanKey, RewardRecoveryPlan>(
                    &cfg.id,
                    RewardRecoveryPlanKey {},
                ),
            E_RECOVERY_ALREADY_SCHEDULED,
        );
        let amount_mist = balance::value(&cfg.vault);
        assert!(amount_mist > 0, E_RECOVERY_EMPTY);
        let unlock_ms = clock::timestamp_ms(clock) + RECOVERY_DELAY_MS;
        dynamic_field::add(
            &mut cfg.id,
            RewardRecoveryPlanKey {},
            RewardRecoveryPlan { unlock_ms, to, amount_mist },
        );
        event::emit(RewardVaultRecoveryScheduledV2 {
            config_id: object::id_address(cfg),
            to,
            amount_mist,
            unlock_ms,
        });
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun cancel_paused_vault_recovery<T>(_: &RewardsAdminCap, cfg: &mut RewardConfig<T>) {
        abort E_LEGACY_UNBOUND_CAP_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun cancel_paused_vault_recovery_v2<T>(
        cap: &RewardsAdminCapV2,
        cfg: &mut RewardConfig<T>,
    ) {
        assert_admin_binding(cap, cfg);
        let key = RewardRecoveryKey {};
        if (dynamic_field::exists_with_type<RewardRecoveryKey, u64>(&cfg.id, key)) {
            dynamic_field::remove<RewardRecoveryKey, u64>(&mut cfg.id, key);
        };
        let plan_key = RewardRecoveryPlanKey {};
        if (dynamic_field::exists_with_type<RewardRecoveryPlanKey, RewardRecoveryPlan>(&cfg.id, plan_key)) {
            let plan = dynamic_field::remove<RewardRecoveryPlanKey, RewardRecoveryPlan>(&mut cfg.id, plan_key);
            event::emit(RewardVaultRecoveryCancelledV2 {
                config_id: object::id_address(cfg),
                to: plan.to,
                amount_mist: plan.amount_mist,
                unlock_ms: plan.unlock_ms,
            });
        };
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun recover_paused_vault<T>(
        _: &RewardsRecoveryCap,
        cfg: &mut RewardConfig<T>,
        to: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Retained for package-upgrade ABI compatibility. V2 executes only the
        // recipient and amount committed when the recovery was scheduled.
        abort E_LEGACY_RECOVERY_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun recover_paused_vault_v2<T>(
        _: &RewardsRecoveryCap,
        cfg: &mut RewardConfig<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        abort E_LEGACY_UNBOUND_CAP_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun recover_paused_vault_v3<T>(
        cap: &RewardsRecoveryCapV2,
        cfg: &mut RewardConfig<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_recovery_binding(cap, cfg);
        assert!(cfg.paused, E_RECOVERY_REQUIRES_PAUSE);
        let key = RewardRecoveryPlanKey {};
        assert!(
            dynamic_field::exists_with_type<RewardRecoveryPlanKey, RewardRecoveryPlan>(&cfg.id, key),
            E_RECOVERY_NOT_SCHEDULED,
        );
        let plan = *dynamic_field::borrow<RewardRecoveryPlanKey, RewardRecoveryPlan>(&cfg.id, key);
        assert!(clock::timestamp_ms(clock) >= plan.unlock_ms, E_RECOVERY_DELAY_ACTIVE);
        assert!(balance::value(&cfg.vault) == plan.amount_mist, E_RECOVERY_BALANCE_CHANGED);
        dynamic_field::remove<RewardRecoveryPlanKey, RewardRecoveryPlan>(&mut cfg.id, key);
        let out = coin::from_balance(balance::split(&mut cfg.vault, plan.amount_mist), ctx);
        transfer::public_transfer(out, plan.to);
        event::emit(RewardVaultRecovered { to: plan.to, amount_mist: plan.amount_mist });
        event::emit(RewardVaultRecoveredV2 {
            config_id: object::id_address(cfg),
            to: plan.to,
            amount_mist: plan.amount_mist,
        });
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun set_verifier<T>(
        _: &RewardsAdminCap,
        cfg: &mut RewardConfig<T>,
        verifier_pubkey: vector<u8>,
    ) {
        // The verifier is immutable after config creation. Rotation requires a
        // reviewed package/governance change rather than hot admin authority.
        abort E_LEGACY_VERIFIER_ROTATION_DISABLED
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_VERIFIER_ROTATION_DISABLED)]
    fun reward_admin_alone_cannot_rotate_verifier() {
        let mut ctx = tx_context::dummy();
        let admin = RewardsAdminCap { id: object::new(&mut ctx) };
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        set_verifier(&admin, &mut cfg, vector[]);
        transfer::share_object(cfg);
        destroy_rewards_admin_cap_for_testing(admin);
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_withdraw<T>(
        _: &RewardsAdminCap,
        cfg: &mut RewardConfig<T>,
        amount: u64,
        to: address,
        ctx: &mut TxContext,
    ) {
        // A reward config cannot know which still-valid signed vouchers exist
        // off-chain, so it cannot prove an amount is surplus. Keep the entry
        // point for ABI compatibility but disallow arbitrary custody drains.
        abort E_ADMIN_WITHDRAW_DISABLED
    }

    #[test]
    #[expected_failure(abort_code = E_ADMIN_WITHDRAW_DISABLED)]
    fun reward_admin_cannot_withdraw_voucher_backing() {
        let mut ctx = tx_context::dummy();
        let admin = RewardsAdminCap { id: object::new(&mut ctx) };
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        admin_withdraw(&admin, &mut cfg, 0, @0x1, &mut ctx);
        transfer::share_object(cfg);
        destroy_rewards_admin_cap_for_testing(admin);
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_auto_payout<T>(
        _: &RewardsAdminCap,
        cfg: &mut RewardConfig<T>,
        payout_id: String,
        amount: u64,
        to: address,
        ctx: &mut TxContext,
    ) {
        // Retained for ABI compatibility. A single config-admin capability
        // must not also be an arbitrary vault transfer capability.
        abort E_LEGACY_AUTO_PAYOUT_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_auto_payout_v2<T>(
        _: &RewardsPayoutCap,
        cfg: &mut RewardConfig<T>,
        payout_id: String,
        amount: u64,
        to: address,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Retained for package-upgrade ABI compatibility. V3 carries an
        // explicit economic entitlement ID shared with manual claims.
        abort E_LEGACY_AUTO_PAYOUT_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_auto_payout_v3<T>(
        _: &RewardsPayoutCap,
        cfg: &mut RewardConfig<T>,
        payout_id: String,
        entitlement_id: String,
        amount: u64,
        to: address,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        abort E_LEGACY_UNBOUND_CAP_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun admin_auto_payout_v4<T>(
        cap: &RewardsPayoutCapV2,
        cfg: &mut RewardConfig<T>,
        payout_id: String,
        entitlement_id: String,
        amount: u64,
        to: address,
        nonce_key: u64,
        expiry_ms: u64,
        signature: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_payout_binding(cap, cfg);
        assert_not_paused(cfg);
        assert_unexpired(expiry_ms, clock);
        let mut message = b"GEXI_REWARD_AUTO_V2";
        vector::append(&mut message, bcs::to_bytes(&object::id_address(cfg)));
        vector::append(&mut message, bcs::to_bytes(&payout_id));
        vector::append(&mut message, bcs::to_bytes(&entitlement_id));
        vector::append(&mut message, bcs::to_bytes(&to));
        vector::append(&mut message, bcs::to_bytes(&amount));
        vector::append(&mut message, bcs::to_bytes(&nonce_key));
        vector::append(&mut message, bcs::to_bytes(&expiry_ms));
        assert!(
            ed25519::ed25519_verify(&signature, &cfg.verifier_pubkey, &message),
            E_VOUCHER_SIGNATURE_INVALID,
        );
        assert!(
            !dynamic_field::exists_with_type<String, bool>(&cfg.id, payout_id),
            E_AUTO_PAYOUT_ALREADY_PROCESSED
        );

        mark_entitlement_used(cfg, to, entitlement_id);
        dynamic_field::add(&mut cfg.id, payout_id, true);
        mark_nonce_used(cfg, NONCE_DOMAIN_AUTO_PAYOUT, nonce_key);

        let out = coin::from_balance(balance::split(&mut cfg.vault, amount), ctx);
        transfer::public_transfer(out, to);

        event::emit(RewardAutoPaid {
            user: to,
            payout_id,
            amount_mist: amount,
        });
        event::emit(RewardAutoPaidV2 {
            config_id: object::id_address(cfg),
            user: to,
            payout_id,
            entitlement_id,
            amount_mist: amount,
        });
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_AUTO_PAYOUT_DISABLED)]
    fun reward_admin_cap_cannot_auto_payout() {
        let mut ctx = tx_context::dummy();
        let admin = RewardsAdminCap { id: object::new(&mut ctx) };
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        admin_auto_payout(
            &admin,
            &mut cfg,
            std::string::utf8(b"payout"),
            0,
            @0x1,
            &mut ctx,
        );
        transfer::share_object(cfg);
        destroy_rewards_admin_cap_for_testing(admin);
    }

    #[test]
    #[expected_failure(abort_code = E_REWARD_ALREADY_CLAIMED)]
    fun shared_entitlement_blocks_second_payment_path() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        let entitlement_id = std::string::utf8(b"task-42");
        mark_entitlement_used(&mut cfg, @0xA, entitlement_id);
        mark_entitlement_used(&mut cfg, @0xA, entitlement_id);
        transfer::share_object(cfg);
    }

    #[test]
    fun same_entitlement_id_is_independent_per_user() {
        let mut ctx = tx_context::dummy();
        let mut cfg = RewardConfig<u8> {
            id: object::new(&mut ctx), vault: balance::zero(),
            verifier_pubkey: vector[], used_nonces: vec_set::empty(), paused: false,
        };
        let entitlement_id = std::string::utf8(b"task-42");
        mark_entitlement_used(&mut cfg, @0xA, entitlement_id);
        mark_entitlement_used(&mut cfg, @0xB, entitlement_id);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_UNBOUND_CAP_DISABLED)]
    fun reward_admin_v2_can_only_be_minted_once_per_config() {
        let mut ctx = tx_context::dummy();
        let root = RewardsAdminCap { id: object::new(&mut ctx) };
        let mut cfg = reward_config_for_testing(&mut ctx);
        bind_rewards_admin_v2(&root, &mut cfg, &mut ctx);
        bind_rewards_admin_v2(&root, &mut cfg, &mut ctx);
        transfer::share_object(cfg);
        destroy_rewards_admin_cap_for_testing(root);
    }
}
