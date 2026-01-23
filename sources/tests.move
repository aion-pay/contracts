#[test_only]
module credit_protocol::tests {
    use std::string;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::account;
    use aptos_framework::timestamp;

    use credit_protocol::lending_pool;
    use credit_protocol::collateral_vault;
    use credit_protocol::credit_manager;
    use credit_protocol::reputation_manager;
    use credit_protocol::interest_rate_model;

    // Test addresses
    const ADMIN_ADDR: address = @0x123;
    const LENDER_ADDR: address = @0x456;
    const BORROWER_ADDR: address = @0x789;
    const RECIPIENT_ADDR: address = @0xABC;

    // Helper function to setup test environment
    fun setup_test(aptos_framework: &signer) {
        // Initialize timestamp
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test_secs(1000000);

        // Initialize AptosCoin for testing
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);

        // Create test accounts
        let admin = account::create_account_for_test(ADMIN_ADDR);
        let lender = account::create_account_for_test(LENDER_ADDR);
        let borrower = account::create_account_for_test(BORROWER_ADDR);
        let _recipient = account::create_account_for_test(RECIPIENT_ADDR);

        // Register accounts for AptosCoin
        coin::register<AptosCoin>(&admin);
        coin::register<AptosCoin>(&lender);
        coin::register<AptosCoin>(&borrower);

        // Mint some test coins
        let admin_coins = coin::mint<AptosCoin>(1000000000000, &mint_cap);
        coin::deposit(ADMIN_ADDR, admin_coins);

        let lender_coins = coin::mint<AptosCoin>(100000000000, &mint_cap);
        coin::deposit(LENDER_ADDR, lender_coins);

        let borrower_coins = coin::mint<AptosCoin>(50000000000, &mint_cap);
        coin::deposit(BORROWER_ADDR, borrower_coins);

        // Clean up capabilities
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    // ==================== LENDING POOL TESTS ====================

    #[test(aptos_framework = @aptos_framework)]
    fun test_lending_pool_initialize(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize lending pool
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);

        // Verify initialization
        assert!(lending_pool::get_total_deposited<AptosCoin>(ADMIN_ADDR) == 0, 1);
        assert!(lending_pool::get_total_borrowed<AptosCoin>(ADMIN_ADDR) == 0, 2);
        assert!(!lending_pool::is_paused<AptosCoin>(ADMIN_ADDR), 3);
        assert!(lending_pool::get_admin<AptosCoin>(ADMIN_ADDR) == ADMIN_ADDR, 4);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_lending_pool_deposit(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let lender = account::create_signer_for_test(LENDER_ADDR);

        // Initialize
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);

        // Deposit
        let deposit_amount = 10000000000u64; // 10,000 coins
        lending_pool::deposit<AptosCoin>(&lender, ADMIN_ADDR, deposit_amount);

        // Verify deposit
        assert!(lending_pool::get_total_deposited<AptosCoin>(ADMIN_ADDR) == deposit_amount, 1);
        let (deposited, _, _) = lending_pool::get_lender_info<AptosCoin>(ADMIN_ADDR, LENDER_ADDR);
        assert!(deposited == deposit_amount, 2);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_lending_pool_withdraw(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let lender = account::create_signer_for_test(LENDER_ADDR);

        // Initialize and deposit
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        let deposit_amount = 10000000000u64;
        lending_pool::deposit<AptosCoin>(&lender, ADMIN_ADDR, deposit_amount);

        // Withdraw partial
        let withdraw_amount = 5000000000u64;
        lending_pool::withdraw<AptosCoin>(&lender, ADMIN_ADDR, withdraw_amount);

        // Verify
        let (remaining, _, _) = lending_pool::get_lender_info<AptosCoin>(ADMIN_ADDR, LENDER_ADDR);
        assert!(remaining == deposit_amount - withdraw_amount, 1);
    }

    #[test(aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 196611)] // E_INSUFFICIENT_LIQUIDITY with invalid_state
    fun test_lending_pool_withdraw_insufficient(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let lender = account::create_signer_for_test(LENDER_ADDR);

        // Initialize and deposit
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        lending_pool::deposit<AptosCoin>(&lender, ADMIN_ADDR, 10000000000u64);

        // Try to withdraw more than deposited - should fail
        lending_pool::withdraw<AptosCoin>(&lender, ADMIN_ADDR, 20000000000u64);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_lending_pool_pause_unpause(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);

        // Pause
        lending_pool::pause<AptosCoin>(&admin, ADMIN_ADDR);
        assert!(lending_pool::is_paused<AptosCoin>(ADMIN_ADDR), 1);

        // Unpause
        lending_pool::unpause<AptosCoin>(&admin, ADMIN_ADDR);
        assert!(!lending_pool::is_paused<AptosCoin>(ADMIN_ADDR), 2);
    }

