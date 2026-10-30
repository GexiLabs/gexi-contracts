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
    const E_SPARKS_STORE_CONFIG_MISMATCH: u64 = 22;
    const E_SPARKS_STORE_ALREADY_CREATED: u64 = 23;
    const E_SPARKS_INVALID_WITHDRAWAL: u64 = 24;
    const E_INFRA_TREASURY_INVALID: u64 = 25;
    const E_INFRA_TREASURY_ALREADY_BOUND: u64 = 26;
    const E_INFRA_TREASURY_CAP_MISMATCH: u64 = 27;
    const E_INFRA_TREASURY_WITHDRAWAL_INVALID: u64 = 28;

    /// GEXI uses 9 decimals. Public pack prices must stay on whole-GEXI ticks
    /// so off-chain quotes cannot silently drift into fractional base units.
    const PRICE_TICK_MIST: u64 = 1_000_000_000;
    const MAX_REFERENCE_BYTES: u64 = 128;
    /// Product code is part of every Sparks event. Tickets retain their v2 ABI.
    const PRODUCT_SPARKS: u8 = 2;

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

    /// Sparks revenue is isolated from the Ticket/Event backing vault above.
    /// This is a NEW shared object, never a field added to an existing layout.
    public struct SparksStoreConfig<phantom T> has key {
        id: UID,
        ticket_store_config_id: address,
        vault: Balance<T>,
        paused: bool,
    }

    /// Independent custody authority, bound to one Sparks vault and its
    /// canonical Ticket Store; never accepted by Ticket funding functions.
    public struct SparksStoreAdminCapV1 has key, store {
        id: UID,
        sparks_config_id: address,
        ticket_store_config_id: address,
    }

    /// The V1 Sparks admin cap is consumed on migration. Prior published
    /// packages can still expose the V1 arbitrary-recipient withdrawal, so
    /// guarding only the new implementation of that function is insufficient.
    public struct SparksStoreAdminCapV2 has key, store {
        id: UID,
        sparks_config_id: address,
        ticket_store_config_id: address,
        infrastructure_treasury: address,
    }

    /// Ticket Store revenue is distinct from existing Rewards/Event backing.
    /// The treasury recipient is fixed once for this StoreConfig and cannot
    /// be replaced by the caller of an individual withdrawal.
    public struct StoreInfrastructureTreasuryCapV1 has key, store {
        id: UID,
        store_config_id: address,
        infrastructure_treasury: address,
    }

    public struct StoreInfrastructureTreasuryBoundV1 has copy, drop {
        store_config_id: address,
        infrastructure_treasury: address,
    }

    public struct StoreEventFundingAuthorityRetiredV1 has copy, drop {
        store_config_id: address,
        reward_config_id: address,
    }

    public struct SparksInfrastructureTreasuryBoundV2 has copy, drop {
        sparks_config_id: address,
        ticket_store_config_id: address,
        infrastructure_treasury: address,
    }

    public struct InfrastructureTreasuryRevenueWithdrawnV1 has copy, drop {
        store_config_id: address,
        infrastructure_treasury: address,
        amount_mist: u64,
        minimum_store_reserve_mist: u64,
        source_ref: String,
    }

    public struct SparksInfrastructureRevenueWithdrawnV2 has copy, drop {
        sparks_config_id: address,
        infrastructure_treasury: address,
        amount_mist: u64,
        minimum_pending_order_reserve_mist: u64,
        source_ref: String,
    }

    public struct SparksStoreCreatedV1 has copy, drop {
        ticket_store_config_id: address,
        sparks_config_id: address,
        administrator: address,
    }

    /// A product-specific purchase receipt: off-chain Sparks credit MUST be
    /// based on this event, never on a Ticket PackPurchasedV2 event or raw
    /// wallet transfer. All amounts of GEXI are in 9-decimal base units.
    public struct SparksPackPurchasedV1 has copy, drop {
        product: u8,
        sparks_config_id: address,
        ticket_store_config_id: address,
        buyer: address,
        pack_id: u8,
        amount_gexi: u64,
        sparks_amount: u64,
        order_id: String,
    }

    public struct SparksRevenueWithdrawnV1 has copy, drop {
        sparks_config_id: address,
        recipient: address,
        amount_gexi: u64,
    }

    #[allow(unused_field)]
    public struct PackPurchased has copy, drop {
        buyer: address,
        pack_id: u8,
        amount_gexi: u64,
        gem_amount: u64,
        order_id: String,
    }

    /// Fresh-mainnet purchase event. `config_id` binds settlement evidence to
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
    public struct StoreInfrastructureTreasuryRouteKey has copy, drop, store {}
    public struct StoreInfrastructureTreasuryWithdrawalKey has copy, drop, store {
        source_ref: String,
    }
    public struct SparksInfrastructureTreasuryWithdrawalKey has copy, drop, store {
        source_ref: String,
    }
    /// StoreConfig remains byte-for-byte upgrade compatible; adding a dynamic
    /// field to its UID does not add a field to its published struct layout.
    public struct SparksStoreCreationKey has copy, drop, store {}

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

    /// Immutable six-pack GEXI->Sparks catalog. No arbitrary admin-set prices
    /// or client-supplied Sparks quantities can bypass these exact quotes.
    fun sparks_pack_params(pack_id: u8): (u64, u64) {
        if (pack_id == 1) return (50 * PRICE_TICK_MIST, 50);
        if (pack_id == 2) return (100 * PRICE_TICK_MIST, 100);
        if (pack_id == 3) return (240 * PRICE_TICK_MIST, 250);
        if (pack_id == 4) return (465 * PRICE_TICK_MIST, 500);
        if (pack_id == 5) return (900 * PRICE_TICK_MIST, 1000);
        if (pack_id == 6) return (2150 * PRICE_TICK_MIST, 2500);
        abort E_PACK_NOT_FOUND
    }

    fun assert_sparks_store_bound<T>(ticket_cfg: &StoreConfig<T>, sparks_cfg: &SparksStoreConfig<T>) {
        assert!(
            sparks_cfg.ticket_store_config_id == object::id_address(ticket_cfg),
            E_SPARKS_STORE_CONFIG_MISMATCH,
        );
        let key = SparksStoreCreationKey {};
        assert!(
            dynamic_field::exists_with_type<SparksStoreCreationKey, address>(&ticket_cfg.id, key)
                && *dynamic_field::borrow<SparksStoreCreationKey, address>(&ticket_cfg.id, key)
                    == object::id_address(sparks_cfg),
            E_SPARKS_STORE_CONFIG_MISMATCH,
        );
    }

    fun assert_sparks_admin_bound<T>(cap: &SparksStoreAdminCapV1, sparks_cfg: &SparksStoreConfig<T>) {
        assert!(
            cap.sparks_config_id == object::id_address(sparks_cfg)
                && cap.ticket_store_config_id == sparks_cfg.ticket_store_config_id,
            E_SPARKS_STORE_CONFIG_MISMATCH,
        );
    }

    fun assert_sparks_admin_v2_bound<T>(cap: &SparksStoreAdminCapV2, sparks_cfg: &SparksStoreConfig<T>) {
        assert!(
            cap.sparks_config_id == object::id_address(sparks_cfg)
                && cap.ticket_store_config_id == sparks_cfg.ticket_store_config_id,
            E_SPARKS_STORE_CONFIG_MISMATCH,
        );
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

    /// One-time opt-in by the canonical bound Store administrator. The
    /// resulting dedicated revenue cap cannot change its payment recipient.
    /// Keep the StoreEventFundingCapV2 available for already-owed rewards.
    #[allow(lint(public_entry))]
    public entry fun bind_store_infrastructure_treasury_v1<T>(
        admin: &StoreAdminCapV2,
        cfg: &mut StoreConfig<T>,
        infrastructure_treasury: address,
        ctx: &mut TxContext,
    ) {
        assert_admin_binding(admin, cfg);
        assert!(infrastructure_treasury != @0x0, E_INFRA_TREASURY_INVALID);
        let key = StoreInfrastructureTreasuryRouteKey {};
        assert!(
            !dynamic_field::exists_with_type<StoreInfrastructureTreasuryRouteKey, address>(&cfg.id, key),
            E_INFRA_TREASURY_ALREADY_BOUND,
        );
        let store_config_id = object::id_address(cfg);
        dynamic_field::add(&mut cfg.id, key, infrastructure_treasury);
        transfer::transfer(StoreInfrastructureTreasuryCapV1 {
            id: object::new(ctx), store_config_id, infrastructure_treasury,
        }, tx_context::sender(ctx));
        event::emit(StoreInfrastructureTreasuryBoundV1 { store_config_id, infrastructure_treasury });
    }

    /// Complete the treasury cutover by consuming the historical Store ->
    /// Rewards funding cap. Earlier package versions remain callable on Sui;
    /// deleting the old cap is the only durable way to retire their ability
    /// to redirect Store proceeds after rewards are separately funded.
    #[allow(lint(public_entry))]
    public entry fun retire_store_event_funding_for_treasury_v1<T>(
        old_cap: StoreEventFundingCapV2,
        treasury_cap: &StoreInfrastructureTreasuryCapV1,
        cfg: &StoreConfig<T>,
    ) {
        assert!(
            old_cap.store_config_id == object::id_address(cfg)
                && treasury_cap.store_config_id == object::id_address(cfg),
            E_INFRA_TREASURY_CAP_MISMATCH,
        );
        let route = StoreInfrastructureTreasuryRouteKey {};
        assert!(
            dynamic_field::exists_with_type<StoreInfrastructureTreasuryRouteKey, address>(&cfg.id, route)
                && *dynamic_field::borrow<StoreInfrastructureTreasuryRouteKey, address>(&cfg.id, route)
                    == treasury_cap.infrastructure_treasury,
            E_INFRA_TREASURY_CAP_MISMATCH,
        );
        let StoreEventFundingCapV2 { id, store_config_id, reward_config_id } = old_cap;
        id.delete();
        event::emit(StoreEventFundingAuthorityRetiredV1 { store_config_id, reward_config_id });
    }

    /// Only settled, surplus Ticket Store receipts may be swept. The caller
    /// must supply an independently reconciled minimum reserve for outstanding
    /// Ticket/Event/refund liabilities; Move enforces that floor atomically.
    /// Each source reference is single-use, including after interrupted jobs.
    #[allow(lint(public_entry))]
    public entry fun withdraw_ticket_infrastructure_revenue_v1<T>(
        cap: &StoreInfrastructureTreasuryCapV1,
        cfg: &mut StoreConfig<T>,
        amount: u64,
        minimum_store_reserve_mist: u64,
        source_ref: String,
        ctx: &mut TxContext,
    ) {
        assert!(cap.store_config_id == object::id_address(cfg), E_INFRA_TREASURY_CAP_MISMATCH);
        let route_key = StoreInfrastructureTreasuryRouteKey {};
        assert!(
            dynamic_field::exists_with_type<StoreInfrastructureTreasuryRouteKey, address>(&cfg.id, route_key)
                && *dynamic_field::borrow<StoreInfrastructureTreasuryRouteKey, address>(&cfg.id, route_key)
                    == cap.infrastructure_treasury,
            E_INFRA_TREASURY_CAP_MISMATCH,
        );
        let available = balance::value(&cfg.vault);
        assert!(
            amount > 0 && amount <= available
                && minimum_store_reserve_mist <= available - amount,
            E_INFRA_TREASURY_WITHDRAWAL_INVALID,
        );
        assert_valid_reference(&source_ref);
        let marker = StoreInfrastructureTreasuryWithdrawalKey { source_ref };
        assert!(
            !dynamic_field::exists_with_type<StoreInfrastructureTreasuryWithdrawalKey, bool>(&cfg.id, marker),
            E_INFRA_TREASURY_WITHDRAWAL_INVALID,
        );
        dynamic_field::add(&mut cfg.id, marker, true);
        transfer::public_transfer(
            coin::from_balance(balance::split(&mut cfg.vault, amount), ctx),
            cap.infrastructure_treasury,
        );
        event::emit(InfrastructureTreasuryRevenueWithdrawnV1 {
            store_config_id: object::id_address(cfg),
            infrastructure_treasury: cap.infrastructure_treasury,
            amount_mist: amount,
            minimum_store_reserve_mist,
            source_ref,
        });
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
        // Retained only for compatibility with already-published testnet ABI.
        // Fresh mainnet must use v2 so purchase quotes and order replay state
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

    /// Called ONCE by the existing Ticket Store's bound administrator after
    /// package upgrade. A shared Sparks object and a separate owned cap are
    /// created. Neither Ticket prices nor Ticket/Event backing are touched.
    #[allow(lint(public_entry))]
    public entry fun create_sparks_store_v1<T>(
        ticket_admin: &StoreAdminCapV2,
        ticket_cfg: &mut StoreConfig<T>,
        ctx: &mut TxContext,
    ) {
        assert_admin_binding(ticket_admin, ticket_cfg);
        let key = SparksStoreCreationKey {};
        assert!(
            !dynamic_field::exists_with_type<SparksStoreCreationKey, address>(&ticket_cfg.id, key),
            E_SPARKS_STORE_ALREADY_CREATED,
        );
        let sparks_cfg = SparksStoreConfig<T> {
            id: object::new(ctx),
            ticket_store_config_id: object::id_address(ticket_cfg),
            vault: balance::zero<T>(),
            paused: false,
        };
        let sparks_config_id = object::id_address(&sparks_cfg);
        let ticket_store_config_id = object::id_address(ticket_cfg);
        dynamic_field::add(&mut ticket_cfg.id, key, sparks_config_id);
        let administrator = tx_context::sender(ctx);
        transfer::transfer(
            SparksStoreAdminCapV1 {
                id: object::new(ctx),
                sparks_config_id,
                ticket_store_config_id,
            },
            administrator,
        );
        event::emit(SparksStoreCreatedV1 { ticket_store_config_id, sparks_config_id, administrator });
        transfer::share_object(sparks_cfg);
    }

    /// Ticket purchase and Sparks purchase share one Store module and one
    /// global buyer/order replay namespace, but NEVER share revenue custody.
    /// A successful event is evidence of paid Sparks; credit is off-chain and
    /// must be idempotent and explicitly verified against this exact receipt.
    #[allow(lint(public_entry))]
    public entry fun buy_sparks_pack_v1<T>(
        ticket_cfg: &mut StoreConfig<T>,
        sparks_cfg: &mut SparksStoreConfig<T>,
        payment: Coin<T>,
        pack_id: u8,
        expected_price: u64,
        expected_sparks: u64,
        order_id: String,
        ctx: &mut TxContext,
    ) {
        assert_sparks_store_bound(ticket_cfg, sparks_cfg);
        // The parent Ticket Store pause is the global Store kill switch.
        // Sparks-specific pause remains an independent, narrower control.
        assert_not_paused(ticket_cfg);
        assert!(!sparks_cfg.paused, E_STORE_PAUSED);
        assert_valid_reference(&order_id);
        let (price, sparks_amount) = sparks_pack_params(pack_id);
        assert!(expected_price == price && coin::value(&payment) == price, E_PRICE_MISMATCH);
        assert!(expected_sparks == sparks_amount, E_GEMS_MISMATCH);
        let buyer = tx_context::sender(ctx);
        // Reuse Ticket v2 buyer/order key on the existing shared Store UID.
        // Same buyer/order UUID cannot be paid once as Ticket and again as
        // Sparks, even though their event types/custody are independent.
        mark_order_processed(ticket_cfg, buyer, order_id);
        balance::join(&mut sparks_cfg.vault, coin::into_balance(payment));
        event::emit(SparksPackPurchasedV1 {
            product: PRODUCT_SPARKS,
            sparks_config_id: object::id_address(sparks_cfg),
            ticket_store_config_id: object::id_address(ticket_cfg),
            buyer,
            pack_id,
            amount_gexi: price,
            sparks_amount,
            order_id,
        });
    }

    #[allow(lint(public_entry))]
    public entry fun set_sparks_paused_v1<T>(
        cap: &SparksStoreAdminCapV1,
        sparks_cfg: &mut SparksStoreConfig<T>,
        paused: bool,
    ) {
        assert_sparks_admin_bound(cap, sparks_cfg);
        sparks_cfg.paused = paused;
    }

    /// Revenue belongs to the separate Sparks administrator, never to Event
    /// payout backing; no StoreEventFundingCap can access sparks_cfg.vault.
    #[allow(lint(public_entry))]
    public entry fun withdraw_sparks_revenue_v1<T>(
        cap: &SparksStoreAdminCapV1,
        sparks_cfg: &mut SparksStoreConfig<T>,
        amount: u64,
        to: address,
        ctx: &mut TxContext,
    ) {
        assert_sparks_admin_bound(cap, sparks_cfg);
        assert!(amount > 0 && balance::value(&sparks_cfg.vault) >= amount, E_SPARKS_INVALID_WITHDRAWAL);
        assert!(to != @0x0, E_SPARKS_INVALID_WITHDRAWAL);
        transfer::public_transfer(coin::from_balance(balance::split(&mut sparks_cfg.vault, amount), ctx), to);
        event::emit(SparksRevenueWithdrawnV1 {
            sparks_config_id: object::id_address(sparks_cfg),
            recipient: to,
            amount_gexi: amount,
        });
    }

    /// Consumes the only V1 Sparks authority so older deployed package code
    /// cannot use it to withdraw to a caller-selected destination. The V2 cap
    /// retains pause authority and can send revenue only to its fixed treasury.
    #[allow(lint(public_entry))]
    public entry fun migrate_sparks_infrastructure_treasury_v2<T>(
        old_cap: SparksStoreAdminCapV1,
        sparks_cfg: &SparksStoreConfig<T>,
        infrastructure_treasury: address,
        ctx: &mut TxContext,
    ) {
        assert_sparks_admin_bound(&old_cap, sparks_cfg);
        assert!(infrastructure_treasury != @0x0, E_INFRA_TREASURY_INVALID);
        let SparksStoreAdminCapV1 { id, sparks_config_id, ticket_store_config_id } = old_cap;
        id.delete();
        transfer::transfer(SparksStoreAdminCapV2 {
            id: object::new(ctx), sparks_config_id, ticket_store_config_id, infrastructure_treasury,
        }, tx_context::sender(ctx));
        event::emit(SparksInfrastructureTreasuryBoundV2 {
            sparks_config_id, ticket_store_config_id, infrastructure_treasury,
        });
    }

    #[allow(lint(public_entry))]
    public entry fun set_sparks_paused_v2<T>(
        cap: &SparksStoreAdminCapV2,
        sparks_cfg: &mut SparksStoreConfig<T>,
        paused: bool,
    ) {
        assert_sparks_admin_v2_bound(cap, sparks_cfg);
        sparks_cfg.paused = paused;
    }

    /// Retain paid-order idempotent verification and receipt recovery in the
    /// backend before calculating withdrawable Sparks revenue. The purchase
    /// entrypoint and its canonical SparksPackPurchasedV1 event are unchanged.
    #[allow(lint(public_entry))]
    public entry fun withdraw_sparks_infrastructure_revenue_v2<T>(
        cap: &SparksStoreAdminCapV2,
        sparks_cfg: &mut SparksStoreConfig<T>,
        amount: u64,
        minimum_pending_order_reserve_mist: u64,
        source_ref: String,
        ctx: &mut TxContext,
    ) {
        assert_sparks_admin_v2_bound(cap, sparks_cfg);
        let available = balance::value(&sparks_cfg.vault);
        assert!(
            amount > 0 && amount <= available
                && minimum_pending_order_reserve_mist <= available - amount,
            E_SPARKS_INVALID_WITHDRAWAL,
        );
        assert_valid_reference(&source_ref);
        let marker = SparksInfrastructureTreasuryWithdrawalKey { source_ref };
        assert!(
            !dynamic_field::exists_with_type<SparksInfrastructureTreasuryWithdrawalKey, bool>(&sparks_cfg.id, marker),
            E_SPARKS_INVALID_WITHDRAWAL,
        );
        dynamic_field::add(&mut sparks_cfg.id, marker, true);
        transfer::public_transfer(
            coin::from_balance(balance::split(&mut sparks_cfg.vault, amount), ctx),
            cap.infrastructure_treasury,
        );
        event::emit(SparksRevenueWithdrawnV1 {
            sparks_config_id: object::id_address(sparks_cfg),
            recipient: cap.infrastructure_treasury,
            amount_gexi: amount,
        });
        event::emit(SparksInfrastructureRevenueWithdrawnV2 {
            sparks_config_id: object::id_address(sparks_cfg),
            infrastructure_treasury: cap.infrastructure_treasury,
            amount_mist: amount,
            minimum_pending_order_reserve_mist,
            source_ref,
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
        // Fresh mainnet GEXI is burn-only through Currency<T>; retaining a
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

    /// Testnet/legacy-supply compatibility path with the same separated burn
    /// authority. Fresh mainnet uses v3 with burn-only Currency<T>.
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

    /// Testnet/legacy-supply compatibility path for the same 20/80 Ticket
    /// settlement. Fresh mainnet uses the Currency<T> burn path above.
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

    #[test_only]
    fun sparks_config_for_testing(ticket_cfg: &mut StoreConfig<u8>, ctx: &mut TxContext): SparksStoreConfig<u8> {
        let sparks_cfg = SparksStoreConfig<u8> {
            id: object::new(ctx),
            ticket_store_config_id: object::id_address(ticket_cfg),
            vault: balance::zero<u8>(),
            paused: false,
        };
        dynamic_field::add(&mut ticket_cfg.id, SparksStoreCreationKey {}, object::id_address(&sparks_cfg));
        sparks_cfg
    }

    #[test]
    fun sparks_catalog_has_six_fixed_exact_quotes() {
        let (p1, s1) = sparks_pack_params(1);
        let (p2, s2) = sparks_pack_params(2);
        let (p3, s3) = sparks_pack_params(3);
        let (p4, s4) = sparks_pack_params(4);
        let (p5, s5) = sparks_pack_params(5);
        let (p6, s6) = sparks_pack_params(6);
        assert!(p1 == 50_000_000_000 && s1 == 50, 911);
        assert!(p2 == 100_000_000_000 && s2 == 100, 912);
        assert!(p3 == 240_000_000_000 && s3 == 250, 913);
        assert!(p4 == 465_000_000_000 && s4 == 500, 914);
        assert!(p5 == 900_000_000_000 && s5 == 1000, 915);
        assert!(p6 == 2_150_000_000_000 && s6 == 2500, 916);
    }

    #[test]
    fun sparks_purchase_never_adds_to_ticket_vault() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let buyer = tx_context::sender(&ctx);
        let order_id = std::string::utf8(b"separated-sparks-order");
        let ticket_payment = coin::mint_for_testing<u8>(20_000_000_000, &mut ctx);
        buy_pack_v2(
            &mut ticket_cfg, ticket_payment, 1, 20_000_000_000, 5,
            std::string::utf8(b"other-ticket-order"), &mut ctx,
        );
        let sparks_payment = coin::mint_for_testing<u8>(240_000_000_000, &mut ctx);
        buy_sparks_pack_v1(
            &mut ticket_cfg, &mut sparks_cfg, sparks_payment, 3, 240_000_000_000, 250,
            order_id, &mut ctx,
        );
        assert!(balance::value(&ticket_cfg.vault) == 20_000_000_000, 917);
        assert!(balance::value(&sparks_cfg.vault) == 240_000_000_000, 918);
        assert!(
            dynamic_field::exists_with_type<StoreOrderKeyV2, bool>(
                &ticket_cfg.id, StoreOrderKeyV2 { buyer, order_id },
            ),
            919,
        );
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_PRICE_MISMATCH)]
    fun sparks_pre_discount_quote_is_rejected_for_large_pack() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        // Pack 3 now grants 250 Sparks for 240 GEXI; a stale 250-GEXI
        // quote must never succeed under the new immutable Store catalog.
        let old_payment = coin::mint_for_testing<u8>(250_000_000_000, &mut ctx);
        buy_sparks_pack_v1(
            &mut ticket_cfg, &mut sparks_cfg, old_payment, 3,
            250_000_000_000, 250,
            std::string::utf8(b"stale-sparks-volume-quote"), &mut ctx,
        );
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_ORDER_ALREADY_PROCESSED)]
    fun sparks_double_purchase_is_rejected_onchain() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let order = std::string::utf8(b"one-sparks-order");
        let payment1 = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment1, 1, 50_000_000_000, 50, order, &mut ctx);
        let payment2 = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment2, 1, 50_000_000_000, 50, order, &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_ORDER_ALREADY_PROCESSED)]
    fun sparks_cannot_reuse_a_ticket_order_id() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let order = std::string::utf8(b"one-product-order");
        let tickets = coin::mint_for_testing<u8>(20_000_000_000, &mut ctx);
        buy_pack_v2(&mut ticket_cfg, tickets, 1, 20_000_000_000, 5, order, &mut ctx);
        let sparks = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, sparks, 1, 50_000_000_000, 50, order, &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_ORDER_ALREADY_PROCESSED)]
    fun tickets_cannot_reuse_a_sparks_order_id() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let order = std::string::utf8(b"reverse-product-order");
        let sparks = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, sparks, 1, 50_000_000_000, 50, order, &mut ctx);
        let tickets = coin::mint_for_testing<u8>(20_000_000_000, &mut ctx);
        buy_pack_v2(&mut ticket_cfg, tickets, 1, 20_000_000_000, 5, order, &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_PRICE_MISMATCH)]
    fun sparks_underpayment_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let payment = coin::mint_for_testing<u8>(49_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment, 1, 50_000_000_000, 50, std::string::utf8(b"bad-price"), &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_PRICE_MISMATCH)]
    fun sparks_stale_quote_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let payment = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment, 1, 51_000_000_000, 50, std::string::utf8(b"stale-sparks-quote"), &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_GEMS_MISMATCH)]
    fun sparks_inflated_credit_amount_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let payment = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment, 1, 50_000_000_000, 5000, std::string::utf8(b"inflated-sparks"), &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_PACK_NOT_FOUND)]
    fun nonexistent_sparks_pack_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let payment = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment, 7, 50_000_000_000, 50, std::string::utf8(b"unknown-pack"), &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_SPARKS_STORE_CONFIG_MISMATCH)]
    fun sparks_wrong_ticket_config_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg_a = config_for_testing(&mut ctx);
        let mut ticket_cfg_b = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg_a, &mut ctx);
        let payment = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg_b, &mut sparks_cfg, payment, 1, 50_000_000_000, 50, std::string::utf8(b"other-store"), &mut ctx);
        transfer::share_object(ticket_cfg_a);
        transfer::share_object(ticket_cfg_b);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_SPARKS_STORE_CONFIG_MISMATCH)]
    fun sparks_unregistered_config_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = SparksStoreConfig<u8> {
            id: object::new(&mut ctx),
            ticket_store_config_id: object::id_address(&ticket_cfg),
            vault: balance::zero<u8>(),
            paused: false,
        };
        let payment = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment, 1, 50_000_000_000, 50, std::string::utf8(b"unregistered-store"), &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
    }

    #[test]
    #[expected_failure(abort_code = E_STORE_PAUSED)]
    fun paused_sparks_store_rejects_sales() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let cap = SparksStoreAdminCapV1 {
            id: object::new(&mut ctx),
            sparks_config_id: object::id_address(&sparks_cfg),
            ticket_store_config_id: object::id_address(&ticket_cfg),
        };
        set_sparks_paused_v1(&cap, &mut sparks_cfg, true);
        let payment = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment, 1, 50_000_000_000, 50, std::string::utf8(b"paused-sparks"), &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
        let SparksStoreAdminCapV1 { id, sparks_config_id: _, ticket_store_config_id: _ } = cap;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_STORE_PAUSED)]
    fun globally_paused_ticket_store_also_blocks_sparks_purchase() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let ticket_admin = StoreAdminCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&ticket_cfg),
        };
        set_paused_v2(&ticket_admin, &mut ticket_cfg, true);
        assert!(!sparks_cfg.paused, 927);
        let payment = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(
            &mut ticket_cfg, &mut sparks_cfg, payment, 1, 50_000_000_000, 50,
            std::string::utf8(b"global-store-paused"), &mut ctx,
        );
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
        let StoreAdminCapV2 { id, config_id: _ } = ticket_admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_SPARKS_STORE_CONFIG_MISMATCH)]
    fun sparks_revenue_cap_cannot_control_unbound_store() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let cap = SparksStoreAdminCapV1 {
            id: object::new(&mut ctx),
            sparks_config_id: @0xBEEF,
            ticket_store_config_id: object::id_address(&ticket_cfg),
        };
        set_sparks_paused_v1(&cap, &mut sparks_cfg, true);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
        let SparksStoreAdminCapV1 { id, sparks_config_id: _, ticket_store_config_id: _ } = cap;
        id.delete();
    }

    #[test]
    fun sparks_revenue_withdrawal_only_moves_sparks_vault_funds() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let cap = SparksStoreAdminCapV1 {
            id: object::new(&mut ctx),
            sparks_config_id: object::id_address(&sparks_cfg),
            ticket_store_config_id: object::id_address(&ticket_cfg),
        };
        let ticket_payment = coin::mint_for_testing<u8>(20_000_000_000, &mut ctx);
        buy_pack_v2(&mut ticket_cfg, ticket_payment, 1, 20_000_000_000, 5, std::string::utf8(b"safe-ticket"), &mut ctx);
        let payment = coin::mint_for_testing<u8>(100_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment, 2, 100_000_000_000, 100, std::string::utf8(b"safe-sparks"), &mut ctx);
        withdraw_sparks_revenue_v1(&cap, &mut sparks_cfg, 10_000_000_000, @0xD00D, &mut ctx);
        assert!(balance::value(&ticket_cfg.vault) == 20_000_000_000, 920);
        assert!(balance::value(&sparks_cfg.vault) == 90_000_000_000, 921);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
        let SparksStoreAdminCapV1 { id, sparks_config_id: _, ticket_store_config_id: _ } = cap;
        id.delete();
    }

    #[test]
    fun migrated_sparks_cap_only_withdraws_from_independent_sparks_vault() {
        let administrator = @0xA11CE;
        let mut scenario = sui::test_scenario::begin(administrator);
        let mut ticket_cfg = config_for_testing(scenario.ctx());
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, scenario.ctx());
        let old_cap = SparksStoreAdminCapV1 {
            id: object::new(scenario.ctx()),
            sparks_config_id: object::id_address(&sparks_cfg),
            ticket_store_config_id: object::id_address(&ticket_cfg),
        };
        migrate_sparks_infrastructure_treasury_v2(old_cap, &sparks_cfg, @0xD00D, scenario.ctx());
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
        scenario.next_tx(administrator);
        let mut ticket_cfg = scenario.take_shared<StoreConfig<u8>>();
        let mut sparks_cfg = scenario.take_shared<SparksStoreConfig<u8>>();
        let cap = scenario.take_from_sender<SparksStoreAdminCapV2>();
        assert!(cap.infrastructure_treasury == @0xD00D, 960);
        set_sparks_paused_v2(&cap, &mut sparks_cfg, true);
        assert!(sparks_cfg.paused, 961);
        set_sparks_paused_v2(&cap, &mut sparks_cfg, false);
        let ticket_payment = coin::mint_for_testing<u8>(20_000_000_000, scenario.ctx());
        buy_pack_v2(&mut ticket_cfg, ticket_payment, 1, 20_000_000_000, 5, std::string::utf8(b"treasury-ticket"), scenario.ctx());
        let payment = coin::mint_for_testing<u8>(100_000_000_000, scenario.ctx());
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment, 2, 100_000_000_000, 100, std::string::utf8(b"treasury-sparks"), scenario.ctx());
        withdraw_sparks_infrastructure_revenue_v2(&cap, &mut sparks_cfg, 60_000_000_000, 40_000_000_000, std::string::utf8(b"treasury-sparks-sweep"), scenario.ctx());
        assert!(balance::value(&sparks_cfg.vault) == 40_000_000_000, 962);
        assert!(balance::value(&ticket_cfg.vault) == 20_000_000_000, 963);
        scenario.return_to_sender(cap);
        sui::test_scenario::return_shared(ticket_cfg);
        sui::test_scenario::return_shared(sparks_cfg);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = E_SPARKS_INVALID_WITHDRAWAL)]
    fun sparks_treasury_withdrawal_cannot_consume_pending_receipt_reserve() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let cap = SparksStoreAdminCapV2 {
            id: object::new(&mut ctx),
            sparks_config_id: object::id_address(&sparks_cfg),
            ticket_store_config_id: object::id_address(&ticket_cfg),
            infrastructure_treasury: @0xD00D,
        };
        let payment = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment, 1, 50_000_000_000, 50, std::string::utf8(b"reserve-sparks"), &mut ctx);
        withdraw_sparks_infrastructure_revenue_v2(&cap, &mut sparks_cfg, 10_000_000_000, 50_000_000_000, std::string::utf8(b"reserve-sparks-sweep"), &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
        let SparksStoreAdminCapV2 { id, sparks_config_id: _, ticket_store_config_id: _, infrastructure_treasury: _ } = cap;
        id.delete();
    }

    #[test]
    fun ticket_store_treasury_withdrawal_preserves_event_liability_reserve() {
        let administrator = @0xA11CE;
        let mut scenario = sui::test_scenario::begin(administrator);
        let mut cfg = config_for_testing(scenario.ctx());
        let admin = StoreAdminCapV2 { id: object::new(scenario.ctx()), config_id: object::id_address(&cfg) };
        bind_store_infrastructure_treasury_v1(&admin, &mut cfg, @0xD00D, scenario.ctx());
        transfer::share_object(cfg);
        scenario.next_tx(administrator);
        let mut cfg = scenario.take_shared<StoreConfig<u8>>();
        let cap = scenario.take_from_sender<StoreInfrastructureTreasuryCapV1>();
        let payment = coin::mint_for_testing<u8>(75_000_000_000, scenario.ctx());
        buy_pack_v2(&mut cfg, payment, 2, 75_000_000_000, 20, std::string::utf8(b"infra-ticket"), scenario.ctx());
        withdraw_ticket_infrastructure_revenue_v1(&cap, &mut cfg, 30_000_000_000, 45_000_000_000, std::string::utf8(b"infra-ticket-sweep"), scenario.ctx());
        assert!(balance::value(&cfg.vault) == 45_000_000_000, 964);
        scenario.return_to_sender(cap);
        sui::test_scenario::return_shared(cfg);
        let StoreAdminCapV2 { id, config_id: _ } = admin;
        id.delete();
        scenario.end();
    }

    #[test]
    fun retiring_store_event_funding_cap_preserves_treasury_cap_and_store_balance() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let admin = StoreAdminCapV2 {
            id: object::new(&mut ctx), config_id: object::id_address(&cfg),
        };
        bind_store_infrastructure_treasury_v1(&admin, &mut cfg, @0xD00D, &mut ctx);
        let treasury_cap = StoreInfrastructureTreasuryCapV1 {
            id: object::new(&mut ctx), store_config_id: object::id_address(&cfg),
            infrastructure_treasury: @0xD00D,
        };
        let old_cap = StoreEventFundingCapV2 {
            id: object::new(&mut ctx), store_config_id: object::id_address(&cfg),
            reward_config_id: @0xDACE,
        };
        let payment = coin::mint_for_testing<u8>(20_000_000_000, &mut ctx);
        buy_pack_v2(&mut cfg, payment, 1, 20_000_000_000, 5, std::string::utf8(b"retired-cap-ticket"), &mut ctx);
        retire_store_event_funding_for_treasury_v1(old_cap, &treasury_cap, &cfg);
        assert!(balance::value(&cfg.vault) == 20_000_000_000, 965);
        transfer::share_object(cfg);
        let StoreInfrastructureTreasuryCapV1 { id, store_config_id: _, infrastructure_treasury: _ } = treasury_cap;
        id.delete();
        let StoreAdminCapV2 { id, config_id: _ } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_INFRA_TREASURY_WITHDRAWAL_INVALID)]
    fun ticket_treasury_cannot_sweep_below_minimum_event_reserve() {
        let mut ctx = tx_context::dummy();
        let mut cfg = config_for_testing(&mut ctx);
        let admin = StoreAdminCapV2 { id: object::new(&mut ctx), config_id: object::id_address(&cfg) };
        bind_store_infrastructure_treasury_v1(&admin, &mut cfg, @0xD00D, &mut ctx);
        let cap = StoreInfrastructureTreasuryCapV1 {
            id: object::new(&mut ctx), store_config_id: object::id_address(&cfg), infrastructure_treasury: @0xD00D,
        };
        let payment = coin::mint_for_testing<u8>(20_000_000_000, &mut ctx);
        buy_pack_v2(&mut cfg, payment, 1, 20_000_000_000, 5, std::string::utf8(b"infra-floor"), &mut ctx);
        withdraw_ticket_infrastructure_revenue_v1(&cap, &mut cfg, 5_000_000_000, 20_000_000_000, std::string::utf8(b"infra-floor-sweep"), &mut ctx);
        transfer::share_object(cfg);
        let StoreInfrastructureTreasuryCapV1 { id, store_config_id: _, infrastructure_treasury: _ } = cap;
        id.delete();
        let StoreAdminCapV2 { id, config_id: _ } = admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_SPARKS_INVALID_WITHDRAWAL)]
    fun sparks_revenue_cannot_overwithdraw() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let cap = SparksStoreAdminCapV1 {
            id: object::new(&mut ctx),
            sparks_config_id: object::id_address(&sparks_cfg),
            ticket_store_config_id: object::id_address(&ticket_cfg),
        };
        let payment = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(&mut ticket_cfg, &mut sparks_cfg, payment, 1, 50_000_000_000, 50, std::string::utf8(b"withdraw-cap"), &mut ctx);
        withdraw_sparks_revenue_v1(&cap, &mut sparks_cfg, 51_000_000_000, @0xD00D, &mut ctx);
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
        let SparksStoreAdminCapV1 { id, sparks_config_id: _, ticket_store_config_id: _ } = cap;
        id.delete();
    }

    #[test]
    fun sparks_store_creation_binds_new_vault_to_ticket_config_once() {
        let owner = @0xA11CE;
        let mut scenario = sui::test_scenario::begin(owner);
        let mut ticket_cfg = config_for_testing(scenario.ctx());
        let ticket_cfg_id = object::id_address(&ticket_cfg);
        let ticket_admin = StoreAdminCapV2 { id: object::new(scenario.ctx()), config_id: ticket_cfg_id };
        create_sparks_store_v1(&ticket_admin, &mut ticket_cfg, scenario.ctx());
        assert!(dynamic_field::exists_with_type<SparksStoreCreationKey, address>(&ticket_cfg.id, SparksStoreCreationKey {}), 922);
        transfer::share_object(ticket_cfg);
        let StoreAdminCapV2 { id, config_id: _ } = ticket_admin;
        id.delete();
        scenario.next_tx(owner);
        let sparks_cfg = scenario.take_shared<SparksStoreConfig<u8>>();
        let sparks_admin = scenario.take_from_sender<SparksStoreAdminCapV1>();
        assert!(sparks_cfg.ticket_store_config_id == ticket_cfg_id, 923);
        assert!(sparks_admin.sparks_config_id == object::id_address(&sparks_cfg), 924);
        assert!(sparks_admin.ticket_store_config_id == ticket_cfg_id, 925);
        assert!(balance::value(&sparks_cfg.vault) == 0, 926);
        sui::test_scenario::return_shared(sparks_cfg);
        scenario.return_to_sender(sparks_admin);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = E_SPARKS_STORE_ALREADY_CREATED)]
    fun cannot_create_second_sparks_vault_for_same_ticket_store() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let ticket_admin = StoreAdminCapV2 { id: object::new(&mut ctx), config_id: object::id_address(&ticket_cfg) };
        create_sparks_store_v1(&ticket_admin, &mut ticket_cfg, &mut ctx);
        create_sparks_store_v1(&ticket_admin, &mut ticket_cfg, &mut ctx);
        transfer::share_object(ticket_cfg);
        let StoreAdminCapV2 { id, config_id: _ } = ticket_admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_STORE_CAP_CONFIG_MISMATCH)]
    fun unrelated_store_admin_cannot_initialize_sparks_custody() {
        let mut ctx = tx_context::dummy();
        let other_ticket_cfg = config_for_testing(&mut ctx);
        let mut target_ticket_cfg = config_for_testing(&mut ctx);
        let wrong_admin = StoreAdminCapV2 {
            id: object::new(&mut ctx),
            config_id: object::id_address(&other_ticket_cfg),
        };
        create_sparks_store_v1(&wrong_admin, &mut target_ticket_cfg, &mut ctx);
        transfer::share_object(other_ticket_cfg);
        transfer::share_object(target_ticket_cfg);
        let StoreAdminCapV2 { id, config_id: _ } = wrong_admin;
        id.delete();
    }

    #[test]
    #[expected_failure(abort_code = E_INVALID_ORDER_ID)]
    fun sparks_purchase_requires_nonempty_bounded_order_reference() {
        let mut ctx = tx_context::dummy();
        let mut ticket_cfg = config_for_testing(&mut ctx);
        let mut sparks_cfg = sparks_config_for_testing(&mut ticket_cfg, &mut ctx);
        let payment = coin::mint_for_testing<u8>(50_000_000_000, &mut ctx);
        buy_sparks_pack_v1(
            &mut ticket_cfg,
            &mut sparks_cfg,
            payment,
            1,
            50_000_000_000,
            50,
            std::string::utf8(b""),
            &mut ctx,
        );
        transfer::share_object(ticket_cfg);
        transfer::share_object(sparks_cfg);
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
