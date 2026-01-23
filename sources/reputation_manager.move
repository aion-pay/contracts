module credit_protocol::reputation_manager {
    use std::signer;
    use std::error;
    use std::vector;
    use std::string::{Self, String};
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::table::{Self, Table};

    /// Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_USER_NOT_INITIALIZED: u64 = 2;
    const E_USER_ALREADY_INITIALIZED: u64 = 3;
    const E_ALREADY_INITIALIZED: u64 = 4;
    const E_INVALID_ADDRESS: u64 = 5;
    const E_PENDING_ADMIN_NOT_SET: u64 = 6;
    const E_NOT_PENDING_ADMIN: u64 = 7;
    const E_INVALID_PARAMETERS: u64 = 8;

    /// Constants
    const MIN_SCORE: u256 = 0;
    const MAX_SCORE: u256 = 1000;
    const DEFAULT_SCORE: u256 = 500;
    const BRONZE_THRESHOLD: u256 = 300;
    const SILVER_THRESHOLD: u256 = 600;
    const GOLD_THRESHOLD: u256 = 850;

    /// Reputation tier constants
    const REPUTATION_TIER_BRONZE: u8 = 0;
    const REPUTATION_TIER_SILVER: u8 = 1;
    const REPUTATION_TIER_GOLD: u8 = 2;
    const REPUTATION_TIER_PLATINUM: u8 = 3;

    /// Reputation data structure
    struct ReputationData has copy, store, drop {
        score: u256,
        last_updated: u64,
        total_repayments: u64,
        on_time_repayments: u64,
        late_repayments: u64,
        defaults: u64,
        tier: u8,
        is_initialized: bool,
    }

    /// Reputation manager resource
    struct ReputationManager has key {
        admin: address,
        pending_admin: std::option::Option<address>,
        credit_manager: address,
        reputations: Table<address, ReputationData>,
        users_list: vector<address>,
        on_time_bonus: u256,
        late_payment_penalty: u256,
        default_penalty: u256,
        max_score_change: u256,
        is_paused: bool,
    }

    /// Events
    #[event]
    struct ScoreUpdatedEvent has drop, store {
        user: address,
        old_score: u256,
        new_score: u256,
        is_increase: bool,
        reason: String,
        timestamp: u64,
    }

    #[event]
    struct TierChangedEvent has drop, store {
        user: address,
        old_tier: u8,
        new_tier: u8,
        timestamp: u64,
    }

    #[event]
    struct UserInitializedEvent has drop, store {
        user: address,
        initial_score: u256,
        initial_tier: u8,
        timestamp: u64,
    }

    #[event]
    struct DefaultRecordedEvent has drop, store {
        user: address,
        debt_amount: u64,
        penalty_applied: u256,
        timestamp: u64,
    }

    #[event]
    struct ParametersUpdatedEvent has drop, store {
        on_time_bonus: u256,
        late_payment_penalty: u256,
        default_penalty: u256,
        max_score_change: u256,
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

    /// Initialize the reputation manager
    public entry fun initialize(
        admin: &signer,
        credit_manager: address,
    ) {
        let admin_addr = signer::address_of(admin);

        assert!(!exists<ReputationManager>(admin_addr), error::already_exists(E_ALREADY_INITIALIZED));
        assert!(credit_manager != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        let reputation_manager = ReputationManager {
            admin: admin_addr,
            pending_admin: std::option::none(),
            credit_manager,
            reputations: table::new(),
            users_list: vector::empty(),
            on_time_bonus: 20,
            late_payment_penalty: 15,
            default_penalty: 50,
            max_score_change: 100,
            is_paused: false,
        };

        move_to(admin, reputation_manager);
    }

    /// Initialize a user in the reputation system
    public entry fun initialize_user(
        credit_manager: &signer,
        manager_addr: address,
        user: address,
    ) acquires ReputationManager {
        let manager_addr_signer = signer::address_of(credit_manager);
        let rep_manager = borrow_global_mut<ReputationManager>(manager_addr);

        assert!(
            rep_manager.credit_manager == manager_addr_signer,
            error::permission_denied(E_NOT_AUTHORIZED)
        );
        assert!(!rep_manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(user != @0x0, error::invalid_argument(E_INVALID_ADDRESS));
        assert!(
            !table::contains(&rep_manager.reputations, user),
            error::already_exists(E_USER_ALREADY_INITIALIZED)
        );

        let initial_tier = calculate_tier(DEFAULT_SCORE);

        let reputation_data = ReputationData {
            score: DEFAULT_SCORE,
            last_updated: timestamp::now_seconds(),
            total_repayments: 0,
            on_time_repayments: 0,
            late_repayments: 0,
            defaults: 0,
            tier: initial_tier,
            is_initialized: true,
        };

        table::add(&mut rep_manager.reputations, user, reputation_data);
        vector::push_back(&mut rep_manager.users_list, user);

        event::emit(UserInitializedEvent {
            user,
            initial_score: DEFAULT_SCORE,
            initial_tier,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Update reputation based on payment behavior
    /// Note: This function is called by credit_manager module during repayments.
    /// The caller_signer is the borrower, but authorization is handled through the credit_manager module.
    public entry fun update_reputation(
        _caller: &signer,  // Kept for entry function compatibility
        manager_addr: address,
        borrower: address,
        is_positive: bool,
        _amount: u64,
    ) acquires ReputationManager {
        let rep_manager = borrow_global_mut<ReputationManager>(manager_addr);
        assert!(!rep_manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));

        // Initialize user if not already initialized
        if (!table::contains(&rep_manager.reputations, borrower)) {
            initialize_user_internal(rep_manager, borrower);
        };

        let reputation_data = table::borrow_mut(&mut rep_manager.reputations, borrower);
        let (score_change, reason) = if (is_positive) {
            reputation_data.on_time_repayments = reputation_data.on_time_repayments + 1;
            (rep_manager.on_time_bonus, string::utf8(b"On-time repayment"))
        } else {
            reputation_data.late_repayments = reputation_data.late_repayments + 1;
            (rep_manager.late_payment_penalty, string::utf8(b"Late payment"))
        };

        reputation_data.total_repayments = reputation_data.total_repayments + 1;
        update_reputation_internal(rep_manager, borrower, is_positive, score_change, reason);
    }

    /// Record a default/liquidation event
    public entry fun record_default(
        credit_manager: &signer,
        manager_addr: address,
        user: address,
        debt_amount: u64,
    ) acquires ReputationManager {
        let manager_addr_signer = signer::address_of(credit_manager);
        let rep_manager = borrow_global_mut<ReputationManager>(manager_addr);

        assert!(
            rep_manager.credit_manager == manager_addr_signer,
            error::permission_denied(E_NOT_AUTHORIZED)
        );
        assert!(!rep_manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(table::contains(&rep_manager.reputations, user), error::not_found(E_USER_NOT_INITIALIZED));

        let reputation_data = table::borrow_mut(&mut rep_manager.reputations, user);
        reputation_data.defaults = reputation_data.defaults + 1;

        let penalty = if (debt_amount > 10000000000) { // 10K USDC (assuming 6 decimals)
            rep_manager.default_penalty * 2
        } else {
            rep_manager.default_penalty
        };

        update_reputation_internal(
            rep_manager,
            user,
            false,
            penalty,
            string::utf8(b"Loan default/liquidation")
        );

        event::emit(DefaultRecordedEvent {
            user,
            debt_amount,
            penalty_applied: penalty,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Get reputation score for a user
    public fun get_reputation_score(manager_addr: address, user: address): u256 acquires ReputationManager {
        let rep_manager = borrow_global<ReputationManager>(manager_addr);

        if (table::contains(&rep_manager.reputations, user)) {
            let reputation_data = table::borrow(&rep_manager.reputations, user);
            reputation_data.score
        } else {
            DEFAULT_SCORE
        }
    }

    /// Get reputation tier for a user
    public fun get_tier(manager_addr: address, user: address): u8 acquires ReputationManager {
        let rep_manager = borrow_global<ReputationManager>(manager_addr);

        if (table::contains(&rep_manager.reputations, user)) {
            let reputation_data = table::borrow(&rep_manager.reputations, user);
            reputation_data.tier
        } else {
            calculate_tier(DEFAULT_SCORE)
        }
    }

    /// Get complete reputation data for a user
    public fun get_reputation_data(
        manager_addr: address,
        user: address,
    ): (u256, u64, u64, u64, u64, u64, u8, bool) acquires ReputationManager {
        let rep_manager = borrow_global<ReputationManager>(manager_addr);

        if (table::contains(&rep_manager.reputations, user)) {
            let reputation_data = table::borrow(&rep_manager.reputations, user);
            (
                reputation_data.score,
                reputation_data.last_updated,
                reputation_data.total_repayments,
                reputation_data.on_time_repayments,
                reputation_data.late_repayments,
                reputation_data.defaults,
                reputation_data.tier,
                reputation_data.is_initialized
            )
        } else {
            (DEFAULT_SCORE, 0, 0, 0, 0, 0, calculate_tier(DEFAULT_SCORE), false)
        }
    }

    /// Get all users in the system
    public fun get_all_users(manager_addr: address): vector<address> acquires ReputationManager {
        let rep_manager = borrow_global<ReputationManager>(manager_addr);
        rep_manager.users_list
    }

    /// Update reputation manager parameters (only by admin)
    public entry fun update_parameters(
        admin: &signer,
        manager_addr: address,
        on_time_bonus: u256,
        late_payment_penalty: u256,
        default_penalty: u256,
        max_score_change: u256,
    ) acquires ReputationManager {
        let admin_addr = signer::address_of(admin);
        let rep_manager = borrow_global_mut<ReputationManager>(manager_addr);

        assert!(rep_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));

        rep_manager.on_time_bonus = on_time_bonus;
        rep_manager.late_payment_penalty = late_payment_penalty;
        rep_manager.default_penalty = default_penalty;
        rep_manager.max_score_change = max_score_change;

        event::emit(ParametersUpdatedEvent {
            on_time_bonus,
            late_payment_penalty,
            default_penalty,
            max_score_change,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Pause the reputation manager
    public entry fun pause(admin: &signer, manager_addr: address) acquires ReputationManager {
        let admin_addr = signer::address_of(admin);
        let rep_manager = borrow_global_mut<ReputationManager>(manager_addr);

        assert!(rep_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        rep_manager.is_paused = true;

        event::emit(PausedEvent {
            admin: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Unpause the reputation manager
    public entry fun unpause(admin: &signer, manager_addr: address) acquires ReputationManager {
        let admin_addr = signer::address_of(admin);
        let rep_manager = borrow_global_mut<ReputationManager>(manager_addr);

        assert!(rep_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        rep_manager.is_paused = false;

        event::emit(UnpausedEvent {
            admin: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Initiate admin transfer (2-step process for security)
    public entry fun transfer_admin(
        admin: &signer,
        manager_addr: address,
        new_admin: address,
    ) acquires ReputationManager {
        let admin_addr = signer::address_of(admin);
        let rep_manager = borrow_global_mut<ReputationManager>(manager_addr);

        assert!(rep_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_admin != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        rep_manager.pending_admin = std::option::some(new_admin);

        event::emit(AdminTransferInitiatedEvent {
            current_admin: admin_addr,
            pending_admin: new_admin,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Accept admin transfer (must be called by pending admin)
    public entry fun accept_admin(
        new_admin: &signer,
        manager_addr: address,
    ) acquires ReputationManager {
        let new_admin_addr = signer::address_of(new_admin);
        let rep_manager = borrow_global_mut<ReputationManager>(manager_addr);

        assert!(std::option::is_some(&rep_manager.pending_admin), error::invalid_state(E_PENDING_ADMIN_NOT_SET));
        assert!(
            *std::option::borrow(&rep_manager.pending_admin) == new_admin_addr,
            error::permission_denied(E_NOT_PENDING_ADMIN)
        );

        let old_admin = rep_manager.admin;
        rep_manager.admin = new_admin_addr;
        rep_manager.pending_admin = std::option::none();

        event::emit(AdminTransferCompletedEvent {
            old_admin,
            new_admin: new_admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Cancel pending admin transfer
    public entry fun cancel_admin_transfer(
        admin: &signer,
        manager_addr: address,
    ) acquires ReputationManager {
        let admin_addr = signer::address_of(admin);
        let rep_manager = borrow_global_mut<ReputationManager>(manager_addr);

        assert!(rep_manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        rep_manager.pending_admin = std::option::none();
    }

    /// Internal function to initialize a user
    fun initialize_user_internal(rep_manager: &mut ReputationManager, user: address) {
        let initial_tier = calculate_tier(DEFAULT_SCORE);

        let reputation_data = ReputationData {
            score: DEFAULT_SCORE,
            last_updated: timestamp::now_seconds(),
            total_repayments: 0,
            on_time_repayments: 0,
            late_repayments: 0,
            defaults: 0,
            tier: initial_tier,
            is_initialized: true,
        };

        table::add(&mut rep_manager.reputations, user, reputation_data);
        vector::push_back(&mut rep_manager.users_list, user);

        event::emit(UserInitializedEvent {
            user,
            initial_score: DEFAULT_SCORE,
            initial_tier,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Internal function to update reputation
    fun update_reputation_internal(
        rep_manager: &mut ReputationManager,
        user: address,
        is_increase: bool,
        amount: u256,
        reason: String,
    ) {
        let reputation_data = table::borrow_mut(&mut rep_manager.reputations, user);
        let old_score = reputation_data.score;
        let old_tier = reputation_data.tier;

        // Apply score change with max limit
        let actual_change = if (amount > rep_manager.max_score_change) {
            rep_manager.max_score_change
        } else {
            amount
        };

        if (is_increase) {
            reputation_data.score = if (reputation_data.score + actual_change > MAX_SCORE) {
                MAX_SCORE
            } else {
                reputation_data.score + actual_change
            };
        } else {
            reputation_data.score = if (reputation_data.score > actual_change) {
                reputation_data.score - actual_change
            } else {
                MIN_SCORE
            };
        };

        reputation_data.last_updated = timestamp::now_seconds();
        reputation_data.tier = calculate_tier(reputation_data.score);

        event::emit(ScoreUpdatedEvent {
            user,
            old_score,
            new_score: reputation_data.score,
            is_increase,
            reason,
            timestamp: reputation_data.last_updated,
        });

        if (old_tier != reputation_data.tier) {
            event::emit(TierChangedEvent {
                user,
                old_tier,
                new_tier: reputation_data.tier,
                timestamp: reputation_data.last_updated,
            });
        };
    }

    /// Calculate reputation tier based on score
    fun calculate_tier(score: u256): u8 {
        if (score >= GOLD_THRESHOLD) {
            REPUTATION_TIER_PLATINUM
        } else if (score >= SILVER_THRESHOLD) {
            REPUTATION_TIER_GOLD
        } else if (score >= BRONZE_THRESHOLD) {
            REPUTATION_TIER_SILVER
        } else {
            REPUTATION_TIER_BRONZE
        }
    }

    /// View functions
    public fun is_paused(manager_addr: address): bool acquires ReputationManager {
        let rep_manager = borrow_global<ReputationManager>(manager_addr);
        rep_manager.is_paused
    }

    public fun get_admin(manager_addr: address): address acquires ReputationManager {
        let rep_manager = borrow_global<ReputationManager>(manager_addr);
        rep_manager.admin
    }

    public fun get_credit_manager(manager_addr: address): address acquires ReputationManager {
        let rep_manager = borrow_global<ReputationManager>(manager_addr);
        rep_manager.credit_manager
    }

    public fun get_parameters(
        manager_addr: address,
    ): (u256, u256, u256, u256) acquires ReputationManager {
        let rep_manager = borrow_global<ReputationManager>(manager_addr);
        (
            rep_manager.on_time_bonus,
            rep_manager.late_payment_penalty,
            rep_manager.default_penalty,
            rep_manager.max_score_change
        )
    }

    public fun get_tier_thresholds(): (u256, u256, u256, u256, u256) {
        (MIN_SCORE, BRONZE_THRESHOLD, SILVER_THRESHOLD, GOLD_THRESHOLD, MAX_SCORE)
    }

    /// Get user count
    public fun get_user_count(manager_addr: address): u64 acquires ReputationManager {
        let rep_manager = borrow_global<ReputationManager>(manager_addr);
        vector::length(&rep_manager.users_list)
    }

    /// Check if user is initialized
    public fun is_user_initialized(manager_addr: address, user: address): bool acquires ReputationManager {
        let rep_manager = borrow_global<ReputationManager>(manager_addr);
        table::contains(&rep_manager.reputations, user)
    }
}