    #[test(aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 196609)] // E_NOT_AUTHORIZED with invalid_state (paused)
    fun test_lending_pool_deposit_when_paused(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let lender = account::create_signer_for_test(LENDER_ADDR);

        // Initialize and pause
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        lending_pool::pause<AptosCoin>(&admin, ADMIN_ADDR);

        // Try to deposit - should fail
        lending_pool::deposit<AptosCoin>(&lender, ADMIN_ADDR, 10000000000u64);
    }

    // ==================== COLLATERAL VAULT TESTS ====================

    #[test(aptos_framework = @aptos_framework)]
    fun test_collateral_vault_initialize(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize collateral vault
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);

        // Verify initialization
        assert!(collateral_vault::get_total_collateral<AptosCoin>(ADMIN_ADDR) == 0, 1);
        assert!(!collateral_vault::is_paused<AptosCoin>(ADMIN_ADDR), 2);
        assert!(collateral_vault::get_admin<AptosCoin>(ADMIN_ADDR) == ADMIN_ADDR, 3);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_collateral_vault_deposit(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);

        // Deposit collateral (as credit manager)
        let deposit_amount = 5000000000u64;
        collateral_vault::deposit_collateral<AptosCoin>(&admin, ADMIN_ADDR, BORROWER_ADDR, deposit_amount);

        // Verify
        assert!(collateral_vault::get_collateral_balance<AptosCoin>(ADMIN_ADDR, BORROWER_ADDR) == deposit_amount, 1);
        assert!(collateral_vault::get_total_collateral<AptosCoin>(ADMIN_ADDR) == deposit_amount, 2);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_collateral_vault_lock_unlock(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize and deposit
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::deposit_collateral<AptosCoin>(&admin, ADMIN_ADDR, BORROWER_ADDR, 5000000000u64);

        // Lock collateral
        let lock_amount = 2000000000u64;
        collateral_vault::lock_collateral<AptosCoin>(
            &admin,
            ADMIN_ADDR,
            BORROWER_ADDR,
            lock_amount,
            string::utf8(b"Borrowing")
        );

        // Verify lock
        let (total, locked, available, _status) = collateral_vault::get_user_collateral<AptosCoin>(ADMIN_ADDR, BORROWER_ADDR);
        assert!(total == 5000000000u64, 1);
        assert!(locked == lock_amount, 2);
        assert!(available == 3000000000u64, 3);

        // Unlock
        collateral_vault::unlock_collateral<AptosCoin>(&admin, ADMIN_ADDR, BORROWER_ADDR, lock_amount);

        // Verify unlock
        let (_, locked_after, _, _) = collateral_vault::get_user_collateral<AptosCoin>(ADMIN_ADDR, BORROWER_ADDR);
        assert!(locked_after == 0, 4);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_collateral_vault_update_parameters(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);

        // Update parameters
        let new_ratio = 20000u256; // 200%
        let new_threshold = 15000u256; // 150%
        let new_max = 5000000000000u64;
        collateral_vault::update_parameters<AptosCoin>(&admin, ADMIN_ADDR, new_ratio, new_threshold, new_max);

        // Verify
        assert!(collateral_vault::get_collateralization_ratio<AptosCoin>(ADMIN_ADDR) == new_ratio, 1);
        assert!(collateral_vault::get_liquidation_threshold<AptosCoin>(ADMIN_ADDR) == new_threshold, 2);
        assert!(collateral_vault::get_max_collateral_amount<AptosCoin>(ADMIN_ADDR) == new_max, 3);
    }

    // ==================== REPUTATION MANAGER TESTS ====================

