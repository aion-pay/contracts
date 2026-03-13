module credit_protocol::lending_pool {
    use std::signer;
    use std::error;
    use std::vector;
    use std::option::{Self, Option};
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::fungible_asset::{Self, FungibleStore, Metadata};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::table::{Self, Table};

    // Only credit_manager can call internal fund-flow functions
    friend credit_protocol::credit_manager;

    /// Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 3;
    const E_INVALID_AMOUNT: u64 = 4;
    const E_ALREADY_INITIALIZED: u64 = 5;
    const E_NOT_INITIALIZED: u64 = 6;
    const E_INVALID_ADDRESS: u64 = 7;
    const E_PENDING_ADMIN_NOT_SET: u64 = 8;
    const E_NOT_PENDING_ADMIN: u64 = 9;
    const E_BELOW_MINIMUM_AMOUNT: u64 = 10;
    const E_COLLATERAL_NOT_FOUND: u64 = 11;

    /// Constants
    const BASIS_POINTS: u256 = 10000;
    const PROTOCOL_FEE_RATE: u256 = 1000; // 10%
    const MIN_DEPOSIT_AMOUNT: u64 = 1000000; // Minimum 1 USDC (6 decimals)
    const PRECISION: u256 = 1_000_000_000_000; // 1e12 for interest accumulator scaling

    /// Lender information structure — interest settled lazily via accumulator (C-08)
    struct LenderInfo has copy, store, drop {
        deposited_amount: u64,
        earned_interest: u64,           // settled on each interaction, not per-repayment
        reward_debt: u256,              // deposited * accumulated_per_share at last settlement
        initial_deposit_timestamp: u64, // first deposit time — never overwritten (H-11)
        last_deposit_timestamp: u64,    // most recent deposit time
    }

    /// Collateral information structure — interest settled lazily via accumulator (C-08)
    struct CollateralInfo has copy, store, drop {
        deposited_amount: u64,
        earned_interest: u64,           // settled on each interaction
        reward_debt: u256,              // deposited * accumulated_per_share at last settlement
        deposit_timestamp: u64,
    }

    /// Lending pool resource — uses Fungible Asset standard
    struct LendingPool has key {
        admin: address,
        pending_admin: Option<address>,
        credit_manager: address,
        total_deposited: u64,
        total_collateral: u64,
        total_borrowed: u64,
        total_repaid: u64,
        protocol_fees_collected: u64,
        accumulated_interest_per_share: u256, // global accumulator scaled by PRECISION (C-08)
        lenders: Table<address, LenderInfo>,
        lenders_list: vector<address>,
        collateral_deposits: Table<address, CollateralInfo>,
        collateral_list: vector<address>,
        token_metadata: Object<Metadata>,
        token_store: Object<FungibleStore>,
        extend_ref: ExtendRef,
        is_paused: bool,
    }

    // ========== Events ==========

    #[event]
    struct DepositEvent has drop, store {
        lender: address,
        amount: u64,
        timestamp: u64,
    }

    #[event]
    struct WithdrawEvent has drop, store {
        lender: address,
        amount: u64,
        interest: u64,
        timestamp: u64,
    }

    #[event]
    struct CollateralDepositedEvent has drop, store {
        borrower: address,
        amount: u64,
        total_collateral: u64,
        timestamp: u64,
    }

    #[event]
    struct CollateralWithdrawnEvent has drop, store {
        borrower: address,
        amount: u64,
        interest_earned: u64,
        remaining_collateral: u64,
        timestamp: u64,
    }

    #[event]
    struct CollateralSeizedEvent has drop, store {
        borrower: address,
        amount_seized: u64,
        interest_seized: u64,
        remaining_collateral: u64,
        timestamp: u64,
    }

    #[event]
    struct BorrowEvent has drop, store {
        borrower: address,
        recipient: address,
        amount: u64,
        timestamp: u64,
    }

    #[event]
    struct RepayEvent has drop, store {
        borrower: address,
        principal: u64,
        interest: u64,
        timestamp: u64,
    }

    #[event]
    struct BadDebtWrittenOffEvent has drop, store {
        borrower: address,
        amount: u64,
        timestamp: u64,
    }

    #[event]
    struct ProtocolFeesWithdrawnEvent has drop, store {
        admin: address,
        to: address,
        amount: u64,
        remaining_fees: u64,
        timestamp: u64,
    }

    #[event]
    struct CreditManagerUpdatedEvent has drop, store {
        old_manager: address,
        new_manager: address,
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
    struct AdminTransferCancelledEvent has drop, store {
        admin: address,
        cancelled_pending_admin: address,
        timestamp: u64,
    }

    // ========== Initialize ==========

    /// Initialize the lending pool with a specific fungible asset
    public entry fun initialize(
        admin: &signer,
        credit_manager: address,
        token_metadata_addr: address,
    ) {
        let admin_addr = signer::address_of(admin);

        assert!(!exists<LendingPool>(admin_addr), error::already_exists(E_ALREADY_INITIALIZED));
        assert!(credit_manager != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        let token_metadata = object::address_to_object<Metadata>(token_metadata_addr);

        // Create a fungible store for the pool to hold tokens
        let constructor_ref = object::create_object(admin_addr);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let token_store = fungible_asset::create_store(&constructor_ref, token_metadata);

        let lending_pool = LendingPool {
            admin: admin_addr,
            pending_admin: option::none(),
            credit_manager,
            total_deposited: 0,
            total_collateral: 0,
            total_borrowed: 0,
            total_repaid: 0,
            protocol_fees_collected: 0,
            accumulated_interest_per_share: 0,
            lenders: table::new(),
            lenders_list: vector::empty(),
            collateral_deposits: table::new(),
            collateral_list: vector::empty(),
            token_metadata,
            token_store,
            extend_ref,
            is_paused: false,
        };

        move_to(admin, lending_pool);
    }

    // ========== Lender Functions ==========

    /// Deposit funds into the lending pool (for lenders)
    public entry fun deposit(
        lender: &signer,
        pool_addr: address,
        amount: u64,
    ) acquires LendingPool {
        let lender_addr = signer::address_of(lender);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(!pool.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(amount >= MIN_DEPOSIT_AMOUNT, error::invalid_argument(E_BELOW_MINIMUM_AMOUNT));

        // Transfer tokens from lender to pool
        let fa = dispatchable_fungible_asset::withdraw(
            lender,
            primary_fungible_store::primary_store(lender_addr, pool.token_metadata),
            amount
        );
        dispatchable_fungible_asset::deposit(pool.token_store, fa);

        // Update or create lender info
        if (table::contains(&pool.lenders, lender_addr)) {
            let lender_info = table::borrow_mut(&mut pool.lenders, lender_addr);
            // Settle pending interest before changing deposit (C-08)
            settle_lender_interest_internal(pool.accumulated_interest_per_share, lender_info);
            lender_info.deposited_amount = lender_info.deposited_amount + amount;
            // Recalculate reward_debt with new deposit amount
            lender_info.reward_debt = (lender_info.deposited_amount as u256)
                * pool.accumulated_interest_per_share / PRECISION;
            lender_info.last_deposit_timestamp = timestamp::now_seconds();
            // initial_deposit_timestamp preserved (H-11)
        } else {
            let lender_info = LenderInfo {
                deposited_amount: amount,
                earned_interest: 0,
                reward_debt: (amount as u256) * pool.accumulated_interest_per_share / PRECISION,
                initial_deposit_timestamp: timestamp::now_seconds(),
                last_deposit_timestamp: timestamp::now_seconds(),
            };
            table::add(&mut pool.lenders, lender_addr, lender_info);
            vector::push_back(&mut pool.lenders_list, lender_addr);
        };

        pool.total_deposited = pool.total_deposited + amount;

        event::emit(DepositEvent {
            lender: lender_addr,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Withdraw funds from the lending pool (for lenders)
    /// Deduction order: interest first, then principal
    public entry fun withdraw(
        lender: &signer,
        pool_addr: address,
        amount: u64,
    ) acquires LendingPool {
        let lender_addr = signer::address_of(lender);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(!pool.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(table::contains(&pool.lenders, lender_addr), error::not_found(E_NOT_INITIALIZED));

        // Check available liquidity (safe subtraction — H-03)
        let pool_balance = fungible_asset::balance(pool.token_store);
        let available_liquidity = safe_subtract(pool_balance, pool.protocol_fees_collected);
        assert!(available_liquidity >= amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

        let lender_info = table::borrow_mut(&mut pool.lenders, lender_addr);

        // Settle pending interest before withdrawal (C-08)
        settle_lender_interest_internal(pool.accumulated_interest_per_share, lender_info);

        let total_available = lender_info.deposited_amount + lender_info.earned_interest;
        assert!(total_available >= amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));

        // Deduct from interest first, then principal
        let interest_withdrawn = if (amount <= lender_info.earned_interest) {
            amount
        } else {
            lender_info.earned_interest
        };
        let principal_withdrawn = amount - interest_withdrawn;

        lender_info.earned_interest = lender_info.earned_interest - interest_withdrawn;
        lender_info.deposited_amount = lender_info.deposited_amount - principal_withdrawn;

        // Recalculate reward_debt after balance change
        lender_info.reward_debt = (lender_info.deposited_amount as u256)
            * pool.accumulated_interest_per_share / PRECISION;

        // Only deduct principal from pool total (interest was never part of total_deposited)
        pool.total_deposited = pool.total_deposited - principal_withdrawn;

        // Remove lender if fully withdrawn
        if (lender_info.deposited_amount == 0 && lender_info.earned_interest == 0) {
            remove_lender_from_list(pool, lender_addr);
            table::remove(&mut pool.lenders, lender_addr);
        };

        // Transfer tokens to lender
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&pool_signer, pool.token_store, amount);
        dispatchable_fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(lender_addr, pool.token_metadata),
            fa
        );

        event::emit(WithdrawEvent {
            lender: lender_addr,
            amount,
            interest: interest_withdrawn,
            timestamp: timestamp::now_seconds(),
        });
    }

    // ========== Friend Functions (Credit Manager Only) ==========

    /// Deposit collateral into the lending pool (called by Credit Manager)
    public(friend) fun deposit_collateral(
        pool_addr: address,
        credit_manager_addr: address,
        borrower: address,
        amount: u64,
        from: &signer,
    ) acquires LendingPool {
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        // Validate caller is the registered credit manager (H-15)
        assert!(pool.credit_manager == credit_manager_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(!pool.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));

        // Transfer tokens from borrower to pool
        let fa = dispatchable_fungible_asset::withdraw(
            from,
            primary_fungible_store::primary_store(signer::address_of(from), pool.token_metadata),
            amount
        );
        dispatchable_fungible_asset::deposit(pool.token_store, fa);

        // Update or create collateral info
        if (table::contains(&pool.collateral_deposits, borrower)) {
            let collateral_info = table::borrow_mut(&mut pool.collateral_deposits, borrower);
            // Settle pending interest before changing deposit (C-08)
            settle_collateral_interest_internal(pool.accumulated_interest_per_share, collateral_info);
            collateral_info.deposited_amount = collateral_info.deposited_amount + amount;
            collateral_info.reward_debt = (collateral_info.deposited_amount as u256)
                * pool.accumulated_interest_per_share / PRECISION;
            collateral_info.deposit_timestamp = timestamp::now_seconds();
        } else {
            let collateral_info = CollateralInfo {
                deposited_amount: amount,
                earned_interest: 0,
                reward_debt: (amount as u256) * pool.accumulated_interest_per_share / PRECISION,
                deposit_timestamp: timestamp::now_seconds(),
            };
            table::add(&mut pool.collateral_deposits, borrower, collateral_info);
            vector::push_back(&mut pool.collateral_list, borrower);
        };

        pool.total_collateral = pool.total_collateral + amount;

        event::emit(CollateralDepositedEvent {
            borrower,
            amount,
            total_collateral: pool.total_collateral,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Withdraw collateral from the lending pool (called by Credit Manager)
    /// Returns the amount withdrawn including any earned interest
    public(friend) fun withdraw_collateral(
        pool_addr: address,
        credit_manager_addr: address,
        borrower: address,
        amount: u64,
        include_interest: bool,
    ): u64 acquires LendingPool {
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        // Validate caller is the registered credit manager (H-15)
        assert!(pool.credit_manager == credit_manager_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(
            table::contains(&pool.collateral_deposits, borrower),
            error::not_found(E_COLLATERAL_NOT_FOUND)
        );

        let (withdraw_amount, principal_withdrawn, interest_withdrawn, should_remove) = {
            let collateral_info = table::borrow_mut(&mut pool.collateral_deposits, borrower);

            // Settle pending interest first (C-08)
            settle_collateral_interest_internal(pool.accumulated_interest_per_share, collateral_info);

            let total_available = collateral_info.deposited_amount + collateral_info.earned_interest;

            // Determine withdrawal amount
            let withdraw_amt = if (include_interest && amount >= collateral_info.deposited_amount) {
                total_available
            } else {
                amount
            };

            // Deduct principal first, then interest
            let principal_part = if (withdraw_amt <= collateral_info.deposited_amount) {
                withdraw_amt
            } else {
                collateral_info.deposited_amount
            };
            let interest_part = withdraw_amt - principal_part;

            collateral_info.deposited_amount = collateral_info.deposited_amount - principal_part;
            collateral_info.earned_interest = collateral_info.earned_interest - interest_part;

            // Recalculate reward_debt
            collateral_info.reward_debt = (collateral_info.deposited_amount as u256)
                * pool.accumulated_interest_per_share / PRECISION;

            let remove = (collateral_info.deposited_amount == 0 && collateral_info.earned_interest == 0);

            (withdraw_amt, principal_part, interest_part, remove)
        };

        // Update pool totals
        pool.total_collateral = pool.total_collateral - principal_withdrawn;

        // Check available liquidity (safe subtraction — H-03)
        let pool_balance = fungible_asset::balance(pool.token_store);
        let available_liquidity = safe_subtract(pool_balance, pool.protocol_fees_collected);
        assert!(available_liquidity >= withdraw_amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

        // Remove borrower from collateral list if fully withdrawn
        if (should_remove) {
            remove_collateral_from_list(pool, borrower);
            table::remove(&mut pool.collateral_deposits, borrower);
        };

        // Transfer tokens to borrower
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&pool_signer, pool.token_store, withdraw_amount);
        dispatchable_fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(borrower, pool.token_metadata),
            fa
        );

        let remaining = if (!should_remove && table::contains(&pool.collateral_deposits, borrower)) {
            let info = table::borrow(&pool.collateral_deposits, borrower);
            info.deposited_amount + info.earned_interest
        } else {
            0
        };

        event::emit(CollateralWithdrawnEvent {
            borrower,
            amount: principal_withdrawn,
            interest_earned: interest_withdrawn,
            remaining_collateral: remaining,
            timestamp: timestamp::now_seconds(),
        });

        withdraw_amount
    }

    /// Seize collateral during liquidation — funds stay in pool to cover bad debt
    /// No token transfer occurs; only accounting is updated
    /// Deduction order: principal first, then interest overflow
    public(friend) fun seize_collateral(
        pool_addr: address,
        credit_manager_addr: address,
        borrower: address,
        amount: u64,
    ): u64 acquires LendingPool {
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        // Validate caller is the registered credit manager (H-15)
        assert!(pool.credit_manager == credit_manager_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(
            table::contains(&pool.collateral_deposits, borrower),
            error::not_found(E_COLLATERAL_NOT_FOUND)
        );

        let (seize_amount, principal_seized, interest_seized, should_remove) = {
            let collateral_info = table::borrow_mut(&mut pool.collateral_deposits, borrower);

            // Settle pending interest first (C-08)
            settle_collateral_interest_internal(pool.accumulated_interest_per_share, collateral_info);

            let total_available = collateral_info.deposited_amount + collateral_info.earned_interest;
            let seize_amt = if (amount > total_available) { total_available } else { amount };

            // Deduct principal first, then any excess from interest (H-04: comment now matches code)
            let principal_part = if (seize_amt <= collateral_info.deposited_amount) {
                seize_amt
            } else {
                collateral_info.deposited_amount
            };
            let interest_part = seize_amt - principal_part;

            collateral_info.deposited_amount = collateral_info.deposited_amount - principal_part;
            collateral_info.earned_interest = collateral_info.earned_interest - interest_part;

            // Recalculate reward_debt
            collateral_info.reward_debt = (collateral_info.deposited_amount as u256)
                * pool.accumulated_interest_per_share / PRECISION;

            let remove = (collateral_info.deposited_amount == 0 && collateral_info.earned_interest == 0);

            (seize_amt, principal_part, interest_part, remove)
        };

        // Update pool totals — track both principal and interest seizure (M-08)
        pool.total_collateral = pool.total_collateral - principal_seized;

        // Remove borrower from collateral list if fully seized
        if (should_remove) {
            remove_collateral_from_list(pool, borrower);
            table::remove(&mut pool.collateral_deposits, borrower);
        };

        // Tokens stay in pool — no transfer. They become available liquidity.

        let remaining = if (!should_remove && table::contains(&pool.collateral_deposits, borrower)) {
            let info = table::borrow(&pool.collateral_deposits, borrower);
            info.deposited_amount + info.earned_interest
        } else {
            0
        };

        event::emit(CollateralSeizedEvent {
            borrower,
            amount_seized: seize_amount,
            interest_seized,
            remaining_collateral: remaining,
            timestamp: timestamp::now_seconds(),
        });

        seize_amount
    }

    /// Borrow funds for direct payment to recipient (called by credit_manager)
    /// C-02: Removed the old public entry `borrow()` — all borrowing goes through this friend function
    public(friend) fun borrow_for_payment(
        pool_addr: address,
        credit_manager_addr: address,
        borrower: address,
        recipient: address,
        amount: u64,
    ): u64 acquires LendingPool {
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        // Validate caller is the registered credit manager (H-15)
        assert!(pool.credit_manager == credit_manager_addr, error::permission_denied(E_NOT_AUTHORIZED));

        // Check available liquidity (safe subtraction — H-10)
        let pool_balance = fungible_asset::balance(pool.token_store);
        let available_liquidity = safe_subtract(pool_balance, pool.protocol_fees_collected);
        assert!(available_liquidity >= amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

        pool.total_borrowed = pool.total_borrowed + amount;

        // Transfer tokens to recipient
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&pool_signer, pool.token_store, amount);
        dispatchable_fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(recipient, pool.token_metadata),
            fa
        );

        // Event records actual borrower AND recipient (M-02)
        event::emit(BorrowEvent {
            borrower,
            recipient,
            amount,
            timestamp: timestamp::now_seconds(),
        });

        amount
    }

    /// Receive repayment — O(1) interest distribution via accumulator (C-08)
    public(friend) fun receive_repayment(
        pool_addr: address,
        credit_manager_addr: address,
        borrower: address,
        principal: u64,
        interest: u64,
        from: &signer,
    ) acquires LendingPool {
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        // Validate caller is the registered credit manager (H-15)
        assert!(pool.credit_manager == credit_manager_addr, error::permission_denied(E_NOT_AUTHORIZED));

        let total_amount = principal + interest;

        // Calculate protocol fee (H-14: explicit parentheses for cast)
        let protocol_fee = (((interest as u256) * PROTOCOL_FEE_RATE / BASIS_POINTS) as u64);
        let distributable_interest = interest - protocol_fee;

        pool.total_repaid = pool.total_repaid + principal;
        pool.protocol_fees_collected = pool.protocol_fees_collected + protocol_fee;

        // O(1) interest distribution via accumulator — NO LOOP (C-08)
        if (distributable_interest > 0) {
            let total_funds = pool.total_deposited + pool.total_collateral;
            if (total_funds > 0) {
                pool.accumulated_interest_per_share = pool.accumulated_interest_per_share +
                    ((distributable_interest as u256) * PRECISION / (total_funds as u256));
            };
            // If total_funds == 0, undistributable interest stays in pool as surplus
        };

        // Receive repayment tokens from caller
        let fa = dispatchable_fungible_asset::withdraw(
            from,
            primary_fungible_store::primary_store(signer::address_of(from), pool.token_metadata),
            total_amount
        );
        dispatchable_fungible_asset::deposit(pool.token_store, fa);

        event::emit(RepayEvent {
            borrower,
            principal,
            interest,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Write off bad debt during liquidation — keeps utilization rate accurate (C-07)
    public(friend) fun write_off_bad_debt(
        pool_addr: address,
        credit_manager_addr: address,
        borrower: address,
        amount: u64,
    ) acquires LendingPool {
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        // Validate caller is the registered credit manager (H-15)
        assert!(pool.credit_manager == credit_manager_addr, error::permission_denied(E_NOT_AUTHORIZED));

        pool.total_repaid = pool.total_repaid + amount;

        event::emit(BadDebtWrittenOffEvent {
            borrower,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    // ========== Admin Functions ==========

    /// Update credit manager (only by admin)
    public entry fun update_credit_manager(
        admin: &signer,
        pool_addr: address,
        new_credit_manager: address,
    ) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_credit_manager != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        let old_manager = pool.credit_manager;
        pool.credit_manager = new_credit_manager;

        event::emit(CreditManagerUpdatedEvent {
            old_manager,
            new_manager: new_credit_manager,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Withdraw protocol fees (only by admin) — now emits event (H-05)
    public entry fun withdraw_protocol_fees(
        admin: &signer,
        pool_addr: address,
        to: address,
        amount: u64,
    ) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(to != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        let withdraw_amount = if (amount == 0) {
            pool.protocol_fees_collected
        } else {
            amount
        };

        assert!(withdraw_amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(
            withdraw_amount <= pool.protocol_fees_collected,
            error::invalid_argument(E_INSUFFICIENT_BALANCE)
        );

        pool.protocol_fees_collected = pool.protocol_fees_collected - withdraw_amount;

        // Transfer fees
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&pool_signer, pool.token_store, withdraw_amount);
        dispatchable_fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(to, pool.token_metadata),
            fa
        );

        event::emit(ProtocolFeesWithdrawnEvent {
            admin: admin_addr,
            to,
            amount: withdraw_amount,
            remaining_fees: pool.protocol_fees_collected,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Pause the lending pool
    public entry fun pause(admin: &signer, pool_addr: address) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        pool.is_paused = true;

        event::emit(PausedEvent {
            admin: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Unpause the lending pool
    public entry fun unpause(admin: &signer, pool_addr: address) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        pool.is_paused = false;

        event::emit(UnpausedEvent {
            admin: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Initiate admin transfer (2-step process)
    public entry fun transfer_admin(
        admin: &signer,
        pool_addr: address,
        new_admin: address,
    ) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_admin != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        pool.pending_admin = option::some(new_admin);

        event::emit(AdminTransferInitiatedEvent {
            current_admin: admin_addr,
            pending_admin: new_admin,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Accept admin transfer
    public entry fun accept_admin(
        new_admin: &signer,
        pool_addr: address,
    ) acquires LendingPool {
        let new_admin_addr = signer::address_of(new_admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(option::is_some(&pool.pending_admin), error::invalid_state(E_PENDING_ADMIN_NOT_SET));
        assert!(
            *option::borrow(&pool.pending_admin) == new_admin_addr,
            error::permission_denied(E_NOT_PENDING_ADMIN)
        );

        let old_admin = pool.admin;
        pool.admin = new_admin_addr;
        pool.pending_admin = option::none();

        event::emit(AdminTransferCompletedEvent {
            old_admin,
            new_admin: new_admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Cancel pending admin transfer — now emits event (H-06)
    public entry fun cancel_admin_transfer(
        admin: &signer,
        pool_addr: address,
    ) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        // NM-1: Require pending admin exists (consistent with credit_manager)
        assert!(option::is_some(&pool.pending_admin), error::invalid_state(E_PENDING_ADMIN_NOT_SET));

        let cancelled = *option::borrow(&pool.pending_admin);
        pool.pending_admin = option::none();

        event::emit(AdminTransferCancelledEvent {
            admin: admin_addr,
            cancelled_pending_admin: cancelled,
            timestamp: timestamp::now_seconds(),
        });
    }

    // ========== Internal Functions ==========

    /// Settle pending interest for a lender (lazy calculation from accumulator)
    fun settle_lender_interest_internal(accumulated: u256, lender_info: &mut LenderInfo) {
        if (lender_info.deposited_amount > 0) {
            let current_accumulated = (lender_info.deposited_amount as u256) * accumulated / PRECISION;
            if (current_accumulated > lender_info.reward_debt) {
                let pending = current_accumulated - lender_info.reward_debt;
                lender_info.earned_interest = lender_info.earned_interest + (pending as u64);
            };
        };
        lender_info.reward_debt = (lender_info.deposited_amount as u256) * accumulated / PRECISION;
    }

    /// Settle pending interest for a collateral depositor (lazy calculation from accumulator)
    fun settle_collateral_interest_internal(accumulated: u256, collateral_info: &mut CollateralInfo) {
        if (collateral_info.deposited_amount > 0) {
            let current_accumulated = (collateral_info.deposited_amount as u256) * accumulated / PRECISION;
            if (current_accumulated > collateral_info.reward_debt) {
                let pending = current_accumulated - collateral_info.reward_debt;
                collateral_info.earned_interest = collateral_info.earned_interest + (pending as u64);
            };
        };
        collateral_info.reward_debt = (collateral_info.deposited_amount as u256) * accumulated / PRECISION;
    }

    /// Safe subtraction — returns 0 if b > a (prevents underflow — H-03, H-10)
    fun safe_subtract(a: u64, b: u64): u64 {
        if (a > b) { a - b } else { 0 }
    }

    /// Remove lender from list
    fun remove_lender_from_list(pool: &mut LendingPool, lender: address) {
        let i = 0;
        let len = vector::length(&pool.lenders_list);
        while (i < len) {
            if (*vector::borrow(&pool.lenders_list, i) == lender) {
                vector::swap_remove(&mut pool.lenders_list, i);
                return
            };
            i = i + 1;
        };
    }

    /// Remove collateral depositor from list
    fun remove_collateral_from_list(pool: &mut LendingPool, borrower: address) {
        let i = 0;
        let len = vector::length(&pool.collateral_list);
        while (i < len) {
            if (*vector::borrow(&pool.collateral_list, i) == borrower) {
                vector::swap_remove(&mut pool.collateral_list, i);
                return
            };
            i = i + 1;
        };
    }

    // ========== View Functions ==========

    #[view]
    /// Get collateral info with lazily-calculated interest
    public fun get_collateral_with_interest(
        pool_addr: address,
        borrower: address,
    ): (u64, u64, u64) acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);

        if (table::contains(&pool.collateral_deposits, borrower)) {
            let collateral_info = table::borrow(&pool.collateral_deposits, borrower);
            // Calculate pending interest without mutating (view function)
            let pending = calculate_pending_interest(
                collateral_info.deposited_amount,
                pool.accumulated_interest_per_share,
                collateral_info.reward_debt
            );
            let total_interest = collateral_info.earned_interest + pending;
            let total = collateral_info.deposited_amount + total_interest;
            (collateral_info.deposited_amount, total_interest, total)
        } else {
            (0, 0, 0)
        }
    }

    #[view]
    /// Check if borrower has collateral deposited
    public fun has_collateral(pool_addr: address, borrower: address): bool acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        table::contains(&pool.collateral_deposits, borrower)
    }

    #[view]
    /// Get available liquidity in the pool
    public fun get_available_liquidity(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        let pool_balance = fungible_asset::balance(pool.token_store);
        safe_subtract(pool_balance, pool.protocol_fees_collected)
    }

    #[view]
    /// Get utilization rate of the pool
    public fun get_utilization_rate(pool_addr: address): u256 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        let total_funds = pool.total_deposited + pool.total_collateral;
        if (total_funds == 0) return 0;

        let current_borrowed = safe_subtract(pool.total_borrowed, pool.total_repaid);

        ((current_borrowed as u256) * BASIS_POINTS) / (total_funds as u256)
    }

    #[view]
    /// Get lender information with lazily-calculated interest
    public fun get_lender_info(
        pool_addr: address,
        lender: address,
    ): (u64, u64, u64) acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);

        if (table::contains(&pool.lenders, lender)) {
            let lender_info = table::borrow(&pool.lenders, lender);
            let pending = calculate_pending_interest(
                lender_info.deposited_amount,
                pool.accumulated_interest_per_share,
                lender_info.reward_debt
            );
            let total_interest = lender_info.earned_interest + pending;
            (lender_info.deposited_amount, total_interest, lender_info.initial_deposit_timestamp)
        } else {
            (0, 0, 0)
        }
    }

    #[view]
    /// Get all lenders
    public fun get_all_lenders(pool_addr: address): vector<address> acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.lenders_list
    }

    #[view]
    /// Get all collateral depositors
    public fun get_all_collateral_depositors(pool_addr: address): vector<address> acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.collateral_list
    }

    #[view]
    public fun get_token_metadata(pool_addr: address): Object<Metadata> acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.token_metadata
    }

    #[view]
    public fun get_total_deposited(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.total_deposited
    }

    #[view]
    public fun get_total_collateral(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.total_collateral
    }

    #[view]
    public fun get_total_borrowed(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.total_borrowed
    }

    #[view]
    public fun get_total_repaid(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.total_repaid
    }

    #[view]
    public fun get_protocol_fees_collected(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.protocol_fees_collected
    }

    #[view]
    public fun is_paused(pool_addr: address): bool acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.is_paused
    }

    #[view]
    public fun get_admin(pool_addr: address): address acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.admin
    }

    #[view]
    public fun get_credit_manager(pool_addr: address): address acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.credit_manager
    }

    // ========== Pure Helper ==========

    /// Calculate pending interest without mutation (for view functions)
    fun calculate_pending_interest(deposited_amount: u64, accumulated: u256, reward_debt: u256): u64 {
        if (deposited_amount == 0) return 0;
        let current = (deposited_amount as u256) * accumulated / PRECISION;
        if (current > reward_debt) {
            ((current - reward_debt) as u64)
        } else {
            0
        }
    }
}
