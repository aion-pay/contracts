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

    /// Constants
    const BASIS_POINTS: u256 = 10000;
    const PROTOCOL_FEE_RATE: u256 = 1000; // 10%
    const MIN_DEPOSIT_AMOUNT: u64 = 1000000; // Minimum 1 USDC (6 decimals)

    /// Lender information structure
    struct LenderInfo has copy, store, drop {
        deposited_amount: u64,
        earned_interest: u64,
        deposit_timestamp: u64,
    }

    /// Lending pool resource - uses Fungible Asset standard
    struct LendingPool has key {
        admin: address,
        pending_admin: Option<address>,
        credit_manager: address,
        total_deposited: u64,
        total_borrowed: u64,
        total_repaid: u64,
        protocol_fees_collected: u64,
        lenders: Table<address, LenderInfo>,
        lenders_list: vector<address>,
        token_metadata: Object<Metadata>,
        token_store: Object<FungibleStore>,
        extend_ref: ExtendRef,  // For withdrawing from the store
        is_paused: bool,
    }

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
    struct BorrowEvent has drop, store {
        borrower: address,
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
            total_borrowed: 0,
            total_repaid: 0,
            protocol_fees_collected: 0,
            lenders: table::new(),
            lenders_list: vector::empty(),
            token_metadata,
            token_store,
            extend_ref,
            is_paused: false,
        };

        move_to(admin, lending_pool);
    }

    /// Deposit funds into the lending pool
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

        // Transfer tokens from lender to pool using dispatchable fungible asset
        let fa = dispatchable_fungible_asset::withdraw(lender, primary_fungible_store::primary_store(signer::address_of(lender), pool.token_metadata), amount);
        dispatchable_fungible_asset::deposit(pool.token_store, fa);

        // Update or create lender info
        if (table::contains(&pool.lenders, lender_addr)) {
            let lender_info = table::borrow_mut(&mut pool.lenders, lender_addr);
            lender_info.deposited_amount = lender_info.deposited_amount + amount;
            lender_info.deposit_timestamp = timestamp::now_seconds();
        } else {
            let lender_info = LenderInfo {
                deposited_amount: amount,
                earned_interest: 0,
                deposit_timestamp: timestamp::now_seconds(),
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

    /// Withdraw funds from the lending pool
    public entry fun withdraw(
        lender: &signer,
        pool_addr: address,
        amount: u64,
    ) acquires LendingPool {
        let lender_addr = signer::address_of(lender);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(!pool.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(table::contains(&pool.lenders, lender_addr), error::not_found(E_NOT_INITIALIZED));

        // Check available liquidity first
        let pool_balance = fungible_asset::balance(pool.token_store);
        let available_liquidity = pool_balance - pool.protocol_fees_collected;
        assert!(available_liquidity >= amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

        let lender_info = table::borrow_mut(&mut pool.lenders, lender_addr);
        assert!(lender_info.deposited_amount >= amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));

        // Update lender info
        lender_info.deposited_amount = lender_info.deposited_amount - amount;
        pool.total_deposited = pool.total_deposited - amount;

        // Remove lender if balance is zero
        if (lender_info.deposited_amount == 0) {
            remove_lender_from_list(pool, lender_addr);
            table::remove(&mut pool.lenders, lender_addr);
        };

        // Transfer tokens to lender using extend_ref for signer capability
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&pool_signer, pool.token_store, amount);
        dispatchable_fungible_asset::deposit(primary_fungible_store::ensure_primary_store_exists(lender_addr, pool.token_metadata), fa);

        event::emit(WithdrawEvent {
            lender: lender_addr,
            amount,
            interest: 0,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Borrow funds from the lending pool (only by credit manager)
    public entry fun borrow(
        credit_manager: &signer,
        pool_addr: address,
        borrower: address,
        amount: u64,
    ) acquires LendingPool {
        let manager_addr = signer::address_of(credit_manager);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.credit_manager == manager_addr, error::permission_denied(E_NOT_AUTHORIZED));

        // Check available liquidity
        let pool_balance = fungible_asset::balance(pool.token_store);
        let available_liquidity = pool_balance - pool.protocol_fees_collected;
        assert!(available_liquidity >= amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

        pool.total_borrowed = pool.total_borrowed + amount;

        // Transfer tokens to borrower using dispatchable fungible asset
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&pool_signer, pool.token_store, amount);
        dispatchable_fungible_asset::deposit(primary_fungible_store::ensure_primary_store_exists(borrower, pool.token_metadata), fa);

        event::emit(BorrowEvent {
            borrower,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Borrow funds for direct payment to recipient (called internally by credit_manager)
    public fun borrow_for_payment(
        pool_addr: address,
        borrower: address,
        amount: u64,
    ): u64 acquires LendingPool {
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        // Check available liquidity
        let pool_balance = fungible_asset::balance(pool.token_store);
        let available_liquidity = pool_balance - pool.protocol_fees_collected;
        assert!(available_liquidity >= amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

        pool.total_borrowed = pool.total_borrowed + amount;

        // Transfer tokens to borrower using dispatchable fungible asset
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&pool_signer, pool.token_store, amount);
        dispatchable_fungible_asset::deposit(primary_fungible_store::ensure_primary_store_exists(borrower, pool.token_metadata), fa);

        event::emit(BorrowEvent {
            borrower,
            amount,
            timestamp: timestamp::now_seconds(),
        });

        amount
    }

    /// Receive repayment - called by credit_manager after withdrawing from borrower
    public fun receive_repayment(
        pool_addr: address,
        borrower: address,
        principal: u64,
        interest: u64,
        from: &signer,
    ) acquires LendingPool {
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        let total_amount = principal + interest;

        // Calculate protocol fee
        let protocol_fee = ((interest as u256) * PROTOCOL_FEE_RATE / BASIS_POINTS as u64);
        let lender_interest = interest - protocol_fee;

        pool.total_repaid = pool.total_repaid + principal;
        pool.protocol_fees_collected = pool.protocol_fees_collected + protocol_fee;

        // Distribute interest to lenders
        if (lender_interest > 0 && pool.total_deposited > 0) {
            distribute_interest(pool, lender_interest);
        };

        // Receive repayment tokens from caller using dispatchable fungible asset
        let fa = dispatchable_fungible_asset::withdraw(from, primary_fungible_store::primary_store(signer::address_of(from), pool.token_metadata), total_amount);
        dispatchable_fungible_asset::deposit(pool.token_store, fa);

        event::emit(RepayEvent {
            borrower,
            principal,
            interest,
            timestamp: timestamp::now_seconds(),
        });
    }

    #[view]
    /// Get available liquidity in the pool
    public fun get_available_liquidity(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        let pool_balance = fungible_asset::balance(pool.token_store);
        if (pool_balance > pool.protocol_fees_collected) {
            pool_balance - pool.protocol_fees_collected
        } else {
            0
        }
    }

    #[view]
    /// Get utilization rate of the pool
    public fun get_utilization_rate(pool_addr: address): u256 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        if (pool.total_deposited == 0) return 0;

        let current_borrowed = if (pool.total_borrowed > pool.total_repaid) {
            pool.total_borrowed - pool.total_repaid
        } else {
            0
        };

        ((current_borrowed as u256) * BASIS_POINTS) / (pool.total_deposited as u256)
    }

    #[view]
    /// Get lender information
    public fun get_lender_info(
        pool_addr: address,
        lender: address,
    ): (u64, u64, u64) acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);

        if (table::contains(&pool.lenders, lender)) {
            let lender_info = table::borrow(&pool.lenders, lender);
            (lender_info.deposited_amount, lender_info.earned_interest, lender_info.deposit_timestamp)
        } else {
            (0, 0, 0)
        }
    }

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

    /// Withdraw protocol fees (only by admin)
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

        assert!(
            withdraw_amount <= pool.protocol_fees_collected,
            error::invalid_argument(E_INSUFFICIENT_BALANCE)
        );

        pool.protocol_fees_collected = pool.protocol_fees_collected - withdraw_amount;

        // Transfer fees using dispatchable fungible asset
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&pool_signer, pool.token_store, withdraw_amount);
        dispatchable_fungible_asset::deposit(primary_fungible_store::ensure_primary_store_exists(to, pool.token_metadata), fa);
    }

    #[view]
    /// Get all lenders
    public fun get_all_lenders(pool_addr: address): vector<address> acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.lenders_list
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

    /// Initiate admin transfer (2-step process for security)
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

    /// Accept admin transfer (must be called by pending admin)
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

    /// Cancel pending admin transfer
    public entry fun cancel_admin_transfer(
        admin: &signer,
        pool_addr: address,
    ) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        pool.pending_admin = option::none();
    }

    /// Internal function to distribute interest to lenders
    fun distribute_interest(pool: &mut LendingPool, interest_amount: u64) {
        let i = 0;
        let len = vector::length(&pool.lenders_list);

        while (i < len) {
            let lender_addr = *vector::borrow(&pool.lenders_list, i);
            let lender_info = table::borrow_mut(&mut pool.lenders, lender_addr);

            if (lender_info.deposited_amount > 0) {
                let lender_share = ((lender_info.deposited_amount as u256) * (interest_amount as u256))
                    / (pool.total_deposited as u256);
                lender_info.earned_interest = lender_info.earned_interest + (lender_share as u64);
            };

            i = i + 1;
        };
    }

    /// Internal function to remove lender from list
    fun remove_lender_from_list(pool: &mut LendingPool, lender: address) {
        let i = 0;
        let len = vector::length(&pool.lenders_list);
        let found = false;

        while (i < len && !found) {
            if (*vector::borrow(&pool.lenders_list, i) == lender) {
                vector::swap_remove(&mut pool.lenders_list, i);
                found = true;
            } else {
                i = i + 1;
            };
        };
    }

    #[view]
    /// Get token metadata address
    public fun get_token_metadata(pool_addr: address): Object<Metadata> acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.token_metadata
    }

    /// View functions
    #[view]
    public fun get_total_deposited(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.total_deposited
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
}