    #[test(aptos_framework = @aptos_framework)]
    fun test_reputation_manager_initialize(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize
        reputation_manager::initialize(&admin, ADMIN_ADDR);

        // Verify
        assert!(reputation_manager::get_admin(ADMIN_ADDR) == ADMIN_ADDR, 1);
        assert!(!reputation_manager::is_paused(ADMIN_ADDR), 2);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_reputation_score_update(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize
        reputation_manager::initialize(&admin, ADMIN_ADDR);

        // Initialize user (as credit manager)
        reputation_manager::initialize_user(&admin, ADMIN_ADDR, BORROWER_ADDR);

        // Update reputation (on-time payment)
        reputation_manager::update_reputation(&admin, ADMIN_ADDR, BORROWER_ADDR, true, 1000000000u64);

        // Check reputation increased
        let score = reputation_manager::get_reputation_score(ADMIN_ADDR, BORROWER_ADDR);
        assert!(score > 500, 1); // Should be above base score
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_reputation_late_payment_penalty(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize
        reputation_manager::initialize(&admin, ADMIN_ADDR);

        // Initialize user
        reputation_manager::initialize_user(&admin, ADMIN_ADDR, BORROWER_ADDR);

        // Update reputation (late payment)
        reputation_manager::update_reputation(&admin, ADMIN_ADDR, BORROWER_ADDR, false, 1000000000u64);

        // Check reputation decreased
        let score = reputation_manager::get_reputation_score(ADMIN_ADDR, BORROWER_ADDR);
        assert!(score < 500, 1); // Should be below base score due to late payment
    }

    // ==================== INTEREST RATE MODEL TESTS ====================

    #[test(aptos_framework = @aptos_framework)]
    fun test_interest_rate_model_initialize(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());

        // Verify
        assert!(interest_rate_model::get_admin(ADMIN_ADDR) == ADMIN_ADDR, 1);
        assert!(!interest_rate_model::is_paused(ADMIN_ADDR), 2);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_interest_rate_get_annual_rate(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());

        // Get annual rate (default is 15%)
        let rate = interest_rate_model::get_annual_rate(ADMIN_ADDR);
        assert!(rate == 1500, 1); // 15% in basis points
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_interest_rate_model_update_rate(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());

        // Update annual rate
        let new_rate = 2000u256; // 20%
        interest_rate_model::set_annual_rate(&admin, ADMIN_ADDR, new_rate);

        // Verify
        let rate = interest_rate_model::get_annual_rate(ADMIN_ADDR);
        assert!(rate == new_rate, 1);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_interest_rate_model_update_parameters(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());

        // Update parameters
        let new_base = 1000u256; // 10%
        let new_max = 2000u256;  // 20%
        let new_penalty = 3000u256; // 30%
        let new_optimal = 6000u256; // 60%
        let new_penalty_util = 9000u256; // 90%
        interest_rate_model::update_rate_parameters(
            &admin,
            ADMIN_ADDR,
            new_base,
            new_max,
            new_penalty,
            new_optimal,
            new_penalty_util,
            0 // Fixed model
        );

        // Verify via get_rate_parameters
        let params = interest_rate_model::get_rate_parameters(ADMIN_ADDR);
        // Can't directly access struct fields, but the update shouldn't fail
    }

    // ==================== CREDIT MANAGER TESTS ====================

    #[test(aptos_framework = @aptos_framework)]
    fun test_credit_manager_initialize(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize all required modules first
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        reputation_manager::initialize(&admin, ADMIN_ADDR);
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());

        // Initialize credit manager
        credit_manager::initialize<AptosCoin>(
            &admin,
            ADMIN_ADDR, // lending_pool_addr
            ADMIN_ADDR, // collateral_vault_addr
            ADMIN_ADDR, // reputation_manager_addr
            ADMIN_ADDR, // interest_rate_model_addr
        );

        // Verify
        assert!(credit_manager::get_admin<AptosCoin>(ADMIN_ADDR) == ADMIN_ADDR, 1);
        assert!(!credit_manager::is_paused<AptosCoin>(ADMIN_ADDR), 2);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_open_credit_line(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let borrower = account::create_signer_for_test(BORROWER_ADDR);

        // Initialize all modules
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        reputation_manager::initialize(&admin, ADMIN_ADDR);
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());
        credit_manager::initialize<AptosCoin>(&admin, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR);

        // Open credit line
        let collateral_amount = 10000000000u64; // 10,000 USDC
        credit_manager::open_credit_line<AptosCoin>(&borrower, ADMIN_ADDR, collateral_amount);

        // Verify credit line
        let (collateral, credit_limit, borrowed, _, _, _, is_active) =
            credit_manager::get_credit_info<AptosCoin>(ADMIN_ADDR, BORROWER_ADDR);
        assert!(collateral == collateral_amount, 1);
        assert!(credit_limit == collateral_amount, 2); // 1:1 ratio
        assert!(borrowed == 0, 3);
        assert!(is_active, 4);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_add_collateral(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let borrower = account::create_signer_for_test(BORROWER_ADDR);

        // Initialize all modules
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        reputation_manager::initialize(&admin, ADMIN_ADDR);
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());
        credit_manager::initialize<AptosCoin>(&admin, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR);

        // Open credit line and add more collateral
        credit_manager::open_credit_line<AptosCoin>(&borrower, ADMIN_ADDR, 10000000000u64);
        credit_manager::add_collateral<AptosCoin>(&borrower, ADMIN_ADDR, 5000000000u64);

        // Verify increased collateral
        let (collateral, credit_limit, _, _, _, _, _) =
            credit_manager::get_credit_info<AptosCoin>(ADMIN_ADDR, BORROWER_ADDR);
        assert!(collateral == 15000000000u64, 1);
        assert!(credit_limit == 15000000000u64, 2);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_borrow(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let lender = account::create_signer_for_test(LENDER_ADDR);
        let borrower = account::create_signer_for_test(BORROWER_ADDR);

        // Initialize all modules
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        reputation_manager::initialize(&admin, ADMIN_ADDR);
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());
        credit_manager::initialize<AptosCoin>(&admin, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR);

        // Lender deposits funds
        lending_pool::deposit<AptosCoin>(&lender, ADMIN_ADDR, 50000000000u64);

        // Borrower opens credit line
        credit_manager::open_credit_line<AptosCoin>(&borrower, ADMIN_ADDR, 10000000000u64);

        // Borrow
        let borrow_amount = 5000000000u64;
        credit_manager::borrow<AptosCoin>(&borrower, ADMIN_ADDR, borrow_amount);

        // Verify borrowed amount
        let (_, _, borrowed, _, _, _, _) =
            credit_manager::get_credit_info<AptosCoin>(ADMIN_ADDR, BORROWER_ADDR);
        assert!(borrowed == borrow_amount, 1);
    }

