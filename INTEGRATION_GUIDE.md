# DeFi Credit Protocol - Move Integration Guide

## 📋 Table of Contents
- [Overview](#overview)
- [Deployed Contracts](#deployed-contracts)
- [Module Architecture](#module-architecture)
- [Function Reference](#function-reference)
- [Integration Examples](#integration-examples)
- [Error Codes](#error-codes)
- [Event System](#event-system)
- [Best Practices](#best-practices)
- [Testing Scripts](#testing-scripts)

---

## 🎯 Overview

This guide provides complete documentation for integrating with the DeFi Credit Protocol deployed on Aptos. The protocol consists of 5 interconnected Move modules that replicate the functionality of the original Solidity contracts.

**Package Name:** `credit_protocol`

---

## 🌐 Mainnet Deployment (Production)

| Component | Address |
|-----------|---------|
| **Contract Package** | `0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172` |
| **Admin Address** | `0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78` |
| **Circle USDC Token** | `0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b` |
| **RPC Endpoint** | `https://fullnode.mainnet.aptoslabs.com` |

**Status:** ✅ Live and tested with real USDC

> **Note:** For detailed mainnet integration, see [MAINNET_INTEGRATION_GUIDE.md](./MAINNET_INTEGRATION_GUIDE.md)

---

## 🧪 Testnet Deployment (Development)

**Network:** Aptos Testnet
**Account Address:** `0x7dab2b468867d46e5a1968ffa045d1308b010e6e1eece081172c72c3f35c4f5e`

---

## 🏗️ Deployed Contracts

### All Modules Address
```
0x7dab2b468867d46e5a1968ffa045d1308b010e6e1eece081172c72c3f35c4f5e
```

### Module Names
1. `credit_protocol::interest_rate_model`
2. `credit_protocol::lending_pool`
3. `credit_protocol::collateral_vault`
4. `credit_protocol::credit_manager` (Main orchestrator)
5. `credit_protocol::reputation_manager`

---

## 🔧 Module Architecture

```
┌─────────────────┐
│  Credit Manager │ ← Main entry point for all operations
│  (Orchestrator) │
└─────┬───────────┘
      │
      ├── Lending Pool      (Liquidity management)
      ├── Collateral Vault  (Collateral handling)
      ├── Reputation Mgr    (Credit scoring)
      └── Interest Rate Mdl (Rate calculations)
```

**Flow:** All user interactions go through `Credit Manager`, which coordinates with other modules.

---

## 📚 Function Reference

### 1. Credit Manager Module

#### 🔧 Administrative Functions

**Initialize the Protocol**
```rust
public entry fun initialize(
    admin: &signer,
    lending_pool_addr: address,
    collateral_vault_addr: address,
    reputation_manager_addr: address,
    interest_rate_model_addr: address,
)
```
- **Purpose:** Initialize the credit manager with references to all other modules
- **Who can call:** Admin only
- **Example:**
```bash
aptos move run --function-id 0x7dab2b...::credit_manager::initialize \
  --args address:0x7dab2b... address:0x7dab2b... address:0x7dab2b... address:0x7dab2b...
```

**Pause/Unpause Protocol**
```rust
public entry fun pause(admin: &signer, manager_addr: address)
public entry fun unpause(admin: &signer, manager_addr: address)
```

#### 💳 Core Credit Functions

**Open Credit Line**
```rust
public entry fun open_credit_line(
    borrower: &signer,
    manager_addr: address,
    collateral_amount: u64,
)
```
- **Purpose:** Create a new credit line for a user
- **Triggers:** Collateral deposit, reputation initialization
- **Example:**
```bash
aptos move run --function-id 0x7dab2b...::credit_manager::open_credit_line \
  --args address:0x7dab2b... u64:1000000
```

**Borrow Funds**
```rust
public entry fun borrow(
    borrower: &signer,
    manager_addr: address,
    amount: u64,
)
```
- **Purpose:** Borrow against existing credit line
- **Checks:** Credit limit, collateral ratio, reputation
- **Triggers:** Interest rate calculation, lending pool withdrawal

**Repay Loan**
```rust
public entry fun repay(
    borrower: &signer,
    manager_addr: address,
    amount: u64,
)
```
- **Purpose:** Repay borrowed amount + interest
- **Triggers:** Interest calculation, reputation update

**Increase Credit Limit**
```rust
public entry fun increase_credit_limit(
    borrower: &signer,
    manager_addr: address,
    additional_collateral: u64,
)
```

**Liquidate Position**
```rust
public entry fun liquidate(
    liquidator: &signer,
    manager_addr: address,
    borrower: address,
)
```

#### 📊 View Functions

**Get Credit Line Info**
```rust
public fun get_credit_line(
    manager_addr: address,
    borrower: address,
): (u64, u64, u64, u64, u64, u64, bool) // credit_limit, borrowed, collateral, interest, last_updated, grace_end, is_active
```

**Check Liquidation Status**
```rust
public fun is_liquidatable(
    manager_addr: address,
    borrower: address,
): bool
```

### 2. Lending Pool Module

#### 💰 Lender Functions

**Deposit Liquidity**
```rust
public entry fun deposit(
    lender: &signer,
    pool_addr: address,
    amount: u64,
)
```
- **Purpose:** Deposit funds to earn interest
- **Requirements:** Sufficient APT balance
- **Example:**
```bash
aptos move run --function-id 0x7dab2b...::lending_pool::deposit \
  --args address:0x7dab2b... u64:5000000
```

**Withdraw Liquidity**
```rust
public entry fun withdraw(
    lender: &signer,
    pool_addr: address,
    amount: u64,
)
```

#### 🔄 Protocol Functions (Credit Manager Only)

**Protocol Borrow**
```rust
public entry fun borrow(
    credit_manager: &signer,
    pool_addr: address,
    borrower: address,
    amount: u64,
)
```

**Process Repayment**
```rust
public entry fun repay(
    credit_manager: &signer,
    pool_addr: address,
    borrower: address,
    principal: u64,
    interest: u64,
)
```

#### 📈 Analytics Functions

```rust
public fun get_available_liquidity(pool_addr: address): u64
public fun get_utilization_rate(pool_addr: address): u256
public fun get_lender_info(pool_addr: address, lender: address): (u64, u64, u64)
public fun get_total_deposited(pool_addr: address): u64
```

### 3. Collateral Vault Module

#### 🏦 Collateral Management

**Deposit Collateral**
```rust
public entry fun deposit_collateral(
    user: &signer,
    vault_addr: address,
    amount: u64,
)
```

**Withdraw Collateral**
```rust
public entry fun withdraw_collateral(
    user: &signer,
    vault_addr: address,
    amount: u64,
)
```

**Lock/Unlock Collateral (Credit Manager Only)**
```rust
public entry fun lock_collateral(
    credit_manager: &signer,
    vault_addr: address,
    user: address,
    amount: u64,
)

public entry fun unlock_collateral(
    credit_manager: &signer,
    vault_addr: address,
    user: address,
    amount: u64,
)
```

#### 📊 Collateral Analytics

```rust
public fun get_collateral_info(vault_addr: address, user: address): (u64, u64, u8)
public fun get_collateral_ratio(): u256 // Returns 150 (150%)
public fun get_liquidation_threshold(): u256 // Returns 120 (120%)
```

### 4. Reputation Manager Module

#### 👤 User Management

**Initialize User (Credit Manager Only)**
```rust
public entry fun initialize_user(
    credit_manager: &signer,
    manager_addr: address,
    user: address,
)
```

**Update Reputation (Credit Manager Only)**
```rust
public entry fun update_reputation(
    credit_manager: &signer,
    manager_addr: address,
    borrower: address,
    is_positive: bool,
    _amount: u64,
)
```

**Record Default**
```rust
public entry fun record_default(
    credit_manager: &signer,
    manager_addr: address,
    user: address,
    debt_amount: u64,
)
```

#### 🏅 Reputation Analytics

```rust
public fun get_reputation_score(manager_addr: address, user: address): u256
public fun get_tier(manager_addr: address, user: address): u8
public fun get_reputation_data(manager_addr: address, user: address): (u256, u64, u64, u64, u64, u64, u8, bool)
public fun get_tier_thresholds(): (u256, u256, u256, u256, u256) // Min, Bronze, Silver, Gold, Max
```

**Tier System:**
- Bronze: 0-299 points
- Silver: 300-599 points
- Gold: 600-849 points
- Platinum: 850-1000 points

### 5. Interest Rate Model Module

#### 📊 Rate Calculations

**Get Current Rate**
```rust
public fun get_current_annual_rate(
    model_addr: address,
    utilization_rate: u256,
): u256
```

**Calculate Interest**
```rust
public fun calculate_accrued_interest(
    model_addr: address,
    principal: u64,
    annual_rate: u256,
    time_elapsed: u64,
): u64
```

#### ⚙️ Configuration

```rust
public fun get_rate_parameters(model_addr: address): (u256, u256, u256, u256, u256, u8, bool)
public fun get_grace_period(model_addr: address): u64
```

---

## 🚀 Integration Examples

### Example 1: Complete Lending Flow

```typescript
// 1. User opens credit line with 10 APT collateral
await client.submitTransaction({
  function: "0x7dab2b...::credit_manager::open_credit_line",
  arguments: ["0x7dab2b...", "10000000"] // 10 APT (8 decimals)
});

// 2. User borrows 5 APT
await client.submitTransaction({
  function: "0x7dab2b...::credit_manager::borrow",
  arguments: ["0x7dab2b...", "5000000"] // 5 APT
});

// 3. Check current debt
const creditInfo = await client.view({
  function: "0x7dab2b...::credit_manager::get_credit_line",
  arguments: ["0x7dab2b...", userAddress]
});

// 4. Repay loan
await client.submitTransaction({
  function: "0x7dab2b...::credit_manager::repay",
  arguments: ["0x7dab2b...", "5100000"] // Principal + interest
});
```

### Example 2: Lender Flow

```typescript
// 1. Lender deposits 100 APT
await client.submitTransaction({
  function: "0x7dab2b...::lending_pool::deposit",
  arguments: ["0x7dab2b...", "100000000"] // 100 APT
});

// 2. Check earned interest
const lenderInfo = await client.view({
  function: "0x7dab2b...::lending_pool::get_lender_info",
  arguments: ["0x7dab2b...", lenderAddress]
});

// 3. Withdraw funds + interest
await client.submitTransaction({
  function: "0x7dab2b...::lending_pool::withdraw",
  arguments: ["0x7dab2b...", withdrawAmount]
});
```

### Example 3: Check User Reputation

```typescript
// Get user's credit score
const score = await client.view({
  function: "0x7dab2b...::reputation_manager::get_reputation_score",
  arguments: ["0x7dab2b...", userAddress]
});

// Get tier (0=Bronze, 1=Silver, 2=Gold, 3=Platinum)
const tier = await client.view({
  function: "0x7dab2b...::reputation_manager::get_tier",
  arguments: ["0x7dab2b...", userAddress]
});
```

---

## ⚠️ Error Codes

### Common Error Codes Across Modules

| Code | Constant | Description |
|------|----------|-------------|
| 1 | `E_NOT_AUTHORIZED` | Caller lacks permission |
| 2 | `E_INSUFFICIENT_BALANCE` | Insufficient funds |
| 3 | `E_INSUFFICIENT_LIQUIDITY` | Pool lacks liquidity |
| 4 | `E_INVALID_AMOUNT` | Amount is zero or invalid |
| 5 | `E_ALREADY_INITIALIZED` | Resource already exists |
| 6 | `E_NOT_INITIALIZED` | Resource doesn't exist |

### Credit Manager Specific

| Code | Constant | Description |
|------|----------|-------------|
| 7 | `E_CREDIT_LINE_EXISTS` | User already has credit line |
| 8 | `E_NO_CREDIT_LINE` | User has no credit line |
| 9 | `E_INSUFFICIENT_COLLATERAL` | Below collateral ratio |
| 10 | `E_GRACE_PERIOD_ACTIVE` | Cannot liquidate during grace |

---

## 📡 Event System

### Credit Manager Events

```rust
struct CreditOpenedEvent {
    borrower: address,
    credit_limit: u64,
    collateral_amount: u64,
    timestamp: u64,
}

struct BorrowedEvent {
    borrower: address,
    amount: u64,
    interest_rate: u256,
    timestamp: u64,
}

struct RepaidEvent {
    borrower: address,
    principal: u64,
    interest: u64,
    timestamp: u64,
}

struct LiquidatedEvent {
    borrower: address,
    liquidator: address,
    debt_amount: u64,
    collateral_seized: u64,
    timestamp: u64,
}
```

### Reputation Events

```rust
struct ScoreUpdatedEvent {
    user: address,
    old_score: u256,
    new_score: u256,
    is_increase: bool,
    reason: String,
    timestamp: u64,
}

struct TierChangedEvent {
    user: address,
    old_tier: u8,
    new_tier: u8,
    timestamp: u64,
}
```

---

## 🎯 Best Practices

### 1. Transaction Ordering
- Always open credit line before borrowing
- Repay before trying to withdraw collateral
- Check collateral ratio before additional borrowing

### 2. Error Handling
```typescript
try {
  await submitTransaction(txn);
} catch (error) {
  if (error.includes("E_INSUFFICIENT_COLLATERAL")) {
    // Handle collateral insufficient
  } else if (error.includes("E_INSUFFICIENT_LIQUIDITY")) {
    // Handle liquidity shortage
  }
}
```

### 3. Gas Management
- Batch operations when possible
- Most operations use ~500-600 gas units
- Initialize operations use ~550 gas units

### 4. Interest Calculations
- Interest accrues every second
- Grace period is 30 days by default
- Penalty rates apply after grace period

---

## 🧪 Testing Scripts

### Initialize All Modules (Admin Only)

```bash
#!/bin/bash
ACCOUNT="0x7dab2b468867d46e5a1968ffa045d1308b010e6e1eece081172c72c3f35c4f5e"

# Initialize lending pool
aptos move run --function-id $ACCOUNT::lending_pool::initialize \
  --args address:$ACCOUNT --assume-yes

# Initialize reputation manager
aptos move run --function-id $ACCOUNT::reputation_manager::initialize \
  --args address:$ACCOUNT --assume-yes

# Initialize collateral vault
aptos move run --function-id $ACCOUNT::collateral_vault::initialize \
  --args address:$ACCOUNT --assume-yes

# Initialize interest rate model
aptos move run --function-id $ACCOUNT::interest_rate_model::initialize \
  --args address:$ACCOUNT "raw:0x017dab2b468867d46e5a1968ffa045d1308b010e6e1eece081172c72c3f35c4f5e" --assume-yes

# Initialize credit manager (main orchestrator)
aptos move run --function-id $ACCOUNT::credit_manager::initialize \
  --args address:$ACCOUNT address:$ACCOUNT address:$ACCOUNT address:$ACCOUNT --assume-yes
```

### Test User Flow

```bash
#!/bin/bash
ACCOUNT="0x7dab2b468867d46e5a1968ffa045d1308b010e6e1eece081172c72c3f35c4f5e"

# Open credit line with 1 APT collateral
aptos move run --function-id $ACCOUNT::credit_manager::open_credit_line \
  --args address:$ACCOUNT u64:100000000 --assume-yes

# Borrow 0.5 APT
aptos move run --function-id $ACCOUNT::credit_manager::borrow \
  --args address:$ACCOUNT u64:50000000 --assume-yes

# Repay with some interest
aptos move run --function-id $ACCOUNT::credit_manager::repay \
  --args address:$ACCOUNT u64:51000000 --assume-yes
```

---

## 📞 Support & Integration Help

### Key Points for Frontend Integration:
1. **All user operations** go through `credit_manager`
2. **View functions** can be called directly on any module
3. **Events** provide real-time updates for UI
4. **Error codes** are consistent across modules
5. **Gas costs** are predictable and low

### Common Integration Patterns:
- **Dashboard**: Query all modules for user status
- **Lending Interface**: Use credit_manager for all actions
- **Analytics**: Use view functions for real-time data
- **Notifications**: Subscribe to events for updates

---

**🎉 The protocol is fully functional and ready for integration!**
**All functions have been tested and verified on Aptos Testnet.**