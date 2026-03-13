#[test_only]
module credit_protocol::credit_protocol_tests {
    use std::signer;
    use std::option;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef, BurnRef, TransferRef};
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;

    use credit_protocol::lending_pool;
    use credit_protocol::credit_manager;
    use credit_protocol::reputation_manager;


    // ============================================================
    // Test helpers
    // ============================================================

    struct TestTokenRefs has key {
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef,
    }

    fun setup_test(aptos_framework: &signer, admin: &signer): address {
        // Initialize timestamp for testing
        timestamp::set_time_has_started_for_testing(aptos_framework);

        // Create accounts
        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);

        admin_addr
    }

    fun create_test_token(admin: &signer): object::Object<Metadata> {
        let constructor_ref = object::create_named_object(admin, b"TEST_USDC");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::some(1000000000000000), // max supply
            std::string::utf8(b"Test USDC"),
            std::string::utf8(b"USDC"),
            6,
            std::string::utf8(b""),
            std::string::utf8(b""),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(&constructor_ref);

        let metadata = object::object_from_constructor_ref<Metadata>(&constructor_ref);

        move_to(admin, TestTokenRefs { mint_ref, burn_ref, transfer_ref });

        metadata
    }

    fun mint_tokens(admin: &signer, to: address, amount: u64) acquires TestTokenRefs {
        let admin_addr = signer::address_of(admin);
        let refs = borrow_global<TestTokenRefs>(admin_addr);
        let fa = fungible_asset::mint(&refs.mint_ref, amount);
        let metadata = fungible_asset::mint_ref_metadata(&refs.mint_ref);
        let store = primary_fungible_store::ensure_primary_store_exists(to, metadata);
        fungible_asset::deposit(store, fa);
    }

    fun setup_protocol(
        aptos_framework: &signer,
        admin: &signer,
    ): (address, object::Object<Metadata>) acquires TestTokenRefs {
        let admin_addr = setup_test(aptos_framework, admin);
        let token_metadata = create_test_token(admin);
        let token_metadata_addr = object::object_address(&token_metadata);

        // Initialize lending pool
        lending_pool::initialize(admin, admin_addr, token_metadata_addr);

        // Initialize reputation manager
        reputation_manager::initialize(admin, admin_addr);

        // Initialize credit manager
        credit_manager::initialize(
            admin,
            admin_addr, // lending_pool_addr
            admin_addr, // reputation_manager_addr
            token_metadata_addr,
        );

        // Update lending pool to point to credit_manager
        lending_pool::update_credit_manager(admin, admin_addr, admin_addr);

        // Mint tokens to admin for initial pool liquidity
        mint_tokens(admin, admin_addr, 100000000000); // 100,000 USDC

        // Admin deposits into lending pool as lender
        lending_pool::deposit(admin, admin_addr, 50000000000); // 50,000 USDC

        (admin_addr, token_metadata)
    }

    // ============================================================
    // Initialization tests
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol)]
    fun test_initialize_all_modules(aptos_framework: &signer, admin: &signer) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);

        // Verify lending pool
        assert!(lending_pool::get_admin(admin_addr) == admin_addr, 1);
        assert!(lending_pool::get_total_deposited(admin_addr) == 50000000000, 2);
        assert!(!lending_pool::is_paused(admin_addr), 3);

        // Verify reputation manager
        assert!(reputation_manager::get_admin(admin_addr) == admin_addr, 4);
        assert!(!reputation_manager::is_paused(admin_addr), 5);

        // Verify credit manager
        assert!(credit_manager::get_admin(admin_addr) == admin_addr, 6);
        assert!(!credit_manager::is_paused(admin_addr), 7);

        // Dead modules (interest_rate_model, collateral_vault) removed per C-03/C-04
    }

    #[test(aptos_framework = @0x1, admin = @credit_protocol)]
    #[expected_failure(abort_code = 524293, location = credit_protocol::lending_pool)]
    fun test_double_initialize_lending_pool_fails(aptos_framework: &signer, admin: &signer) acquires TestTokenRefs {
        let (admin_addr, token) = setup_protocol(aptos_framework, admin);
        let token_addr = object::object_address(&token);
        // Second init should fail with E_ALREADY_INITIALIZED
        lending_pool::initialize(admin, admin_addr, token_addr);
    }

    // ============================================================
    // Core flow: open credit line → borrow → repay
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    fun test_full_borrow_repay_cycle(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        // Mint USDC to borrower for collateral
        mint_tokens(admin, borrower_addr, 10000000); // 10 USDC

        // Open credit line with 5 USDC collateral
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);

        // Verify credit line exists
        let (collateral, credit_limit, borrowed, _interest, _total_debt, _due, is_active) =
            credit_manager::get_credit_info(admin_addr, borrower_addr);
        assert!(collateral == 5000000, 1);
        assert!(credit_limit == 5000000, 2);
        assert!(borrowed == 0, 3);
        assert!(is_active, 4);

        // Borrow 2 USDC
        credit_manager::borrow(borrower, admin_addr, 2000000);

        // Verify borrowed amount
        let (_col, _lim, borrowed_after, _int, _debt, _due, _active) =
            credit_manager::get_credit_info(admin_addr, borrower_addr);
        assert!(borrowed_after == 2000000, 5);

        // Advance time 1 day
        timestamp::fast_forward_seconds(86400);

        // Repay principal (2 USDC) + any small interest
        let (_col2, _lim2, _bor2, interest_accrued, _debt2, _due2, _active2) =
            credit_manager::get_credit_info(admin_addr, borrower_addr);

        // Mint enough for interest payment
        if (interest_accrued > 0) {
            mint_tokens(admin, borrower_addr, interest_accrued);
        };

        credit_manager::repay(borrower, admin_addr, 2000000, interest_accrued);

        // Verify fully repaid
        let (_col3, _lim3, borrowed_final, _int3, _debt3, _due3, _active3) =
            credit_manager::get_credit_info(admin_addr, borrower_addr);
        assert!(borrowed_final == 0, 6);

        // Verify reputation was updated (on-time repayment)
        let (on_time, late, _total_repaid) =
            credit_manager::get_repayment_history(admin_addr, borrower_addr);
        assert!(on_time == 1, 7);
        assert!(late == 0, 8);
    }

    // ============================================================
    // Borrow and pay (direct payment to recipient)
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B, recipient = @0xCAFE)]
    fun test_borrow_and_pay_direct(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
        recipient: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        let recipient_addr = signer::address_of(recipient);
        account::create_account_for_test(borrower_addr);
        account::create_account_for_test(recipient_addr);

        // Mint collateral to borrower
        mint_tokens(admin, borrower_addr, 5000000);

        // Open credit line
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);

        // Borrow and pay directly to recipient
        credit_manager::borrow_and_pay(borrower, admin_addr, recipient_addr, 1000000);

        // Verify recipient received funds
        let recipient_balance = primary_fungible_store::balance(recipient_addr, token);
        assert!(recipient_balance == 1000000, 1);

        // Verify borrower has the debt
        let (_col, _lim, borrowed, _int, _debt, _due, _active) =
            credit_manager::get_credit_info(admin_addr, borrower_addr);
        assert!(borrowed == 1000000, 2);
    }

    // ============================================================
    // Liquidation tests (CRITICAL-2 fix validation)
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    fun test_liquidation_keeps_funds_in_pool(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        // Mint collateral
        mint_tokens(admin, borrower_addr, 5000000);

        // Open credit line and borrow max
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);
        credit_manager::borrow(borrower, admin_addr, 4000000);

        // Record borrower's balance before liquidation
        let borrower_balance_before = primary_fungible_store::balance(borrower_addr, token);

        // Advance time past repayment due date to trigger overdue
        timestamp::fast_forward_seconds(6000000); // ~69 days

        // Admin liquidates
        credit_manager::liquidate(admin, admin_addr, borrower_addr);

        // Verify: borrower did NOT receive collateral back (critical fix for CRITICAL-2)
        let borrower_balance_after = primary_fungible_store::balance(borrower_addr, token);
        assert!(borrower_balance_after == borrower_balance_before, 1);

        // Verify: collateral was partially seized (debt < collateral, so some remains)
        let (remaining_principal, _interest, _total) = lending_pool::get_collateral_with_interest(admin_addr, borrower_addr);
        assert!(remaining_principal < 5000000, 2); // Less than original 5 USDC collateral

        // Verify: debt is cleared after liquidation
        let (_col, _lim, borrowed, _int, _debt, _due, _is_active) =
            credit_manager::get_credit_info(admin_addr, borrower_addr);
        assert!(borrowed == 0, 3);
        // Note: credit line stays active if surplus collateral remains (partial seizure)
        // This is correct — only total_debt worth of collateral was seized
    }

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    #[expected_failure(abort_code = 196617, location = credit_protocol::credit_manager)]
    fun test_liquidation_fails_when_not_eligible(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 5000000);

        // Open credit line and borrow small amount (healthy position)
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);
        credit_manager::borrow(borrower, admin_addr, 1000000);

        // Try to liquidate immediately — should fail (not overdue, not over LTV)
        credit_manager::liquidate(admin, admin_addr, borrower_addr);
    }

    // ============================================================
    // Lender interest withdrawal tests (HIGH-5 fix validation)
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, lender = @0xAAA, borrower = @0xB0B)]
    fun test_lender_can_withdraw_interest(
        aptos_framework: &signer,
        admin: &signer,
        lender: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, token) = setup_protocol(aptos_framework, admin);
        let lender_addr = signer::address_of(lender);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(lender_addr);
        account::create_account_for_test(borrower_addr);

        // Lender deposits 10 USDC
        mint_tokens(admin, lender_addr, 10000000);
        lending_pool::deposit(lender, admin_addr, 10000000);

        // Setup borrower
        mint_tokens(admin, borrower_addr, 5000000);
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);
        credit_manager::borrow(borrower, admin_addr, 2000000);

        // Advance time for interest accrual
        timestamp::fast_forward_seconds(86400 * 30); // 30 days

        // Borrower repays with interest
        let (_col, _lim, _bor, interest, _debt, _due, _active) =
            credit_manager::get_credit_info(admin_addr, borrower_addr);
        if (interest > 0) {
            mint_tokens(admin, borrower_addr, interest);
        };
        credit_manager::repay(borrower, admin_addr, 2000000, interest);

        // Check lender earned interest
        let (_deposited, earned_interest, _ts) = lending_pool::get_lender_info(admin_addr, lender_addr);

        // If interest was distributed, lender should be able to withdraw it
        if (earned_interest > 0) {
            let balance_before = primary_fungible_store::balance(lender_addr, token);
            lending_pool::withdraw(lender, admin_addr, earned_interest);
            let balance_after = primary_fungible_store::balance(lender_addr, token);
            assert!(balance_after == balance_before + earned_interest, 1);
        };
    }

    // ============================================================
    // Authorization tests
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, non_admin = @0xBAD)]
    #[expected_failure(abort_code = 327681, location = credit_protocol::credit_manager)]
    fun test_non_admin_cannot_liquidate(
        aptos_framework: &signer,
        admin: &signer,
        non_admin: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let non_admin_addr = signer::address_of(non_admin);
        account::create_account_for_test(non_admin_addr);

        // Non-admin tries to liquidate — should fail
        credit_manager::liquidate(non_admin, admin_addr, @0xB0B);
    }

    #[test(aptos_framework = @0x1, admin = @credit_protocol, non_admin = @0xBAD)]
    #[expected_failure(abort_code = 327681, location = credit_protocol::credit_manager)]
    fun test_non_admin_cannot_pause(
        aptos_framework: &signer,
        admin: &signer,
        non_admin: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let non_admin_addr = signer::address_of(non_admin);
        account::create_account_for_test(non_admin_addr);

        credit_manager::pause(non_admin, admin_addr);
    }

    #[test(aptos_framework = @0x1, admin = @credit_protocol, non_admin = @0xBAD)]
    #[expected_failure(abort_code = 327681, location = credit_protocol::lending_pool)]
    fun test_non_admin_cannot_withdraw_fees(
        aptos_framework: &signer,
        admin: &signer,
        non_admin: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let non_admin_addr = signer::address_of(non_admin);
        account::create_account_for_test(non_admin_addr);

        lending_pool::withdraw_protocol_fees(non_admin, admin_addr, non_admin_addr, 1000);
    }

    // ============================================================
    // Edge case / failure tests
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    #[expected_failure(abort_code = 65538, location = credit_protocol::credit_manager)]
    fun test_borrow_zero_amount_fails(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 5000000);
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);

        // Borrow 0 should fail
        credit_manager::borrow(borrower, admin_addr, 0);
    }

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    #[expected_failure(abort_code = 65550, location = credit_protocol::credit_manager)]
    fun test_borrow_below_minimum_fails(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 5000000);
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);

        // Borrow below MIN_BORROW_AMOUNT (100000 = 0.1 USDC) should fail
        credit_manager::borrow(borrower, admin_addr, 50000);
    }

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    #[expected_failure(abort_code = 196613, location = credit_protocol::credit_manager)]
    fun test_borrow_exceeds_credit_limit_fails(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 2000000);
        credit_manager::open_credit_line(borrower, admin_addr, 2000000);

        // Try to borrow more than credit limit
        credit_manager::borrow(borrower, admin_addr, 3000000);
    }

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    #[expected_failure(abort_code = 65550, location = credit_protocol::credit_manager)]
    fun test_collateral_below_minimum_fails(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 1000000);

        // Open with below MIN_COLLATERAL_AMOUNT should fail
        credit_manager::open_credit_line(borrower, admin_addr, 500000);
    }

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    #[expected_failure(abort_code = 524291, location = credit_protocol::credit_manager)]
    fun test_duplicate_credit_line_fails(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 10000000);

        credit_manager::open_credit_line(borrower, admin_addr, 5000000);
        // Second open should fail
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);
    }

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    #[expected_failure(abort_code = 196624, location = credit_protocol::credit_manager)]
    fun test_withdraw_collateral_with_debt_fails(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 5000000);
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);
        credit_manager::borrow(borrower, admin_addr, 1000000);

        // Try to withdraw collateral while having debt — should fail
        credit_manager::withdraw_collateral(borrower, admin_addr, 1000000);
    }

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    #[expected_failure(abort_code = 65543, location = credit_protocol::credit_manager)]
    fun test_repay_more_than_borrowed_fails(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 10000000);
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);
        credit_manager::borrow(borrower, admin_addr, 1000000);

        // Repay more than borrowed
        credit_manager::repay(borrower, admin_addr, 2000000, 0);
    }

    // ============================================================
    // Pause tests
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    #[expected_failure(abort_code = 196609, location = credit_protocol::credit_manager)]
    fun test_borrow_when_paused_fails(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 5000000);
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);

        // Pause the protocol
        credit_manager::pause(admin, admin_addr);

        // Borrow should fail when paused
        credit_manager::borrow(borrower, admin_addr, 1000000);
    }

    // ============================================================
    // Collateral withdrawal (full cycle)
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    fun test_withdraw_collateral_after_repay(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 10000000);

        // Open credit line
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);

        // Borrow and repay
        credit_manager::borrow(borrower, admin_addr, 1000000);
        credit_manager::repay(borrower, admin_addr, 1000000, 0);

        let balance_before = primary_fungible_store::balance(borrower_addr, token);

        // Withdraw collateral
        credit_manager::withdraw_collateral(borrower, admin_addr, 5000000);

        let balance_after = primary_fungible_store::balance(borrower_addr, token);
        assert!(balance_after > balance_before, 1);

        // Credit line should be inactive after full withdrawal
        let (_col, _lim, _bor, _int, _debt, _due, is_active) =
            credit_manager::get_credit_info(admin_addr, borrower_addr);
        assert!(!is_active, 2);
    }

    // ============================================================
    // Admin transfer (2-step) test
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, new_admin = @0xAD1)]
    fun test_admin_transfer_two_step(
        aptos_framework: &signer,
        admin: &signer,
        new_admin: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let new_admin_addr = signer::address_of(new_admin);
        account::create_account_for_test(new_admin_addr);

        // Step 1: Initiate transfer
        credit_manager::transfer_admin(admin, admin_addr, new_admin_addr);

        // Step 2: New admin accepts
        credit_manager::accept_admin(new_admin, admin_addr);

        // Verify new admin
        assert!(credit_manager::get_admin(admin_addr) == new_admin_addr, 1);
    }

    // ============================================================
    // Add collateral and reactivation test
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, borrower = @0xB0B)]
    fun test_add_collateral_to_existing_line(
        aptos_framework: &signer,
        admin: &signer,
        borrower: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let borrower_addr = signer::address_of(borrower);
        account::create_account_for_test(borrower_addr);

        mint_tokens(admin, borrower_addr, 15000000);

        // Open with 5 USDC
        credit_manager::open_credit_line(borrower, admin_addr, 5000000);

        // Add 3 more USDC collateral
        credit_manager::add_collateral(borrower, admin_addr, 3000000);

        // Credit limit should now reflect 8 USDC
        let (collateral, _lim, _bor, _int, _debt, _due, _active) =
            credit_manager::get_credit_info(admin_addr, borrower_addr);
        assert!(collateral == 8000000, 1);
    }

    // ============================================================
    // Lender deposit below minimum fails
    // ============================================================

    #[test(aptos_framework = @0x1, admin = @credit_protocol, lender = @0xAAA)]
    #[expected_failure(abort_code = 65546, location = credit_protocol::lending_pool)]
    fun test_lender_deposit_below_minimum_fails(
        aptos_framework: &signer,
        admin: &signer,
        lender: &signer,
    ) acquires TestTokenRefs {
        let (admin_addr, _token) = setup_protocol(aptos_framework, admin);
        let lender_addr = signer::address_of(lender);
        account::create_account_for_test(lender_addr);

        mint_tokens(admin, lender_addr, 500000);

        // Deposit below MIN_DEPOSIT_AMOUNT (1 USDC = 1000000) should fail
        lending_pool::deposit(lender, admin_addr, 500000);
    }
}
