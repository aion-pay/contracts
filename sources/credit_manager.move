module credit_protocol::credit_manager {
    use std::signer;
    use std::error;
    use std::vector;
    use std::string::{Self, String};
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::table::{Self, Table};

    // Import other modules
    use credit_protocol::lending_pool;
    use credit_protocol::reputation_manager;

    /// Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INVALID_AMOUNT: u64 = 2;
    const E_CREDIT_LINE_EXISTS: u64 = 3;
    const E_CREDIT_LINE_NOT_ACTIVE: u64 = 4;
    const E_EXCEEDS_CREDIT_LIMIT: u64 = 5;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 6;
    const E_EXCEEDS_BORROWED_AMOUNT: u64 = 7;
    const E_EXCEEDS_INTEREST: u64 = 8;
    const E_LIQUIDATION_NOT_ALLOWED: u64 = 9;
    const E_ALREADY_INITIALIZED: u64 = 10;
    const E_INVALID_ADDRESS: u64 = 11;
    const E_PENDING_ADMIN_NOT_SET: u64 = 12;
    const E_NOT_PENDING_ADMIN: u64 = 13;
    const E_BELOW_MINIMUM_AMOUNT: u64 = 14;
    const E_NO_ACTIVE_DEBT: u64 = 15;
    const E_HAS_OUTSTANDING_DEBT: u64 = 16;
    const E_INVALID_PARAMETERS: u64 = 17;

    /// Constants
    const BASIS_POINTS: u256 = 10000;
    const SECONDS_PER_YEAR: u64 = 31536000; // 365 * 24 * 60 * 60
    const GRACE_PERIOD: u64 = 2592000; // 30 days
    const MAX_LTV: u256 = 10000; // 100%
    const LIQUIDATION_THRESHOLD: u256 = 11000; // 110%
    const MIN_COLLATERAL_AMOUNT: u64 = 1000000; // Minimum 1 USDC (6 decimals)
    const MIN_BORROW_AMOUNT: u64 = 100000; // Minimum 0.1 USDC
    const MAX_INTEREST_RATE: u256 = 5000; // 50% max annual rate
    const MAX_CREDIT_MULTIPLIER: u256 = 20000; // 200% max multiplier

    /// Credit line structure
    struct CreditLine has copy, store, drop {
        collateral_deposited: u64,
        credit_limit: u64,
        borrowed_amount: u64,
        last_borrowed_timestamp: u64,
        interest_accrued: u64,
        last_interest_update: u64,
        repayment_due_date: u64,
        is_active: bool,
        total_repaid: u64,
        on_time_repayments: u64,
        late_repayments: u64,
    }

    /// Credit manager resource - generic over CoinType (e.g., USDC)
    struct CreditManager<phantom CoinType> has key {
        admin: address,
        pending_admin: std::option::Option<address>,
        lending_pool_addr: address,
        collateral_vault_addr: address,
        reputation_manager_addr: address,
        interest_rate_model_addr: address,
        fixed_interest_rate: u256,      // basis points
        reputation_threshold: u256,      // reputation score threshold
        credit_increase_multiplier: u256, // basis points
        credit_lines: Table<address, CreditLine>,
        borrowers_list: vector<address>,
        collateral_reserve: Coin<CoinType>, // For handling collateral transfers
        is_paused: bool,
    }

    /// Events
    #[event]
    struct CreditOpenedEvent has drop, store {
        borrower: address,
        collateral_amount: u64,
        credit_limit: u64,
        timestamp: u64,
    }

    #[event]
    struct BorrowedEvent has drop, store {
        borrower: address,
        amount: u64,
        total_borrowed: u64,
        due_date: u64,
        timestamp: u64,
    }

    #[event]
    struct DirectPaymentEvent has drop, store {
        borrower: address,
        recipient: address,
        amount: u64,
        total_borrowed: u64,
        due_date: u64,
        timestamp: u64,
    }

    #[event]
    struct RepaidEvent has drop, store {
        borrower: address,
        principal_amount: u64,
        interest_amount: u64,
        remaining_balance: u64,
        timestamp: u64,
    }

    #[event]
    struct LiquidatedEvent has drop, store {
        borrower: address,
        collateral_liquidated: u64,
        debt_cleared: u64,
        reason: String,
        timestamp: u64,
    }

    #[event]
    struct CreditLimitIncreasedEvent has drop, store {
        borrower: address,
        old_limit: u64,
        new_limit: u64,
        reputation_score: u256,
        timestamp: u64,
    }

    #[event]
    struct CollateralAddedEvent has drop, store {
        borrower: address,
        amount: u64,
        total_collateral: u64,
        new_credit_limit: u64,
        timestamp: u64,
    }

    #[event]
    struct CollateralWithdrawnEvent has drop, store {
        borrower: address,
        amount: u64,
        remaining_collateral: u64,
        remaining_credit_limit: u64,
        timestamp: u64,
    }

    #[event]
    struct PausedEvent has drop, store {
        admin: address,
        timestamp: u64,
    }

    #[event]
    struct UnpausedEvent has drop, store {
        admin: address,
        timestamp: u64,
    }

    #[event]
    struct AdminTransferInitiatedEvent has drop, store {
        current_admin: address,
        pending_admin: address,
        timestamp: u64,
    }

    #[event]
    struct AdminTransferCompletedEvent has drop, store {
        old_admin: address,
        new_admin: address,
        timestamp: u64,
    }

    #[event]
    struct ParametersUpdatedEvent has drop, store {
        fixed_interest_rate: u256,
        reputation_threshold: u256,
        credit_increase_multiplier: u256,
        timestamp: u64,
    }

    /// Initialize the credit manager
    public entry fun initialize<CoinType>(
        admin: &signer,
        lending_pool_addr: address,
        collateral_vault_addr: address,
        reputation_manager_addr: address,
        interest_rate_model_addr: address,
    ) {
        let admin_addr = signer::address_of(admin);

        assert!(!exists<CreditManager<CoinType>>(admin_addr), error::already_exists(E_ALREADY_INITIALIZED));
        // Validate all addresses are non-zero
        assert!(lending_pool_addr != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        assert!(collateral_vault_addr != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        assert!(reputation_manager_addr != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        assert!(interest_rate_model_addr != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        let credit_manager = CreditManager<CoinType> {
            admin: admin_addr,
            pending_admin: std::option::none(),
            lending_pool_addr,
            collateral_vault_addr,
            reputation_manager_addr,
            interest_rate_model_addr,
            fixed_interest_rate: 1500, // 15%
            reputation_threshold: 750,
            credit_increase_multiplier: 12000, // 120% (20% increase from base)
            credit_lines: table::new(),
            borrowers_list: vector::empty(),
            collateral_reserve: coin::zero<CoinType>(),
            is_paused: false,
        };

        move_to(admin, credit_manager);
    }

    /// Open a credit line
    public entry fun open_credit_line<CoinType>(
        borrower: &signer,
        manager_addr: address,
        collateral_amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(collateral_amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(collateral_amount >= MIN_COLLATERAL_AMOUNT, error::invalid_argument(E_BELOW_MINIMUM_AMOUNT));
        assert!(
            !table::contains(&manager.credit_lines, borrower_addr),
            error::already_exists(E_CREDIT_LINE_EXISTS)
        );

        // Transfer collateral from borrower to manager's collateral reserve
        let collateral_coins = coin::withdraw<CoinType>(borrower, collateral_amount);
        coin::merge(&mut manager.collateral_reserve, collateral_coins);

        // Calculate credit limit (1:1 ratio - can be adjusted based on collateral type)
        let credit_limit = collateral_amount;

        let credit_line = CreditLine {
            collateral_deposited: collateral_amount,
            credit_limit,
            borrowed_amount: 0,
            last_borrowed_timestamp: 0,
            interest_accrued: 0,
            last_interest_update: timestamp::now_seconds(),
            repayment_due_date: 0,
            is_active: true,
            total_repaid: 0,
            on_time_repayments: 0,
            late_repayments: 0,
        };

        table::add(&mut manager.credit_lines, borrower_addr, credit_line);
        vector::push_back(&mut manager.borrowers_list, borrower_addr);

        event::emit(CreditOpenedEvent {
            borrower: borrower_addr,
            collateral_amount,
            credit_limit,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Add collateral to existing credit line
    public entry fun add_collateral<CoinType>(
        borrower: &signer,
        manager_addr: address,
        collateral_amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(collateral_amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(
            table::contains(&manager.credit_lines, borrower_addr),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower_addr);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));

        // Transfer additional collateral
        let collateral_coins = coin::withdraw<CoinType>(borrower, collateral_amount);
        coin::merge(&mut manager.collateral_reserve, collateral_coins);

        // Update credit line
        credit_line.collateral_deposited = credit_line.collateral_deposited + collateral_amount;
        credit_line.credit_limit = credit_line.credit_limit + collateral_amount;

        event::emit(CollateralAddedEvent {
            borrower: borrower_addr,
            amount: collateral_amount,
            total_collateral: credit_line.collateral_deposited,
            new_credit_limit: credit_line.credit_limit,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Borrow funds
    public entry fun borrow<CoinType>(
        borrower: &signer,
        manager_addr: address,
        amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(amount >= MIN_BORROW_AMOUNT, error::invalid_argument(E_BELOW_MINIMUM_AMOUNT));
        assert!(
            table::contains(&manager.credit_lines, borrower_addr),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        // Update interest before borrowing
        update_interest_internal(manager, borrower_addr);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower_addr);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));

        let total_debt = credit_line.borrowed_amount + credit_line.interest_accrued;
        assert!(
            total_debt + amount <= credit_line.credit_limit,
            error::invalid_state(E_EXCEEDS_CREDIT_LIMIT)
        );

        // Check available liquidity from lending pool
        let available_liquidity = lending_pool::get_available_liquidity<CoinType>(manager.lending_pool_addr);
        assert!(available_liquidity >= amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

        // Update credit line state first (checks-effects-interactions pattern)
        credit_line.borrowed_amount = credit_line.borrowed_amount + amount;
        credit_line.last_borrowed_timestamp = timestamp::now_seconds();
        // Set due date: grace period + 30 days for repayment
        credit_line.repayment_due_date = timestamp::now_seconds() + GRACE_PERIOD + 2592000;

        // Get funds from lending pool and transfer to borrower
        let borrowed_coins = lending_pool::borrow_for_payment<CoinType>(
            manager.lending_pool_addr,
            borrower_addr,
            amount
        );
        coin::deposit(borrower_addr, borrowed_coins);

        event::emit(BorrowedEvent {
            borrower: borrower_addr,
            amount,
            total_borrowed: credit_line.borrowed_amount,
            due_date: credit_line.repayment_due_date,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Borrow funds and pay directly to recipient
    public entry fun borrow_and_pay<CoinType>(
        borrower: &signer,
        manager_addr: address,
        recipient: address,
        amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(amount >= MIN_BORROW_AMOUNT, error::invalid_argument(E_BELOW_MINIMUM_AMOUNT));
        assert!(recipient != borrower_addr, error::invalid_argument(E_INVALID_ADDRESS));
        assert!(recipient != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        assert!(
            table::contains(&manager.credit_lines, borrower_addr),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        // Update interest before borrowing
        update_interest_internal(manager, borrower_addr);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower_addr);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));

        let total_debt = credit_line.borrowed_amount + credit_line.interest_accrued;
        assert!(
            total_debt + amount <= credit_line.credit_limit,
            error::invalid_state(E_EXCEEDS_CREDIT_LIMIT)
        );

        // Check available liquidity from lending pool
        let available_liquidity = lending_pool::get_available_liquidity<CoinType>(manager.lending_pool_addr);
        assert!(available_liquidity >= amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

        // Update credit line state first (checks-effects-interactions pattern)
        credit_line.borrowed_amount = credit_line.borrowed_amount + amount;
        credit_line.last_borrowed_timestamp = timestamp::now_seconds();
        credit_line.repayment_due_date = timestamp::now_seconds() + GRACE_PERIOD + 2592000;

        // Get funds from lending pool
        let borrowed_coins = lending_pool::borrow_for_payment<CoinType>(
            manager.lending_pool_addr,
            borrower_addr,
            amount
        );

        // Transfer funds directly to recipient
        coin::deposit(recipient, borrowed_coins);

        event::emit(DirectPaymentEvent {
            borrower: borrower_addr,
            recipient,
            amount,
            total_borrowed: credit_line.borrowed_amount,
            due_date: credit_line.repayment_due_date,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Repay loan
    public entry fun repay<CoinType>(
        borrower: &signer,
        manager_addr: address,
        principal_amount: u64,
        interest_amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(
            principal_amount > 0 || interest_amount > 0,
            error::invalid_argument(E_INVALID_AMOUNT)
        );
        assert!(
            table::contains(&manager.credit_lines, borrower_addr),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        // Update interest before repayment
        update_interest_internal(manager, borrower_addr);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower_addr);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));
        assert!(credit_line.borrowed_amount > 0, error::invalid_state(E_NO_ACTIVE_DEBT));
        assert!(
            principal_amount <= credit_line.borrowed_amount,
            error::invalid_argument(E_EXCEEDS_BORROWED_AMOUNT)
        );
        assert!(
            interest_amount <= credit_line.interest_accrued,
            error::invalid_argument(E_EXCEEDS_INTEREST)
        );

        let total_repayment = principal_amount + interest_amount;

        // Check if payment is on time (before state changes)
        let current_time = timestamp::now_seconds();
        let is_on_time = current_time <= credit_line.repayment_due_date;

        // Update credit line state first
        credit_line.borrowed_amount = credit_line.borrowed_amount - principal_amount;
        credit_line.interest_accrued = credit_line.interest_accrued - interest_amount;
        credit_line.total_repaid = credit_line.total_repaid + total_repayment;

        if (is_on_time) {
            credit_line.on_time_repayments = credit_line.on_time_repayments + 1;
        } else {
            credit_line.late_repayments = credit_line.late_repayments + 1;
        };

        // Store remaining balance for event
        let remaining_balance = credit_line.borrowed_amount;

        // Transfer repayment from borrower and send to lending pool
        let repayment_coins = coin::withdraw<CoinType>(borrower, total_repayment);

        // Send repayment to lending pool with accounting update
        lending_pool::receive_repayment<CoinType>(
            manager.lending_pool_addr,
            borrower_addr,
            principal_amount,
            interest_amount,
            repayment_coins
        );

        // Update reputation in reputation manager
        reputation_manager::update_reputation(
            borrower,
            manager.reputation_manager_addr,
            borrower_addr,
            is_on_time,
            total_repayment
        );

        // Check for credit limit increase only if debt is fully repaid
        if (remaining_balance == 0) {
            check_credit_limit_increase_internal(manager, borrower_addr);
        };

        event::emit(RepaidEvent {
            borrower: borrower_addr,
            principal_amount,
            interest_amount,
            remaining_balance,
            timestamp: current_time,
        });
    }

    /// Liquidate a borrower's position
    public entry fun liquidate<CoinType>(
        admin: &signer,
        manager_addr: address,
        borrower: address,
    ) acquires CreditManager {
        let admin_addr = signer::address_of(admin);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(
            table::contains(&manager.credit_lines, borrower),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        // Update interest before liquidation
        update_interest_internal(manager, borrower);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));

        let is_over_ltv = is_over_ltv_internal(credit_line);
        let is_overdue = is_overdue_internal(credit_line);

        assert!(is_over_ltv || is_overdue, error::invalid_state(E_LIQUIDATION_NOT_ALLOWED));

        let total_debt = credit_line.borrowed_amount + credit_line.interest_accrued;
        let collateral_to_liquidate = if (total_debt < credit_line.collateral_deposited) {
            total_debt
        } else {
            credit_line.collateral_deposited
        };

        // Liquidate collateral (would call collateral vault module)
        // collateral_vault::liquidate_collateral(manager.collateral_vault_addr, borrower, collateral_to_liquidate);

        // Update credit line
        credit_line.borrowed_amount = 0;
        credit_line.interest_accrued = 0;
        credit_line.collateral_deposited = credit_line.collateral_deposited - collateral_to_liquidate;

        // Update reputation (negative impact)
        // reputation_manager::record_default(manager.reputation_manager_addr, borrower, total_debt);

        if (credit_line.collateral_deposited == 0) {
            credit_line.is_active = false;
        };

        let reason = if (is_over_ltv) {
            string::utf8(b"Over LTV")
        } else {
            string::utf8(b"Overdue")
        };

        event::emit(LiquidatedEvent {
            borrower,
            collateral_liquidated: collateral_to_liquidate,
            debt_cleared: total_debt,
            reason,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Get credit information for a borrower
    public fun get_credit_info<CoinType>(
        manager_addr: address,
        borrower: address,
    ): (u64, u64, u64, u64, u64, u64, bool) acquires CreditManager {
        let manager = borrow_global<CreditManager<CoinType>>(manager_addr);

        if (table::contains(&manager.credit_lines, borrower)) {
            let credit_line = table::borrow(&manager.credit_lines, borrower);
            let current_interest = calculate_interest_internal(manager, borrower);
            let total_interest = credit_line.interest_accrued + current_interest;

            (
                credit_line.collateral_deposited,
                credit_line.credit_limit,
                credit_line.borrowed_amount,
                total_interest,
                credit_line.borrowed_amount + total_interest,
                credit_line.repayment_due_date,
                credit_line.is_active
            )
        } else {
            (0, 0, 0, 0, 0, 0, false)
        }
    }

    /// Get repayment history for a borrower
    public fun get_repayment_history<CoinType>(
        manager_addr: address,
        borrower: address,
    ): (u64, u64, u64) acquires CreditManager {
        let manager = borrow_global<CreditManager<CoinType>>(manager_addr);

        if (table::contains(&manager.credit_lines, borrower)) {
            let credit_line = table::borrow(&manager.credit_lines, borrower);
            (credit_line.on_time_repayments, credit_line.late_repayments, credit_line.total_repaid)
        } else {
            (0, 0, 0)
        }
    }

    /// Check credit increase eligibility
    public fun check_credit_increase_eligibility<CoinType>(
        manager_addr: address,
        borrower: address,
    ): (bool, u64) acquires CreditManager {
        let manager = borrow_global<CreditManager<CoinType>>(manager_addr);

        if (!table::contains(&manager.credit_lines, borrower)) {
            return (false, 0)
        };

        let credit_line = table::borrow(&manager.credit_lines, borrower);
        if (!credit_line.is_active) {
            return (false, 0)
        };

        // Get actual reputation score from reputation manager
        let reputation_score = reputation_manager::get_reputation_score(
            manager.reputation_manager_addr,
            borrower
        );

        let has_good_reputation = reputation_score >= manager.reputation_threshold;
        let has_repayment_history = credit_line.on_time_repayments > 0;
        let no_current_debt = credit_line.borrowed_amount == 0;

        let eligible = has_good_reputation && has_repayment_history && no_current_debt;
        let new_limit = if (eligible) {
            ((credit_line.credit_limit as u256) * manager.credit_increase_multiplier / BASIS_POINTS as u64)
        } else {
            0
        };

        (eligible, new_limit)
    }

    /// Get all borrowers
    public fun get_all_borrowers<CoinType>(manager_addr: address): vector<address> acquires CreditManager {
        let manager = borrow_global<CreditManager<CoinType>>(manager_addr);
        manager.borrowers_list
    }

    /// Withdraw excess collateral (when no outstanding debt)
    public entry fun withdraw_collateral<CoinType>(
        borrower: &signer,
        manager_addr: address,
        amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(
            table::contains(&manager.credit_lines, borrower_addr),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        // Update interest before withdrawal check
        update_interest_internal(manager, borrower_addr);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower_addr);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));

        // Can only withdraw if no outstanding debt
        let total_debt = credit_line.borrowed_amount + credit_line.interest_accrued;
        assert!(total_debt == 0, error::invalid_state(E_HAS_OUTSTANDING_DEBT));
        assert!(
            amount <= credit_line.collateral_deposited,
            error::invalid_argument(E_INVALID_AMOUNT)
        );

        // Update credit line
        credit_line.collateral_deposited = credit_line.collateral_deposited - amount;
        credit_line.credit_limit = credit_line.collateral_deposited; // Adjust credit limit proportionally

        // Transfer collateral back to borrower
        let withdrawal_coins = coin::extract(&mut manager.collateral_reserve, amount);
        coin::deposit(borrower_addr, withdrawal_coins);

        // Deactivate credit line if all collateral is withdrawn
        if (credit_line.collateral_deposited == 0) {
            credit_line.is_active = false;
        };

        event::emit(CollateralWithdrawnEvent {
            borrower: borrower_addr,
            amount,
            remaining_collateral: credit_line.collateral_deposited,
            remaining_credit_limit: credit_line.credit_limit,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Pause the credit manager
    public entry fun pause<CoinType>(admin: &signer, manager_addr: address) acquires CreditManager {
        let admin_addr = signer::address_of(admin);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        manager.is_paused = true;

        event::emit(PausedEvent {
            admin: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Unpause the credit manager
    public entry fun unpause<CoinType>(admin: &signer, manager_addr: address) acquires CreditManager {
        let admin_addr = signer::address_of(admin);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        manager.is_paused = false;

        event::emit(UnpausedEvent {
            admin: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Initiate admin transfer (2-step process for security)
    public entry fun transfer_admin<CoinType>(
        admin: &signer,
        manager_addr: address,
        new_admin: address,
    ) acquires CreditManager {
        let admin_addr = signer::address_of(admin);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_admin != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        manager.pending_admin = std::option::some(new_admin);

        event::emit(AdminTransferInitiatedEvent {
            current_admin: admin_addr,
            pending_admin: new_admin,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Accept admin transfer (must be called by pending admin)
    public entry fun accept_admin<CoinType>(
        new_admin: &signer,
        manager_addr: address,
    ) acquires CreditManager {
        let new_admin_addr = signer::address_of(new_admin);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(std::option::is_some(&manager.pending_admin), error::invalid_state(E_PENDING_ADMIN_NOT_SET));
        assert!(
            *std::option::borrow(&manager.pending_admin) == new_admin_addr,
            error::permission_denied(E_NOT_PENDING_ADMIN)
        );

        let old_admin = manager.admin;
        manager.admin = new_admin_addr;
        manager.pending_admin = std::option::none();

        event::emit(AdminTransferCompletedEvent {
            old_admin,
            new_admin: new_admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Cancel pending admin transfer
    public entry fun cancel_admin_transfer<CoinType>(
        admin: &signer,
        manager_addr: address,
    ) acquires CreditManager {
        let admin_addr = signer::address_of(admin);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        manager.pending_admin = std::option::none();
    }

    /// Update parameters with validation
    public entry fun update_parameters<CoinType>(
        admin: &signer,
        manager_addr: address,
        fixed_interest_rate: u256,
        reputation_threshold: u256,
        credit_increase_multiplier: u256,
    ) acquires CreditManager {
        let admin_addr = signer::address_of(admin);
        let manager = borrow_global_mut<CreditManager<CoinType>>(manager_addr);

        assert!(manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        // Validate parameters
        assert!(fixed_interest_rate <= MAX_INTEREST_RATE, error::invalid_argument(E_INVALID_PARAMETERS));
        assert!(reputation_threshold <= 1000, error::invalid_argument(E_INVALID_PARAMETERS)); // Max score is 1000
        assert!(
            credit_increase_multiplier >= BASIS_POINTS && credit_increase_multiplier <= MAX_CREDIT_MULTIPLIER,
            error::invalid_argument(E_INVALID_PARAMETERS)
        );

        manager.fixed_interest_rate = fixed_interest_rate;
        manager.reputation_threshold = reputation_threshold;
        manager.credit_increase_multiplier = credit_increase_multiplier;

        event::emit(ParametersUpdatedEvent {
            fixed_interest_rate,
            reputation_threshold,
            credit_increase_multiplier,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Internal function to update interest
    fun update_interest_internal<CoinType>(manager: &mut CreditManager<CoinType>, borrower: address) {
        if (!table::contains(&manager.credit_lines, borrower)) {
            return
        };

        // Calculate new interest first before borrowing mutably
        let new_interest = calculate_interest_internal(manager, borrower);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower);
        if (credit_line.borrowed_amount > 0 && credit_line.last_borrowed_timestamp > 0) {
            credit_line.interest_accrued = credit_line.interest_accrued + new_interest;
            credit_line.last_interest_update = timestamp::now_seconds();
        };
    }

    /// Internal function to calculate interest
    fun calculate_interest_internal<CoinType>(manager: &CreditManager<CoinType>, borrower: address): u64 {
        if (!table::contains(&manager.credit_lines, borrower)) {
            return 0
        };

        let credit_line = table::borrow(&manager.credit_lines, borrower);
        if (credit_line.borrowed_amount == 0 || credit_line.last_borrowed_timestamp == 0) {
            return 0
        };

        // Calculate interest using interest rate model (would call interest rate model module)
        // let total_accrued = interest_rate_model::calculate_accrued_interest(
        //     manager.interest_rate_model_addr,
        //     credit_line.borrowed_amount,
        //     credit_line.last_borrowed_timestamp
        // );

        // Simplified interest calculation for demonstration
        let current_time = timestamp::now_seconds();
        let time_elapsed = current_time - credit_line.last_interest_update;
        let annual_rate = manager.fixed_interest_rate;
        let interest_per_second = (annual_rate * (credit_line.borrowed_amount as u256)) /
            (BASIS_POINTS * (SECONDS_PER_YEAR as u256));
        let new_interest = (interest_per_second * (time_elapsed as u256)) as u64;

        new_interest
    }

    /// Internal function to check if over LTV
    fun is_over_ltv_internal(credit_line: &CreditLine): bool {
        if (credit_line.collateral_deposited == 0) return true;

        let total_debt = credit_line.borrowed_amount + credit_line.interest_accrued;
        let current_ltv = ((total_debt as u256) * BASIS_POINTS) / (credit_line.collateral_deposited as u256);
        current_ltv > LIQUIDATION_THRESHOLD
    }

    /// Internal function to check if overdue
    fun is_overdue_internal(credit_line: &CreditLine): bool {
        credit_line.borrowed_amount > 0 && timestamp::now_seconds() > credit_line.repayment_due_date
    }

    /// Internal function to check credit limit increase
    fun check_credit_limit_increase_internal<CoinType>(manager: &mut CreditManager<CoinType>, borrower: address) {
        // Check eligibility directly without acquiring global again
        if (!table::contains(&manager.credit_lines, borrower)) {
            return
        };

        let credit_line = table::borrow(&manager.credit_lines, borrower);
        if (!credit_line.is_active) {
            return
        };

        // Get actual reputation score from reputation manager
        let reputation_score = reputation_manager::get_reputation_score(
            manager.reputation_manager_addr,
            borrower
        );

        let has_good_reputation = reputation_score >= manager.reputation_threshold;
        let has_repayment_history = credit_line.on_time_repayments > 0;
        let no_current_debt = credit_line.borrowed_amount == 0;

        let eligible = has_good_reputation && has_repayment_history && no_current_debt;

        if (eligible) {
            let new_limit = ((credit_line.credit_limit as u256) * manager.credit_increase_multiplier / BASIS_POINTS as u64);

            let credit_line_mut = table::borrow_mut(&mut manager.credit_lines, borrower);
            let old_limit = credit_line_mut.credit_limit;
            credit_line_mut.credit_limit = new_limit;

            event::emit(CreditLimitIncreasedEvent {
                borrower,
                old_limit,
                new_limit,
                reputation_score,
                timestamp: timestamp::now_seconds(),
            });
        };
    }

    /// View functions
    public fun is_paused<CoinType>(manager_addr: address): bool acquires CreditManager {
        let manager = borrow_global<CreditManager<CoinType>>(manager_addr);
        manager.is_paused
    }

    public fun get_admin<CoinType>(manager_addr: address): address acquires CreditManager {
        let manager = borrow_global<CreditManager<CoinType>>(manager_addr);
        manager.admin
    }

    public fun get_lending_pool_addr<CoinType>(manager_addr: address): address acquires CreditManager {
        let manager = borrow_global<CreditManager<CoinType>>(manager_addr);
        manager.lending_pool_addr
    }

    public fun get_fixed_interest_rate<CoinType>(manager_addr: address): u256 acquires CreditManager {
        let manager = borrow_global<CreditManager<CoinType>>(manager_addr);
        manager.fixed_interest_rate
    }
}