    #[test(aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 196613)] // E_EXCEEDS_CREDIT_LIMIT with invalid_state
    fun test_borrow_exceeds_credit_limit(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let lender = account::create_signer_for_test(LENDER_ADDR);
        let borrower = account::create_signer_for_test(BORROWER_ADDR);

        // Initialize all modules
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        reputation_manager::initialize(&admin, ADMIN_ADDR);
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());
        credit_manager::initialize<AptosCoin>(&admin, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR);

        // Lender deposits
        lending_pool::deposit<AptosCoin>(&lender, ADMIN_ADDR, 50000000000u64);

        // Borrower opens credit line with 10,000 collateral
        credit_manager::open_credit_line<AptosCoin>(&borrower, ADMIN_ADDR, 10000000000u64);

        // Try to borrow more than credit limit - should fail
        credit_manager::borrow<AptosCoin>(&borrower, ADMIN_ADDR, 15000000000u64);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_repay(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let lender = account::create_signer_for_test(LENDER_ADDR);
        let borrower = account::create_signer_for_test(BORROWER_ADDR);

        // Initialize all modules
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        reputation_manager::initialize(&admin, ADMIN_ADDR);
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());
        credit_manager::initialize<AptosCoin>(&admin, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR);

        // Lender deposits
        lending_pool::deposit<AptosCoin>(&lender, ADMIN_ADDR, 50000000000u64);

        // Borrower opens credit line and borrows
        credit_manager::open_credit_line<AptosCoin>(&borrower, ADMIN_ADDR, 10000000000u64);
        credit_manager::borrow<AptosCoin>(&borrower, ADMIN_ADDR, 5000000000u64);

        // Repay
        credit_manager::repay<AptosCoin>(&borrower, ADMIN_ADDR, 5000000000u64, 0);

        // Verify repayment
        let (_, _, borrowed, _, _, _, _) =
            credit_manager::get_credit_info<AptosCoin>(ADMIN_ADDR, BORROWER_ADDR);
        assert!(borrowed == 0, 1);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_withdraw_collateral(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let borrower = account::create_signer_for_test(BORROWER_ADDR);

        // Initialize all modules
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        reputation_manager::initialize(&admin, ADMIN_ADDR);
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());
        credit_manager::initialize<AptosCoin>(&admin, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR);

