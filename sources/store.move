module gexi_economy::store {
    use gexi_economy::rewards::{Self, RewardConfig, RewardsAdminCapV2};
    use std::string::String;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::coin_registry::{Self, Currency};
    use sui::dynamic_field;
    use sui::event;
    use sui::object::UID;

    const E_PACK_NOT_FOUND: u64 = 1;
    const E_PRICE_MISMATCH: u64 = 2;
    const E_INVALID_PACK_CONFIG: u64 = 4;
    const E_LEGACY_BUY_DISABLED: u64 = 5;
    const E_ORDER_ALREADY_PROCESSED: u64 = 6;
    const E_GEMS_MISMATCH: u64 = 7;
    const E_STORE_PAUSED: u64 = 8;
    const E_ADMIN_WITHDRAW_DISABLED: u64 = 9;
    const E_LEGACY_TREASURY_BURN_DISABLED: u64 = 10;
    const E_INVALID_ORDER_ID: u64 = 11;
    const E_BURN_ALREADY_PROCESSED: u64 = 13;
    const E_LEGACY_ADMIN_BURN_DISABLED: u64 = 14;
    const E_STORE_BURN_DISABLED: u64 = 16;
    const E_EVENT_FUNDING_ALREADY_PROCESSED: u64 = 17;
    const E_INVALID_EVENT_FUNDING: u64 = 18;
    const E_STORE_CAP_CONFIG_MISMATCH: u64 = 19;
    const E_EVENT_ROUTE_MISMATCH: u64 = 20;
    const E_LEGACY_UNBOUND_ADMIN_DISABLED: u64 = 21;

    /// GEXI uses 9 decimals. Public pack prices must stay on whole-GEXI ticks
    /// so off-chain quotes cannot silently drift into fractional base units.
    const PRICE_TICK_MIST: u64 = 1_000_000_000;
    const MAX_REFERENCE_BYTES: u64 = 128;

    public struct StoreAdminCap has key, store {
        id: UID,
    }

    /// Separate destructive authority for irreversible Store-vault burns.
    /// Compromise of StoreAdminCap alone must not be enough to destroy funds.
    public struct StoreBurnCap has key, store {
        id: UID,
    }

    public struct StoreAdminCapV2 has key, store {
        id: UID,
        config_id: address,
    }

    /// Dedicated Store -> Rewards routing authority. It is bound to both
    /// shared objects so a Store admin cannot redirect proceeds at call time.
    public struct StoreEventFundingCapV2 has key, store {
        id: UID,
        store_config_id: address,
        reward_config_id: address,
    }

    public struct STORE has drop {}

    public struct StoreConfig<phantom T> has key {
        id: UID,
        vault: Balance<T>,
        pack_1_price: u64,
        pack_1_gems: u64,
        pack_2_price: u64,
        pack_2_gems: u64,
        pack_3_price: u64,
        pack_3_gems: u64,
        pack_4_price: u64,
        pack_4_gems: u64,
        pack_5_price: u64,
        pack_5_gems: u64,
        pack_6_price: u64,
        pack_6_gems: u64,
        paused: bool,
    }

    #[allow(unused_field)]
    public struct PackPurchased has copy, drop {
        buyer: address,
        pack_id: u8,
        amount_gexi: u64,
        gem_amount: u64,
        order_id: String,
    }

    /// Configuration-bound purchase event. `config_id` binds settlement evidence to
    /// the canonical StoreConfig object expected by the application.
    public struct PackPurchasedV2 has copy, drop {
        config_id: address,
        buyer: address,
        pack_id: u8,
        amount_gexi: u64,
        gem_amount: u64,
        order_id: String,
    }

    public struct StoreVaultBurned has copy, drop {
        amount_mist: u64,
        source_ref: String,
    }

    public struct StoreVaultBurnedV2 has copy, drop {
        config_id: address,
        amount_mist: u64,
        source_ref: String,
    }

    /// A finalized paid developer-game play settles its nominal Ticket value
    /// atomically: 20% moves into the developer-revenue custody address and
    /// the remaining 80% is destroyed.
    public struct StoreDeveloperTicketRevenueSettled has copy, drop {
        config_id: address,
        developer_revenue_recipient: address,
        ticket_count: u64,
        gross_amount_mist: u64,
        developer_share_mist: u64,
        burn_mist: u64,
        source_ref: String,
    }

    public struct StoreOrderKey has copy, drop, store {
        order_id: String,
    }

    /// Buyer-scoped replay key used by the current purchase path. Keep the
    /// legacy key type unchanged so package upgrades do not require mutating a
    /// previously published struct layout.
    public struct StoreOrderKeyV2 has copy, drop, store {
        buyer: address,
        order_id: String,
    }

    public struct StoreBurnKey has copy, drop, store {
        source_ref: String,
    }

    public struct StoreEventFundingKey has copy, drop, store {
        source_ref: String,
    }

    public struct StoreAdminCapV2MintedKey has copy, drop, store {}
    public struct StoreEventRouteKey has copy, drop, store {}

    public struct StoreEventTreasuryFunded has copy, drop {
        config_id: address,
        reward_config_id: address,
        amount_mist: u64,
        source_ref: String,
    }

    fun pack_params<T>(cfg: &StoreConfig<T>, pack_id: u8): (u64, u64) {
        if (pack_id == 1) return (cfg.pack_1_price, cfg.pack_1_gems);
        if (pack_id == 2) return (cfg.pack_2_price, cfg.pack_2_gems);
        if (pack_id == 3) return (cfg.pack_3_price, cfg.pack_3_gems);
        if (pack_id == 4) return (cfg.pack_4_price, cfg.pack_4_gems);
        if (pack_id == 5) return (cfg.pack_5_price, cfg.pack_5_gems);
        if (pack_id == 6) return (cfg.pack_6_price, cfg.pack_6_gems);
        abort E_PACK_NOT_FOUND
    }

    fun assert_not_paused<T>(cfg: &StoreConfig<T>) {
        assert!(!cfg.paused, E_STORE_PAUSED);
    }

    fun assert_admin_binding<T>(cap: &StoreAdminCapV2, cfg: &StoreConfig<T>) {
        assert!(cap.config_id == object::id_address(cfg), E_STORE_CAP_CONFIG_MISMATCH);
    }

    fun assert_event_route_binding<T>(
        cap: &StoreEventFundingCapV2,
        cfg: &StoreConfig<T>,
        reward_cfg: &RewardConfig<T>,
    ) {
        assert!(cap.store_config_id == object::id_address(cfg), E_EVENT_ROUTE_MISMATCH);
        assert!(cap.reward_config_id == object::id_address(reward_cfg), E_EVENT_ROUTE_MISMATCH);
    }

    fun assert_valid_reference(value: &String) {
        let len = std::string::length(value);
        assert!(len > 0 && len <= MAX_REFERENCE_BYTES, E_INVALID_ORDER_ID);
    }

    fun assert_valid_public_pack_config(price: u64, gems: u64) {
        assert!(
            price >= PRICE_TICK_MIST
                && price % PRICE_TICK_MIST == 0
                && gems > 0,
            E_INVALID_PACK_CONFIG,
        );
    }

    fun mark_burn_processed<T>(cfg: &mut StoreConfig<T>, source_ref: String) {
        assert_valid_reference(&source_ref);
        let burn_key = StoreBurnKey { source_ref };
        assert!(
            !dynamic_field::exists_with_type<StoreBurnKey, bool>(&cfg.id, burn_key),
            E_BURN_ALREADY_PROCESSED,
        );
        dynamic_field::add(&mut cfg.id, burn_key, true);
    }

    fun mark_event_funding_processed<T>(cfg: &mut StoreConfig<T>, source_ref: String) {
        assert_valid_reference(&source_ref);
        let funding_key = StoreEventFundingKey { source_ref };
        assert!(
            !dynamic_field::exists_with_type<StoreEventFundingKey, bool>(&cfg.id, funding_key),
            E_EVENT_FUNDING_ALREADY_PROCESSED,
        );
        dynamic_field::add(&mut cfg.id, funding_key, true);
    }

    fun mark_order_processed<T>(cfg: &mut StoreConfig<T>, buyer: address, order_id: String) {
        let order_key = StoreOrderKeyV2 { buyer, order_id };
        assert!(
            !dynamic_field::exists_with_type<StoreOrderKeyV2, bool>(&cfg.id, order_key),
            E_ORDER_ALREADY_PROCESSED,
        );
        dynamic_field::add(&mut cfg.id, order_key, true);
    }

    fun init(_witness: STORE, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        transfer::transfer(StoreAdminCap { id: object::new(ctx) }, sender);
        transfer::transfer(StoreBurnCap { id: object::new(ctx) }, sender);
    }

    /// Permanently consume the legacy protocol-wide roots after migration.
    /// No bound or replacement capability is minted by retirement.
    #[allow(lint(public_entry))]
    public entry fun retire_legacy_store_admin_cap(cap: StoreAdminCap) {
        let StoreAdminCap { id } = cap;
        id.delete();
    }

    #[allow(lint(public_entry))]
    public entry fun retire_legacy_store_burn_cap(cap: StoreBurnCap) {
        let StoreBurnCap { id } = cap;
        id.delete();
    }

    #[allow(lint(public_entry))]
    public entry fun create_store<T>(_: &StoreAdminCap, ctx: &mut TxContext) {
        let cfg = StoreConfig<T> {
            id: object::new(ctx),
            vault: balance::zero<T>(),
            pack_1_price: 20_000_000_000,
            pack_1_gems: 5,
            pack_2_price: 75_000_000_000,
            pack_2_gems: 20,
            pack_3_price: 180_000_000_000,
            pack_3_gems: 50,
            pack_4_price: 340_000_000_000,
            pack_4_gems: 100,
            pack_5_price: 800_000_000_000,
            pack_5_gems: 250,
            pack_6_price: 1_500_000_000_000,
            pack_6_gems: 500,
            paused: false,
        };
        transfer::share_object(cfg);
    }

    #[allow(lint(public_entry))]
    public entry fun bind_store_admin_v2<T>(
        _: &StoreAdminCap,
        cfg: &mut StoreConfig<T>,
        ctx: &mut TxContext,
    ) {
        let key = StoreAdminCapV2MintedKey {};
        assert!(
            !dynamic_field::exists_with_type<StoreAdminCapV2MintedKey, bool>(&cfg.id, key),
            E_LEGACY_UNBOUND_ADMIN_DISABLED,
        );
        dynamic_field::add(&mut cfg.id, key, true);
        transfer::transfer(
            StoreAdminCapV2 { id: object::new(ctx), config_id: object::id_address(cfg) },
            tx_context::sender(ctx),
        );
    }

    /// Establish a Store -> Rewards route only when both authority domains
    /// agree on the destination RewardConfig.
    #[allow(lint(public_entry))]
    public entry fun bind_event_funding_v2<T>(
        _: &StoreAdminCap,
        reward_admin: &RewardsAdminCapV2,
        cfg: &mut StoreConfig<T>,
        reward_cfg: &RewardConfig<T>,
        ctx: &mut TxContext,
    ) {
        rewards::assert_admin_binding_v2(reward_admin, reward_cfg);
        let route_key = StoreEventRouteKey {};
        assert!(
            !dynamic_field::exists_with_type<StoreEventRouteKey, address>(&cfg.id, route_key),
            E_EVENT_ROUTE_MISMATCH,
        );
        dynamic_field::add(&mut cfg.id, route_key, object::id_address(reward_cfg));
        transfer::transfer(
            StoreEventFundingCapV2 {
                id: object::new(ctx),
                store_config_id: object::id_address(cfg),
                reward_config_id: object::id_address(reward_cfg),
            },
            tx_context::sender(ctx),
        );
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun buy_pack<T>(
        cfg: &mut StoreConfig<T>,
        payment: Coin<T>,
        pack_id: u8,
        order_id: String,
        ctx: &mut TxContext,
    ) {
        // Retained only for compatibility with the previously published ABI.
        // New deployments must use v2 so purchase quotes and order replay state
        // are enforced on-chain before Store custody accepts the payment.
        abort E_LEGACY_BUY_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun buy_pack_v2<T>(
        cfg: &mut StoreConfig<T>,
        payment: Coin<T>,
        pack_id: u8,
        expected_price: u64,
        expected_gems: u64,
        order_id: String,
        ctx: &mut TxContext,
    ) {
        assert_not_paused(cfg);
        assert_valid_reference(&order_id);

        let (price, gems) = pack_params(cfg, pack_id);
        assert!(expected_price == price, E_PRICE_MISMATCH);
        assert!(expected_gems == gems, E_GEMS_MISMATCH);

        let paid = coin::value(&payment);
        assert!(paid == expected_price, E_PRICE_MISMATCH);

        // Mark the order before custody transfer. Sui transaction atomicity
        // rolls the marker back if any later operation aborts.
        let buyer = tx_context::sender(ctx);
        mark_order_processed(cfg, buyer, order_id);
        balance::join(&mut cfg.vault, coin::into_balance(payment));

        event::emit(PackPurchasedV2 {
            config_id: object::id_address(cfg),
            buyer,
            pack_id,
            amount_gexi: price,
            gem_amount: gems,
            order_id,
        });
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun set_paused<T>(_: &StoreAdminCap, cfg: &mut StoreConfig<T>, paused: bool) {
        abort E_LEGACY_UNBOUND_ADMIN_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun set_paused_v2<T>(cap: &StoreAdminCapV2, cfg: &mut StoreConfig<T>, paused: bool) {
        assert_admin_binding(cap, cfg);
        cfg.paused = paused;
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun set_pack<T>(
        _: &StoreAdminCap,
        cfg: &mut StoreConfig<T>,
        pack_id: u8,
        new_price: u64,
        new_gems: u64,
    ) {
        abort E_LEGACY_UNBOUND_ADMIN_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun set_pack_v2<T>(
        cap: &StoreAdminCapV2,
        cfg: &mut StoreConfig<T>,
        pack_id: u8,
        new_price: u64,
        new_gems: u64,
    ) {
        assert_admin_binding(cap, cfg);
        assert_valid_public_pack_config(new_price, new_gems);
        if (pack_id == 1) {
            cfg.pack_1_price = new_price;
            cfg.pack_1_gems = new_gems;
            return
        };
        if (pack_id == 2) {
            cfg.pack_2_price = new_price;
            cfg.pack_2_gems = new_gems;
            return
        };
        if (pack_id == 3) {
            cfg.pack_3_price = new_price;
            cfg.pack_3_gems = new_gems;
            return
        };
        if (pack_id == 4) {
            cfg.pack_4_price = new_price;
            cfg.pack_4_gems = new_gems;
            return
        };
        if (pack_id == 5) {
            cfg.pack_5_price = new_price;
            cfg.pack_5_gems = new_gems;
            return
        };
        if (pack_id == 6) {
            cfg.pack_6_price = new_price;
            cfg.pack_6_gems = new_gems;
            return
        };
        abort E_PACK_NOT_FOUND
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_withdraw<T>(
        _: &StoreAdminCap,
        cfg: &mut StoreConfig<T>,
        amount: u64,
        to: address,
        ctx: &mut TxContext,
    ) {
        abort E_ADMIN_WITHDRAW_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_burn_vault<T>(
        _: &StoreAdminCap,
        treasury: &mut TreasuryCap<T>,
        cfg: &mut StoreConfig<T>,
        amount: u64,
        source_ref: String,
        ctx: &mut TxContext,
    ) {
        // Burn-only GEXI is implemented through Currency<T>; retaining a
        // TreasuryCap burn path would encode an incompatible supply authority.
        abort E_LEGACY_TREASURY_BURN_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_burn_vault_v2<T>(
        _: &StoreAdminCap,
        currency: &mut Currency<T>,
        cfg: &mut StoreConfig<T>,
        amount: u64,
        source_ref: String,
        ctx: &mut TxContext,
    ) {
        // Retained for package-upgrade ABI compatibility. StoreAdminCap controls
        // configuration only; irreversible burns require StoreBurnCap in v3.
        abort E_LEGACY_ADMIN_BURN_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_burn_vault_v3<T>(
        _: &StoreBurnCap,
        currency: &mut Currency<T>,
        cfg: &mut StoreConfig<T>,
        amount: u64,
        source_ref: String,
        ctx: &mut TxContext,
    ) {
        // Store proceeds are Event Treasury backing in the current economy.
        // Keep this ABI entry point for upgrades, but never destroy Store funds.
        abort E_STORE_BURN_DISABLED
    }

    /// Legacy-supply compatibility path with the same separated burn
    /// authority. New deployments use v3 with burn-only Currency<T>.
    #[allow(unused_variable, lint(public_entry))]
    public entry fun admin_burn_vault_legacy_v2<T>(
        _: &StoreBurnCap,
        treasury: &mut TreasuryCap<T>,
        cfg: &mut StoreConfig<T>,
        amount: u64,
        source_ref: String,
        ctx: &mut TxContext,
    ) {
        abort E_STORE_BURN_DISABLED
    }

    #[allow(unused_variable, lint(public_entry))]
    public entry fun settle_developer_ticket_revenue_v1<T>(
        _: &StoreBurnCap,
        currency: &mut Currency<T>,
        cfg: &mut StoreConfig<T>,
        ticket_count: u64,
        developer_revenue_recipient: address,
        source_ref: String,
        ctx: &mut TxContext,
    ) {
        // Paid normal plays no longer exist. Developer Event revenue is
        // accrued from the final Event pot and Store funds never burn here.
        abort E_STORE_BURN_DISABLED
    }

    /// Legacy-supply compatibility path for the same 20/80 Ticket
    /// settlement. New deployments use the Currency<T> burn path above.
    #[allow(unused_variable, lint(public_entry))]
    public entry fun settle_developer_ticket_revenue_legacy_v1<T>(
        _: &StoreBurnCap,
        treasury: &mut TreasuryCap<T>,
        cfg: &mut StoreConfig<T>,
        ticket_count: u64,
        developer_revenue_recipient: address,
        source_ref: String,
        ctx: &mut TxContext,
    ) {
        abort E_STORE_BURN_DISABLED
    }

    /// Move Store purchase proceeds into the existing Rewards/Event payout
    /// vault. Treasury funding can top up that same vault when discounted or
    /// rewarded Tickets create more nominal Event liability than Store sales.
    #[allow(unused_variable, lint(public_entry))]
    public entry fun fund_event_rewards_v1<T>(
        _: &StoreAdminCap,
        cfg: &mut StoreConfig<T>,
        reward_cfg: &mut RewardConfig<T>,
        amount: u64,
        source_ref: String,
        ctx: &mut TxContext,
    ) {
        abort E_LEGACY_UNBOUND_ADMIN_DISABLED
    }

    #[allow(lint(public_entry))]
    public entry fun fund_event_rewards_v2<T>(
        cap: &StoreEventFundingCapV2,
        cfg: &mut StoreConfig<T>,
        reward_cfg: &mut RewardConfig<T>,
        amount: u64,
        source_ref: String,
        ctx: &mut TxContext,
    ) {
        assert_event_route_binding(cap, cfg, reward_cfg);
        assert!(amount > 0 && balance::value(&cfg.vault) >= amount, E_INVALID_EVENT_FUNDING);
        mark_event_funding_processed(cfg, source_ref);
        let event_coins = coin::from_balance(balance::split(&mut cfg.vault, amount), ctx);
        rewards::fund_vault(reward_cfg, event_coins);
        event::emit(StoreEventTreasuryFunded {
            config_id: object::id_address(cfg),
            reward_config_id: object::id_address(reward_cfg),
            amount_mist: amount,
            source_ref,
        });
    }

    #[test]
    fun init_bootstraps_separate_store_caps() {
        let deployer = @0xA11CE;
        let mut scenario = sui::test_scenario::begin(deployer);
        init(STORE {}, scenario.ctx());
        scenario.next_tx(deployer);
        let admin = scenario.take_from_sender<StoreAdminCap>();
        let burn = scenario.take_from_sender<StoreBurnCap>();
        scenario.return_to_sender(admin);
        scenario.return_to_sender(burn);
        scenario.end();
    }

    #[test]
    fun legacy_store_roots_can_be_retired_without_replacement() {
        let mut ctx = tx_context::dummy();
        retire_legacy_store_admin_cap(StoreAdminCap { id: object::new(&mut ctx) });
        retire_legacy_store_burn_cap(StoreBurnCap { id: object::new(&mut ctx) });
    }

    #[test_only]
    fun config_for_testing(ctx: &mut TxContext): StoreConfig<u8> {
        StoreConfig<u8> {
            id: object::new(ctx),
            vault: balance::zero<u8>(),
            pack_1_price: 20_000_000_000,
            pack_1_gems: 5,
            pack_2_price: 75_000_000_000,
            pack_2_gems: 20,
            pack_3_price: 180_000_000_000,
            pack_3_gems: 50,
            pack_4_price: 340_000_000_000,
            pack_4_gems: 100,
            pack_5_price: 800_000_000_000,
            pack_5_gems: 250,
            pack_6_price: 1_500_000_000_000,
            pack_6_gems: 500,
            paused: false,
        }
    }

    #[test]
    #[allow(lint(abort_without_constant))]
    fun valid_v2_purchase_marks_order_and_funds_vault() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let buyer = tx_context::sender(&ctx);
        let order_id = std::string::utf8(b"valid-order");
        let payment = coin::mint_for_testing<u8>(20_000_000_000, &mut ctx);
        buy_pack_v2(&mut cfg, payment, 1, 20_000_000_000, 5, order_id, &mut ctx);
        assert!(balance::value(&cfg.vault) == 20_000_000_000, 900);
        assert!(
            dynamic_field::exists_with_type<StoreOrderKeyV2, bool>(
                &cfg.id,
                StoreOrderKeyV2 { buyer, order_id },
            ),
            901,
        );
        transfer::share_object(cfg);
    }

    #[test]
    fun store_proceeds_fund_event_reward_vault_without_burn() {
        let deployer = @0xA11CE;
        let mut scenario = sui::test_scenario::begin(deployer);
        let reward_admin = rewards::rewards_admin_cap_for_testing(scenario.ctx());
        rewards::create_rewards<u8>(
            &reward_admin,
            vector[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            scenario.ctx(),
        );
        rewards::destroy_rewards_admin_cap_for_testing(reward_admin);

        scenario.next_tx(deployer);
        let mut reward_cfg = scenario.take_shared<RewardConfig<u8>>();
        let mut store_cfg = config_for_testing(scenario.ctx());
        let funding_cap = StoreEventFundingCapV2 {
            id: object::new(scenario.ctx()),
            store_config_id: object::id_address(&store_cfg),
            reward_config_id: object::id_address(&reward_cfg),
        };
        let payment = coin::mint_for_testing<u8>(20_000_000_000, scenario.ctx());
        buy_pack_v2(
            &mut store_cfg,
            payment,
            1,
            20_000_000_000,
            5,
            std::string::utf8(b"event-vault-order"),
            scenario.ctx(),
        );

        fund_event_rewards_v2(
            &funding_cap,
            &mut store_cfg,
            &mut reward_cfg,
            20_000_000_000,
            std::string::utf8(b"event-vault-funding"),
            scenario.ctx(),
        );

        assert!(balance::value(&store_cfg.vault) == 0, 907);
        assert!(rewards::reward_vault_balance_for_testing(&reward_cfg) == 20_000_000_000, 908);

        sui::test_scenario::return_shared(reward_cfg);
        transfer::share_object(store_cfg);
        let StoreEventFundingCapV2 { id, store_config_id: _, reward_config_id: _ } = funding_cap;
        id.delete();
        scenario.end();
    }

    #[test]
    fun same_order_id_is_scoped_to_buyer() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let order_id = std::string::utf8(b"buyer-scoped-order");
        mark_order_processed(&mut cfg, @0xA, order_id);
        mark_order_processed(&mut cfg, @0xB, order_id);
        assert!(
            dynamic_field::exists_with_type<StoreOrderKeyV2, bool>(
                &cfg.id,
                StoreOrderKeyV2 { buyer: @0xA, order_id },
            ),
            905,
        );
        assert!(
            dynamic_field::exists_with_type<StoreOrderKeyV2, bool>(
                &cfg.id,
                StoreOrderKeyV2 { buyer: @0xB, order_id },
            ),
            906,
        );
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_BUY_DISABLED)]
    fun legacy_buy_is_disabled() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let payment = coin::mint_for_testing<u8>(75_000_000_000, &mut ctx);
        buy_pack(
            &mut cfg,
            payment,
            2,
            std::string::utf8(b"legacy-order"),
            &mut ctx,
        );
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_PRICE_MISMATCH)]
    fun quote_change_rejects_stale_price() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let admin = StoreAdminCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&cfg),
        };
        set_pack_v2(&admin, &mut cfg, 2, 76_000_000_000, 20);
        let payment = coin::mint_for_testing<u8>(75_000_000_000, &mut ctx);
        buy_pack_v2(
            &mut cfg,
            payment,
            2,
            75_000_000_000,
            20,
            std::string::utf8(b"stale-quote"),
            &mut ctx,
        );
        transfer::share_object(cfg);
        let StoreAdminCapV2 { id, config_id: _ } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_PRICE_MISMATCH)]
    fun wrong_expected_price_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let payment = coin::mint_for_testing<u8>(75_000_000_000, &mut ctx);
        buy_pack_v2(
            &mut cfg,
            payment,
            2,
            74_000_000_000,
            20,
            std::string::utf8(b"wrong-price"),
            &mut ctx,
        );
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_GEMS_MISMATCH)]
    fun wrong_expected_gems_are_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let payment = coin::mint_for_testing<u8>(75_000_000_000, &mut ctx);
        buy_pack_v2(
            &mut cfg,
            payment,
            2,
            75_000_000_000,
            21,
            std::string::utf8(b"wrong-gems"),
            &mut ctx,
        );
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_ORDER_ALREADY_PROCESSED)]
    fun duplicate_order_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let order_id = std::string::utf8(b"same-order");
        let first = coin::mint_for_testing<u8>(75_000_000_000, &mut ctx);
        buy_pack_v2(&mut cfg, first, 2, 75_000_000_000, 20, order_id, &mut ctx);
        let second = coin::mint_for_testing<u8>(75_000_000_000, &mut ctx);
        buy_pack_v2(&mut cfg, second, 2, 75_000_000_000, 20, order_id, &mut ctx);
        transfer::share_object(cfg);
    }

    #[test]
    fun pack_one_is_a_normal_onchain_purchase() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let payment = coin::mint_for_testing<u8>(20_000_000_000, &mut ctx);
        buy_pack_v2(
            &mut cfg,
            payment,
            1,
            20_000_000_000,
            5,
            std::string::utf8(b"pack-one"),
            &mut ctx,
        );
        assert!(balance::value(&cfg.vault) == 20_000_000_000, 902);
        transfer::share_object(cfg);
    }

    #[test]
    fun pack_one_can_be_reconfigured() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let admin = StoreAdminCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&cfg),
        };
        set_pack_v2(&admin, &mut cfg, 1, 25_000_000_000, 6);
        let (price, gems) = pack_params(&cfg, 1);
        assert!(price == 25_000_000_000, 903);
        assert!(gems == 6, 904);
        transfer::share_object(cfg);
        let StoreAdminCapV2 { id, config_id: _ } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_STORE_PAUSED)]
    fun paused_store_rejects_purchase() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let admin = StoreAdminCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&cfg),
        };
        set_paused_v2(&admin, &mut cfg, true);
        let payment = coin::mint_for_testing<u8>(75_000_000_000, &mut ctx);
        buy_pack_v2(
            &mut cfg,
            payment,
            2,
            75_000_000_000,
            20,
            std::string::utf8(b"paused-order"),
            &mut ctx,
        );
        transfer::share_object(cfg);
        let StoreAdminCapV2 { id, config_id: _ } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_PACK_CONFIG)]
    fun fractional_price_tick_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let admin = StoreAdminCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&cfg),
        };
        set_pack_v2(&admin, &mut cfg, 2, 75_000_000_001, 20);
        transfer::share_object(cfg);
        let StoreAdminCapV2 { id, config_id: _ } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_PACK_CONFIG)]
    fun zero_gem_pack_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let admin = StoreAdminCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&cfg),
        };
        set_pack_v2(&admin, &mut cfg, 2, 75_000_000_000, 0);
        transfer::share_object(cfg);
        let StoreAdminCapV2 { id, config_id: _ } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_ADMIN_WITHDRAW_DISABLED)]
    fun admin_withdraw_is_disabled() {
        let mut ctx = tx_context::dummy();
        let admin = StoreAdminCap { id: object::new(&mut ctx) };
        let mut cfg = config_for_testing(&mut ctx);
        admin_withdraw(&admin, &mut cfg, 0, @0x1, &mut ctx);
        transfer::share_object(cfg);
        let StoreAdminCap { id } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_TREASURY_BURN_DISABLED)]
    fun treasury_cap_burn_path_is_disabled() {
        let mut ctx = tx_context::dummy();
        let admin = StoreAdminCap { id: object::new(&mut ctx) };
        let mut treasury = coin::create_treasury_cap_for_testing<u8>(&mut ctx);
        let mut cfg = config_for_testing(&mut ctx);
        admin_burn_vault(
            &admin,
            &mut treasury,
            &mut cfg,
            0,
            std::string::utf8(b"legacy-burn"),
            &mut ctx,
        );
        transfer::share_object(cfg);
        transfer::public_transfer(treasury, @0x1);
        let StoreAdminCap { id } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_BURN_ALREADY_PROCESSED)]
    fun burn_source_ref_replay_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let source_ref = std::string::utf8(b"burn-batch-1");
        mark_burn_processed(&mut cfg, source_ref);
        mark_burn_processed(&mut cfg, source_ref);
        transfer::share_object(cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_STORE_CAP_CONFIG_MISMATCH)]
    fun bound_store_admin_rejects_other_config() {
        let mut ctx = tx_context::dummy();
        let cfg_a = config_for_testing(&mut ctx);
        let mut cfg_b = config_for_testing(&mut ctx);
        let admin = StoreAdminCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&cfg_a),
        };
        set_paused_v2(&admin, &mut cfg_b, true);
        transfer::share_object(cfg_a);
        transfer::share_object(cfg_b);
        let StoreAdminCapV2 { id, config_id: _ } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_EVENT_ROUTE_MISMATCH)]
    fun bound_event_route_rejects_other_reward_config() {
        let mut ctx = tx_context::dummy();
        let mut store_cfg = config_for_testing(&mut ctx);
        let reward_cfg_a = rewards::reward_config_for_testing(&mut ctx);
        let mut reward_cfg_b = rewards::reward_config_for_testing(&mut ctx);
        let funding_cap = StoreEventFundingCapV2 {
            id: object::new(&mut ctx),
            store_config_id: object::id_address(&store_cfg),
            reward_config_id: object::id_address(&reward_cfg_a),
        };
        let payment = coin::mint_for_testing<u8>(20_000_000_000, &mut ctx);
        buy_pack_v2(
            &mut store_cfg,
            payment,
            1,
            20_000_000_000,
            5,
            std::string::utf8(b"route-mismatch-order"),
            &mut ctx,
        );
        fund_event_rewards_v2(
            &funding_cap,
            &mut store_cfg,
            &mut reward_cfg_b,
            20_000_000_000,
            std::string::utf8(b"route-mismatch-funding"),
            &mut ctx,
        );
        transfer::share_object(store_cfg);
        rewards::share_reward_config_for_testing(reward_cfg_a);
        rewards::share_reward_config_for_testing(reward_cfg_b);
        let StoreEventFundingCapV2 { id, store_config_id: _, reward_config_id: _ } = funding_cap;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_LEGACY_UNBOUND_ADMIN_DISABLED)]
    fun store_admin_v2_can_only_be_minted_once_per_config() {
        let mut ctx = tx_context::dummy();
        let root = StoreAdminCap { id: object::new(&mut ctx) };
        let mut cfg = config_for_testing(&mut ctx);
        bind_store_admin_v2(&root, &mut cfg, &mut ctx);
        bind_store_admin_v2(&root, &mut cfg, &mut ctx);
        transfer::share_object(cfg);
        let StoreAdminCap { id } = root;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_EVENT_ROUTE_MISMATCH)]
    fun event_route_can_only_be_bound_once_per_store_config() {
        let mut ctx = tx_context::dummy();
        let store_root = StoreAdminCap { id: object::new(&mut ctx) };
        let mut store_cfg = config_for_testing(&mut ctx);
        let reward_cfg = rewards::reward_config_for_testing(&mut ctx);
        let reward_admin = rewards::rewards_admin_cap_v2_for_testing(&reward_cfg, &mut ctx);
        bind_event_funding_v2(
            &store_root,
            &reward_admin,
            &mut store_cfg,
            &reward_cfg,
            &mut ctx,
        );
        bind_event_funding_v2(
            &store_root,
            &reward_admin,
            &mut store_cfg,
            &reward_cfg,
            &mut ctx,
        );
        transfer::share_object(store_cfg);
        rewards::share_reward_config_for_testing(reward_cfg);
        rewards::destroy_rewards_admin_cap_v2_for_testing(reward_admin);
        let StoreAdminCap { id } = store_root;
        id.delete();
    }
}
