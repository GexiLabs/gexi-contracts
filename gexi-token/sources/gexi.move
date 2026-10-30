module gexi_token::gexi {
    use std::string;
    use sui::coin;
    use sui::coin_registry;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const DECIMALS: u8 = 9;
    const INITIAL_SUPPLY: u64 = 100_000_000_000_000_000;

    /// Fresh-mainnet GEXI one-time witness.
    public struct GEXI has drop {}

    fun new_currency(
        witness: GEXI,
        ctx: &mut TxContext,
    ): (coin_registry::CurrencyInitializer<GEXI>, coin::TreasuryCap<GEXI>) {
        coin_registry::new_currency_with_otw(
            witness,
            DECIMALS,
            string::utf8(b"GEXI"),
            string::utf8(b"Gexi"),
            string::utf8(b"Gexi in-game currency"),
            string::utf8(b"https://ipfs.filebase.io/ipfs/QmWhQviYYoNGsMo9mgb7arcieTJtmPf2My7nFEEJFk5PqN"),
            ctx,
        )
    }

    fun init(witness: GEXI, ctx: &mut TxContext) {
        let (mut currency, mut treasury_cap) = new_currency(witness, ctx);

        // Mint the entire 100M supply exactly once during package publication.
        // The publish signer must therefore be the intended initial-supply
        // custody wallet.
        let initial_supply = coin::mint(&mut treasury_cap, INITIAL_SUPPLY, ctx);

        // Permanently remove mint authority before Currency finalization.
        currency.make_supply_burn_only(treasury_cap);

        // Metadata is final at launch. Do not leave a metadata admin capability.
        currency.finalize_and_delete_metadata_cap(ctx);

        transfer::public_transfer(initial_supply, tx_context::sender(ctx));
    }

    #[test, expected_failure(abort_code = 0)]
    fun token_configuration_is_final() {
        let ctx = &mut tx_context::dummy();
        let (mut currency, mut treasury_cap) = new_currency(GEXI {}, ctx);
        let expected_supply = INITIAL_SUPPLY;
        let initial_supply = coin::mint(&mut treasury_cap, expected_supply, ctx);
        currency.make_supply_burn_only(treasury_cap);
        let (currency, _metadata_cap) =
            coin_registry::finalize_unwrap_for_testing(currency, ctx);

        assert!(coin_registry::decimals(&currency) == DECIMALS, 1);
        assert!(coin_registry::symbol(&currency) == string::utf8(b"GEXI"), 2);
        assert!(coin_registry::name(&currency) == string::utf8(b"Gexi"), 3);
        assert!(
            coin_registry::description(&currency) == string::utf8(b"Gexi in-game currency"),
            4,
        );
        assert!(
            coin_registry::icon_url(&currency) ==
                string::utf8(b"https://ipfs.filebase.io/ipfs/QmWhQviYYoNGsMo9mgb7arcieTJtmPf2My7nFEEJFk5PqN"),
            5,
        );
        assert!(coin_registry::is_supply_burn_only(&currency), 6);
        assert!(
            coin_registry::total_supply(&currency).is_some_and!(|value| value == expected_supply),
            7,
        );
        assert!(coin::value(&initial_supply) == expected_supply, 8);

        // Abort only to discard test-owned objects. The exact abort code makes
        // any earlier assertion failure fail the test.
        abort 0
    }
}