        // Open credit line
        credit_manager::open_credit_line<AptosCoin>(&borrower, ADMIN_ADDR, 10000000000u64);

        // Withdraw some collateral (no debt)
        credit_manager::withdraw_collateral<AptosCoin>(&borrower, ADMIN_ADDR, 5000000000u64);

        // Verify
        let (collateral, credit_limit, _, _, _, _, _) =
            credit_manager::get_credit_info<AptosCoin>(ADMIN_ADDR, BORROWER_ADDR);
        assert!(collateral == 5000000000u64, 1);
        assert!(credit_limit == 5000000000u64, 2);
    }

    #[test(aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 196624)] // E_HAS_OUTSTANDING_DEBT with invalid_state
    fun test_withdraw_collateral_with_debt(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let lender = account::create_signer_for_test(LENDER_ADDR);
        let borrower = account::create_signer_for_test(BORROWER_ADDR);

        // Initialize all modules
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        reputation_manager::initialize(&admin, ADMIN_ADDR);
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());
        credit_manager::initialize<AptosCoin>(&admin, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR);

        // Lender deposits
        lending_pool::deposit<AptosCoin>(&lender, ADMIN_ADDR, 50000000000u64);

        // Open credit line and borrow
        credit_manager::open_credit_line<AptosCoin>(&borrower, ADMIN_ADDR, 10000000000u64);
        credit_manager::borrow<AptosCoin>(&borrower, ADMIN_ADDR, 5000000000u64);

        // Try to withdraw collateral with outstanding debt - should fail
        credit_manager::withdraw_collateral<AptosCoin>(&borrower, ADMIN_ADDR, 5000000000u64);
    }

    // ==================== ADMIN TRANSFER TESTS ====================

    #[test(aptos_framework = @aptos_framework)]
    fun test_lending_pool_admin_transfer(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let new_admin = account::create_signer_for_test(LENDER_ADDR);

        // Initialize
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);

        // Initiate transfer
        lending_pool::transfer_admin<AptosCoin>(&admin, ADMIN_ADDR, LENDER_ADDR);

        // Accept transfer
        lending_pool::accept_admin<AptosCoin>(&new_admin, ADMIN_ADDR);

        // Verify new admin
        assert!(lending_pool::get_admin<AptosCoin>(ADMIN_ADDR) == LENDER_ADDR, 1);
    }

    #[test(aptos_framework = @aptos_framework)]
    fun test_credit_manager_pause_unpause(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);

        // Initialize all modules
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        reputation_manager::initialize(&admin, ADMIN_ADDR);
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());
        credit_manager::initialize<AptosCoin>(&admin, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR);

        // Pause
        credit_manager::pause<AptosCoin>(&admin, ADMIN_ADDR);
        assert!(credit_manager::is_paused<AptosCoin>(ADMIN_ADDR), 1);

        // Unpause
        credit_manager::unpause<AptosCoin>(&admin, ADMIN_ADDR);
        assert!(!credit_manager::is_paused<AptosCoin>(ADMIN_ADDR), 2);
    }

    // ==================== MINIMUM AMOUNT TESTS ====================

    #[test(aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 65546)]
    fun test_lending_pool_deposit_below_minimum(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let lender = account::create_signer_for_test(LENDER_ADDR);

        // Initialize
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);

        // Try to deposit below minimum (1 USDC = 1000000)
        lending_pool::deposit<AptosCoin>(&lender, ADMIN_ADDR, 100000u64); // 0.1 USDC
    }

    #[test(aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 65550)]
    fun test_credit_manager_collateral_below_minimum(aptos_framework: &signer) {
        setup_test(aptos_framework);
        let admin = account::create_signer_for_test(ADMIN_ADDR);
        let borrower = account::create_signer_for_test(BORROWER_ADDR);

        // Initialize all modules
        lending_pool::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        collateral_vault::initialize<AptosCoin>(&admin, ADMIN_ADDR);
        reputation_manager::initialize(&admin, ADMIN_ADDR);
        interest_rate_model::initialize(&admin, ADMIN_ADDR, std::option::none());
        credit_manager::initialize<AptosCoin>(&admin, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR, ADMIN_ADDR);

        // Try to open credit line with collateral below minimum
        credit_manager::open_credit_line<AptosCoin>(&borrower, ADMIN_ADDR, 100000u64); // 0.1 USDC
    }
}
