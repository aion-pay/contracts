module credit_protocol::collateral_vault {
    use std::signer;
    use std::error;
    use std::vector;
    use std::string::String;
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
    const E_INSUFFICIENT_COLLATERAL: u64 = 2;
    const E_INVALID_AMOUNT: u64 = 3;
    const E_ALREADY_INITIALIZED: u64 = 4;
    const E_NOT_INITIALIZED: u64 = 5;
    const E_INVALID_ADDRESS: u64 = 6;
    const E_EXCEEDS_MAX_LIMIT: u64 = 7;
    const E_INSUFFICIENT_LOCKED_COLLATERAL: u64 = 8;
    const E_NOT_ENOUGH_UNLOCKED_COLLATERAL: u64 = 9;
    const E_CONTRACT_NOT_PAUSED: u64 = 10;
    const E_INVALID_PARAMETERS: u64 = 11;
    const E_PENDING_ADMIN_NOT_SET: u64 = 12;
    const E_NOT_PENDING_ADMIN: u64 = 13;
    const E_BELOW_MINIMUM_AMOUNT: u64 = 14;

    /// Constants
    const BASIS_POINTS: u256 = 10000;
    const MIN_COLLATERAL_AMOUNT: u64 = 1000000; // Minimum 1 USDC (6 decimals)
    const MIN_COLLATERALIZATION_RATIO: u256 = 10000; // 100% minimum
    const MAX_COLLATERALIZATION_RATIO: u256 = 50000; // 500% maximum

    /// Collateral status constants
    const COLLATERAL_STATUS_ACTIVE: u8 = 0;
    const COLLATERAL_STATUS_LOCKED: u8 = 1;
    const COLLATERAL_STATUS_LIQUIDATING: u8 = 2;

    /// User collateral information structure
    struct UserCollateral has copy, store, drop {
        amount: u64,
        status: u8,
        locked_amount: u64,
        last_update_timestamp: u64,
    }

    /// Collateral vault resource - uses Fungible Asset standard
    struct CollateralVault has key {
        admin: address,
        pending_admin: Option<address>,
        credit_manager: address,
        liquidator: Option<address>,
        user_collateral: Table<address, UserCollateral>,
        users_list: vector<address>,
        total_collateral: u64,
        token_metadata: Object<Metadata>,
        token_store: Object<FungibleStore>,
        extend_ref: ExtendRef,  // For withdrawing from the store
        collateralization_ratio: u256,
        liquidation_threshold: u256,
        max_collateral_amount: u64,
        is_paused: bool,
    }

    #[event]
    struct CollateralDepositedEvent has drop, store {
        user: address,
        amount: u64,
        total_user_collateral: u64,
        timestamp: u64,
    }

    #[event]
    struct CollateralWithdrawnEvent has drop, store {
        user: address,
        amount: u64,
        remaining_collateral: u64,
        timestamp: u64,
    }

    #[event]
    struct CollateralLockedEvent has drop, store {
        user: address,
        amount: u64,
        reason: String,
        timestamp: u64,
    }

    #[event]
    struct CollateralUnlockedEvent has drop, store {
        user: address,
        amount: u64,
        timestamp: u64,
    }

    #[event]
    struct CollateralLiquidatedEvent has drop, store {
        user: address,
        amount: u64,
        liquidator: address,
        timestamp: u64,
    }

    #[event]
    struct EmergencyWithdrawalEvent has drop, store {
        user: address,
        amount: u64,
        admin: address,
        timestamp: u64,
    }

    #[event]
    struct ParametersUpdatedEvent has drop, store {
        collateralization_ratio: u256,
        liquidation_threshold: u256,
        max_collateral_amount: u64,
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

    /// Initialize the collateral vault with a specific fungible asset
    public entry fun initialize(
        admin: &signer,
        credit_manager: address,
        token_metadata_addr: address,
    ) {
        let admin_addr = signer::address_of(admin);

        assert!(!exists<CollateralVault>(admin_addr), error::already_exists(E_ALREADY_INITIALIZED));
        assert!(credit_manager != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        let token_metadata = object::address_to_object<Metadata>(token_metadata_addr);

        // Create a fungible store for the vault
        let constructor_ref = object::create_object(admin_addr);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let token_store = fungible_asset::create_store(&constructor_ref, token_metadata);

        let collateral_vault = CollateralVault {
            admin: admin_addr,
            pending_admin: option::none(),
            credit_manager,
            liquidator: option::none(),
            user_collateral: table::new(),
            users_list: vector::empty(),
            total_collateral: 0,
            token_metadata,
            token_store,
            extend_ref,
            collateralization_ratio: 15000, // 150%
            liquidation_threshold: 12000,   // 120%
            max_collateral_amount: 1000000000000, // 1M USDC (with 6 decimals)
            is_paused: false,
        };

        move_to(admin, collateral_vault);
    }

    /// Deposit collateral (only by credit manager)
    public entry fun deposit_collateral(
        credit_manager: &signer,
        vault_addr: address,
        borrower: address,
        amount: u64,
    ) acquires CollateralVault {
        let manager_addr = signer::address_of(credit_manager);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.credit_manager == manager_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(!vault.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(amount >= MIN_COLLATERAL_AMOUNT, error::invalid_argument(E_BELOW_MINIMUM_AMOUNT));
        assert!(borrower != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        assert!(
            vault.total_collateral + amount <= vault.max_collateral_amount,
            error::invalid_state(E_EXCEEDS_MAX_LIMIT)
        );

        // Transfer collateral from credit_manager to vault using dispatchable fungible asset
        let fa = dispatchable_fungible_asset::withdraw(credit_manager, primary_fungible_store::primary_store(signer::address_of(credit_manager), vault.token_metadata), amount);
        dispatchable_fungible_asset::deposit(vault.token_store, fa);

        // Update or create user collateral
        if (table::contains(&vault.user_collateral, borrower)) {
            let user_collateral = table::borrow_mut(&mut vault.user_collateral, borrower);
            user_collateral.amount = user_collateral.amount + amount;
            user_collateral.last_update_timestamp = timestamp::now_seconds();

            if (user_collateral.status == COLLATERAL_STATUS_LIQUIDATING) {
                user_collateral.status = COLLATERAL_STATUS_ACTIVE;
            };

            event::emit(CollateralDepositedEvent {
                user: borrower,
                amount,
                total_user_collateral: user_collateral.amount,
                timestamp: timestamp::now_seconds(),
            });
        } else {
            let user_collateral = UserCollateral {
                amount,
                status: COLLATERAL_STATUS_ACTIVE,
                locked_amount: 0,
                last_update_timestamp: timestamp::now_seconds(),
            };
            table::add(&mut vault.user_collateral, borrower, user_collateral);
            vector::push_back(&mut vault.users_list, borrower);

            event::emit(CollateralDepositedEvent {
                user: borrower,
                amount,
                total_user_collateral: amount,
                timestamp: timestamp::now_seconds(),
            });
        };

        vault.total_collateral = vault.total_collateral + amount;
    }

    /// Withdraw collateral (only by credit manager)
    public entry fun withdraw_collateral(
        credit_manager: &signer,
        vault_addr: address,
        borrower: address,
        amount: u64,
    ) acquires CollateralVault {
        let manager_addr = signer::address_of(credit_manager);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.credit_manager == manager_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(!vault.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(table::contains(&vault.user_collateral, borrower), error::not_found(E_NOT_INITIALIZED));

        let user_collateral = table::borrow_mut(&mut vault.user_collateral, borrower);
        assert!(user_collateral.amount >= amount, error::invalid_argument(E_INSUFFICIENT_COLLATERAL));
        let available_collateral = user_collateral.amount - user_collateral.locked_amount;
        assert!(available_collateral >= amount, error::invalid_state(E_NOT_ENOUGH_UNLOCKED_COLLATERAL));

        user_collateral.amount = user_collateral.amount - amount;
        user_collateral.last_update_timestamp = timestamp::now_seconds();
        vault.total_collateral = vault.total_collateral - amount;

        let remaining_collateral = user_collateral.amount;
        if (remaining_collateral == 0) {
            remove_user_from_list(vault, borrower);
            table::remove(&mut vault.user_collateral, borrower);
        };

        // Transfer collateral to borrower using dispatchable fungible asset
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&vault_signer, vault.token_store, amount);
        dispatchable_fungible_asset::deposit(primary_fungible_store::ensure_primary_store_exists(borrower, vault.token_metadata), fa);

        event::emit(CollateralWithdrawnEvent {
            user: borrower,
            amount,
            remaining_collateral,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Lock collateral (only by credit manager)
    public entry fun lock_collateral(
        credit_manager: &signer,
        vault_addr: address,
        user: address,
        amount: u64,
        reason: String,
    ) acquires CollateralVault {
        let manager_addr = signer::address_of(credit_manager);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.credit_manager == manager_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(table::contains(&vault.user_collateral, user), error::not_found(E_NOT_INITIALIZED));

        let user_collateral = table::borrow_mut(&mut vault.user_collateral, user);
        assert!(user_collateral.amount >= amount, error::invalid_argument(E_INSUFFICIENT_COLLATERAL));
        assert!(
            user_collateral.amount - user_collateral.locked_amount >= amount,
            error::invalid_state(E_NOT_ENOUGH_UNLOCKED_COLLATERAL)
        );

        user_collateral.locked_amount = user_collateral.locked_amount + amount;
        user_collateral.status = COLLATERAL_STATUS_LOCKED;
        user_collateral.last_update_timestamp = timestamp::now_seconds();

        event::emit(CollateralLockedEvent {
            user,
            amount,
            reason,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Unlock collateral (only by credit manager)
    public entry fun unlock_collateral(
        credit_manager: &signer,
        vault_addr: address,
        user: address,
        amount: u64,
    ) acquires CollateralVault {
        let manager_addr = signer::address_of(credit_manager);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.credit_manager == manager_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(table::contains(&vault.user_collateral, user), error::not_found(E_NOT_INITIALIZED));

        let user_collateral = table::borrow_mut(&mut vault.user_collateral, user);
        assert!(
            user_collateral.locked_amount >= amount,
            error::invalid_argument(E_INSUFFICIENT_LOCKED_COLLATERAL)
        );

        user_collateral.locked_amount = user_collateral.locked_amount - amount;
        if (user_collateral.locked_amount == 0) {
            user_collateral.status = COLLATERAL_STATUS_ACTIVE;
        };
        user_collateral.last_update_timestamp = timestamp::now_seconds();

        event::emit(CollateralUnlockedEvent {
            user,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Liquidate collateral (only by authorized liquidator)
    public entry fun liquidate_collateral(
        liquidator: &signer,
        vault_addr: address,
        user: address,
        amount: u64,
    ) acquires CollateralVault {
        let liquidator_addr = signer::address_of(liquidator);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        let is_authorized = vault.credit_manager == liquidator_addr ||
            (option::is_some(&vault.liquidator) && *option::borrow(&vault.liquidator) == liquidator_addr);
        assert!(is_authorized, error::permission_denied(E_NOT_AUTHORIZED));

        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(table::contains(&vault.user_collateral, user), error::not_found(E_NOT_INITIALIZED));

        let user_collateral = table::borrow_mut(&mut vault.user_collateral, user);
        assert!(user_collateral.amount >= amount, error::invalid_argument(E_INSUFFICIENT_COLLATERAL));

        user_collateral.amount = user_collateral.amount - amount;
        user_collateral.status = COLLATERAL_STATUS_LIQUIDATING;
        user_collateral.last_update_timestamp = timestamp::now_seconds();
        vault.total_collateral = vault.total_collateral - amount;

        if (user_collateral.amount == 0) {
            remove_user_from_list(vault, user);
            table::remove(&mut vault.user_collateral, user);
        };

        // Transfer liquidated collateral to liquidator using dispatchable fungible asset
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&vault_signer, vault.token_store, amount);
        dispatchable_fungible_asset::deposit(primary_fungible_store::ensure_primary_store_exists(liquidator_addr, vault.token_metadata), fa);

        event::emit(CollateralLiquidatedEvent {
            user,
            amount,
            liquidator: liquidator_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Emergency withdraw (only by admin when paused)
    public entry fun emergency_withdraw(
        admin: &signer,
        vault_addr: address,
        user: address,
        amount: u64,
    ) acquires CollateralVault {
        let admin_addr = signer::address_of(admin);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(vault.is_paused, error::invalid_state(E_CONTRACT_NOT_PAUSED));
        assert!(table::contains(&vault.user_collateral, user), error::not_found(E_NOT_INITIALIZED));

        let user_collateral = table::borrow_mut(&mut vault.user_collateral, user);
        assert!(user_collateral.amount >= amount, error::invalid_argument(E_INSUFFICIENT_COLLATERAL));

        user_collateral.amount = user_collateral.amount - amount;
        vault.total_collateral = vault.total_collateral - amount;

        // Emergency withdraw using dispatchable fungible asset
        let vault_signer = object::generate_signer_for_extending(&vault.extend_ref);
        let fa = dispatchable_fungible_asset::withdraw(&vault_signer, vault.token_store, amount);
        dispatchable_fungible_asset::deposit(primary_fungible_store::ensure_primary_store_exists(user, vault.token_metadata), fa);

        event::emit(EmergencyWithdrawalEvent {
            user,
            amount,
            admin: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Update parameters (only by admin)
    public entry fun update_parameters(
        admin: &signer,
        vault_addr: address,
        collateralization_ratio: u256,
        liquidation_threshold: u256,
        max_collateral_amount: u64,
    ) acquires CollateralVault {
        let admin_addr = signer::address_of(admin);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(
            collateralization_ratio >= MIN_COLLATERALIZATION_RATIO &&
            collateralization_ratio <= MAX_COLLATERALIZATION_RATIO,
            error::invalid_argument(E_INVALID_PARAMETERS)
        );
        assert!(
            liquidation_threshold >= MIN_COLLATERALIZATION_RATIO &&
            liquidation_threshold < collateralization_ratio,
            error::invalid_argument(E_INVALID_PARAMETERS)
        );
        assert!(max_collateral_amount > 0, error::invalid_argument(E_INVALID_PARAMETERS));

        vault.collateralization_ratio = collateralization_ratio;
        vault.liquidation_threshold = liquidation_threshold;
        vault.max_collateral_amount = max_collateral_amount;

        event::emit(ParametersUpdatedEvent {
            collateralization_ratio,
            liquidation_threshold,
            max_collateral_amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Set liquidator (only by admin)
    public entry fun set_liquidator(
        admin: &signer,
        vault_addr: address,
        liquidator: address,
    ) acquires CollateralVault {
        let admin_addr = signer::address_of(admin);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        vault.liquidator = option::some(liquidator);
    }

    /// Remove liquidator (only by admin)
    public entry fun remove_liquidator(
        admin: &signer,
        vault_addr: address,
    ) acquires CollateralVault {
        let admin_addr = signer::address_of(admin);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        vault.liquidator = option::none();
    }

    /// Pause the vault
    public entry fun pause(admin: &signer, vault_addr: address) acquires CollateralVault {
        let admin_addr = signer::address_of(admin);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        vault.is_paused = true;

        event::emit(PausedEvent {
            admin: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Unpause the vault
    public entry fun unpause(admin: &signer, vault_addr: address) acquires CollateralVault {
        let admin_addr = signer::address_of(admin);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        vault.is_paused = false;

        event::emit(UnpausedEvent {
            admin: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Initiate admin transfer (2-step process for security)
    public entry fun transfer_admin(
        admin: &signer,
        vault_addr: address,
        new_admin: address,
    ) acquires CollateralVault {
        let admin_addr = signer::address_of(admin);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_admin != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        vault.pending_admin = option::some(new_admin);

        event::emit(AdminTransferInitiatedEvent {
            current_admin: admin_addr,
            pending_admin: new_admin,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Accept admin transfer (must be called by pending admin)
    public entry fun accept_admin(
        new_admin: &signer,
        vault_addr: address,
    ) acquires CollateralVault {
        let new_admin_addr = signer::address_of(new_admin);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(option::is_some(&vault.pending_admin), error::invalid_state(E_PENDING_ADMIN_NOT_SET));
        assert!(
            *option::borrow(&vault.pending_admin) == new_admin_addr,
            error::permission_denied(E_NOT_PENDING_ADMIN)
        );

        let old_admin = vault.admin;
        vault.admin = new_admin_addr;
        vault.pending_admin = option::none();

        event::emit(AdminTransferCompletedEvent {
            old_admin,
            new_admin: new_admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Cancel pending admin transfer
    public entry fun cancel_admin_transfer(
        admin: &signer,
        vault_addr: address,
    ) acquires CollateralVault {
        let admin_addr = signer::address_of(admin);
        let vault = borrow_global_mut<CollateralVault>(vault_addr);

        assert!(vault.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        vault.pending_admin = option::none();
    }

    /// Get collateral balance for a user
    public fun get_collateral_balance(vault_addr: address, user: address): u64 acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        if (table::contains(&vault.user_collateral, user)) {
            let user_collateral = table::borrow(&vault.user_collateral, user);
            user_collateral.amount
        } else {
            0
        }
    }

    /// Get user collateral details
    public fun get_user_collateral(
        vault_addr: address,
        user: address,
    ): (u64, u64, u64, u8) acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        if (table::contains(&vault.user_collateral, user)) {
            let user_collateral = table::borrow(&vault.user_collateral, user);
            let available_amount = user_collateral.amount - user_collateral.locked_amount;
            (user_collateral.amount, user_collateral.locked_amount, available_amount, user_collateral.status)
        } else {
            (0, 0, 0, COLLATERAL_STATUS_ACTIVE)
        }
    }

    /// Get all users
    public fun get_all_users(vault_addr: address): vector<address> acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        vault.users_list
    }

    /// Internal function to remove user from list
    fun remove_user_from_list(vault: &mut CollateralVault, user: address) {
        let i = 0;
        let len = vector::length(&vault.users_list);
        let found = false;

        while (i < len && !found) {
            if (*vector::borrow(&vault.users_list, i) == user) {
                vector::swap_remove(&mut vault.users_list, i);
                found = true;
            } else {
                i = i + 1;
            };
        };
    }

    /// View functions
    public fun get_total_collateral(vault_addr: address): u64 acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        vault.total_collateral
    }

    public fun get_collateralization_ratio(vault_addr: address): u256 acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        vault.collateralization_ratio
    }

    public fun get_liquidation_threshold(vault_addr: address): u256 acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        vault.liquidation_threshold
    }

    public fun get_max_collateral_amount(vault_addr: address): u64 acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        vault.max_collateral_amount
    }

    public fun is_paused(vault_addr: address): bool acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        vault.is_paused
    }

    public fun get_admin(vault_addr: address): address acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        vault.admin
    }

    public fun get_credit_manager(vault_addr: address): address acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        vault.credit_manager
    }

    public fun get_token_metadata(vault_addr: address): Object<Metadata> acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(vault_addr);
        vault.token_metadata
    }
}
