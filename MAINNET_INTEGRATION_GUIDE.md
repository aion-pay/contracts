# AION Credit Protocol — Mainnet Integration Guide v5.0

**Version:** 5.0 (Post-Security Audit)
**Date:** March 13, 2026
**Audience:** Frontend Engineers, dApp Integrators
**Network:** Aptos Mainnet
**Token Standard:** Aptos Fungible Asset (FA)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Contract Addresses & Configuration](#2-contract-addresses--configuration)
3. [Constants & Limits](#3-constants--limits)
4. [Module Reference](#4-module-reference)
   - [4.1 Lending Pool](#41-lending-pool)
   - [4.2 Credit Manager](#42-credit-manager)
   - [4.3 Reputation Manager](#43-reputation-manager)
5. [User Flows](#5-user-flows)
   - [5.1 Lender Flow](#51-lender-flow)
   - [5.2 Borrower Flow](#52-borrower-flow)
   - [5.3 Admin Flow](#53-admin-flow)
6. [View Functions Reference](#6-view-functions-reference)
7. [Events Reference](#7-events-reference)
8. [Error Codes](#8-error-codes)
9. [Integration Examples (TypeScript)](#9-integration-examples-typescript)
10. [Token Amounts & Decimals](#10-token-amounts--decimals)
11. [Security Considerations](#11-security-considerations)
12. [FAQ](#12-faq)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        FRONTEND / dApp                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   LENDERS              BORROWERS              ADMIN             │
│   ├─ deposit()         ├─ open_credit_line()  ├─ pause()        │
│   └─ withdraw()        ├─ add_collateral()    ├─ unpause()      │
│                        ├─ borrow()            ├─ liquidate()    │
│                        ├─ borrow_and_pay()    ├─ update_params()│
│                        ├─ repay()             └─ transfer_admin()│
│                        └─ withdraw_collateral()                 │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    SMART CONTRACTS (Aptos Move)                 │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              CREDIT MANAGER (Orchestrator)              │    │
│  │  • Credit line lifecycle (open/borrow/repay/liquidate)  │    │
│  │  • Interest calculation (fixed rate, per-second)        │    │
│  │  • Collateral/debt ratio enforcement                    │    │
│  │  • Calls lending_pool & reputation_manager internally   │    │
│  └────────────────┬─────────────────────┬──────────────────┘    │
│                   │                     │                       │
│  ┌────────────────▼──────┐  ┌──────────▼──────────────────┐    │
│  │    LENDING POOL       │  │   REPUTATION MANAGER        │    │
│  │  • Token custody (FA) │  │  • Score tracking (0-1000)  │    │
│  │  • Lender deposits    │  │  • Tier system (Bronze →    │    │
│  │  • Interest distrib.  │  │    Silver → Gold → Platinum)│    │
│  │  • Collateral mgmt    │  │  • Default recording        │    │
│  │  • Protocol fees      │  │  • On-time/late tracking    │    │
│  └───────────────────────┘  └─────────────────────────────┘    │
│                                                                 │
│  Token: USDC (Fungible Asset)                                   │
│  USDC Metadata: 0x69091fbab5f7d635ee7ac5098cf0c1efbe31d68fec... │
└─────────────────────────────────────────────────────────────────┘
```

**Key points:**
- All three modules are deployed at the **same address** (the deployer/admin address)
- The `credit_manager` is the entry point for ALL borrower operations
- The `lending_pool` handles token custody — lenders interact with it directly
- The `reputation_manager` is internal — only called by `credit_manager`
- All amounts are in USDC with **6 decimal places** (1 USDC = 1,000,000 units)

### What Changed in v5.0 (Post-Audit)

- **43 security issues fixed** (8 Critical, 15 High, 12 Medium, 3 Low, 5 New)
- **2 dead modules removed** (`interest_rate_model`, `collateral_vault`) — frontend should NOT reference them
- **Interest distribution rewritten** — now O(1) accumulator model (was O(n) loop)
- **Liquidation model changed** — seized collateral stays in pool (no transfer to liquidator)
- **`lending_pool::borrow()` removed** — all borrowing goes through credit_manager
- **New blocked recipients** in `borrow_and_pay` — pool, manager, and reputation addresses blocked
- **Repayment due date** — now set only on first borrow (cannot be reset by subsequent borrows)
- **New view functions** added across all modules
- **New events** — `AdminTransferCancelledEvent`, `ProtocolFeesWithdrawnEvent`, `BadDebtWrittenOffEvent`
- **Requires fresh deployment** — struct layout changes prevent upgrade of old contracts

---

## 2. Contract Addresses & Configuration

> **IMPORTANT:** Replace these with actual mainnet addresses after deployment.

```typescript
const CONFIG = {
  // All modules deployed at the same address
  MODULE_ADDRESS: "0x<DEPLOYER_ADDRESS>",

  // USDC Fungible Asset metadata address on Aptos Mainnet
  USDC_METADATA: "0x69091fbab5f7d635ee7ac5098cf0c1efbe31d68fec0f2cd565e8d168daf52832",

  // Module names
  MODULES: {
    CREDIT_MANAGER: "credit_manager",
    LENDING_POOL: "lending_pool",
    REPUTATION_MANAGER: "reputation_manager",
  },

  // The pool_addr / manager_addr / reputation_addr are all MODULE_ADDRESS
  // All resources are stored at the deployer's address
  POOL_ADDR: "0x<DEPLOYER_ADDRESS>",
  MANAGER_ADDR: "0x<DEPLOYER_ADDRESS>",
  REPUTATION_ADDR: "0x<DEPLOYER_ADDRESS>",
};
```

### Testnet Reference

```typescript
const TESTNET_CONFIG = {
  MODULE_ADDRESS: "0x5b5f60e32d998c41f20ff9b2a155a99bff4114eda8f8ed27740ae7de19f7753d",
  USDC_METADATA: "0x69091fbab5f7d635ee7ac5098cf0c1efbe31d68fec0f2cd565e8d168daf52832",
  POOL_ADDR: "0x5b5f60e32d998c41f20ff9b2a155a99bff4114eda8f8ed27740ae7de19f7753d",
  MANAGER_ADDR: "0x5b5f60e32d998c41f20ff9b2a155a99bff4114eda8f8ed27740ae7de19f7753d",
  REPUTATION_ADDR: "0x5b5f60e32d998c41f20ff9b2a155a99bff4114eda8f8ed27740ae7de19f7753d",
};
```

---

## 3. Constants & Limits

### Credit Manager

| Constant | Value | Description |
|----------|-------|-------------|
| `MIN_COLLATERAL_AMOUNT` | `1,000,000` (1 USDC) | Minimum collateral for opening/adding |
| `MIN_BORROW_AMOUNT` | `100,000` (0.1 USDC) | Minimum borrow per transaction |
| `GRACE_PERIOD` | `2,592,000` (30 days) | Grace period before overdue |
| `LIQUIDATION_THRESHOLD` | `11000` (110%) | Debt/collateral ratio for LTV liquidation |
| `DEFAULT_INTEREST_RATE` | `500` (5% annual) | Default fixed interest rate |
| `MIN_INTEREST_RATE` | `100` (1% annual) | Minimum allowed rate |
| `MAX_INTEREST_RATE` | `5000` (50% annual) | Maximum allowed rate |
| `MAX_CREDIT_MULTIPLIER` | `30000` (3x) | Max credit increase multiplier |
| Repayment due date | Grace + 30 days | Set on FIRST borrow only, never reset |

### Lending Pool

| Constant | Value | Description |
|----------|-------|-------------|
| `MIN_DEPOSIT_AMOUNT` | `1,000,000` (1 USDC) | Minimum lender deposit |
| `PROTOCOL_FEE_RATE` | `1000` (10%) | Fee on interest before distribution |
| `PRECISION` | `1e12` | Accumulator scaling factor |

### Reputation Manager

| Constant | Value | Description |
|----------|-------|-------------|
| `DEFAULT_SCORE` | `500` | Starting score |
| `MAX_SCORE` | `1000` | Maximum score |
| `SILVER_THRESHOLD` | `300` | Score >= 300 = Silver (tier 1) |
| `GOLD_THRESHOLD` | `600` | Score >= 600 = Gold (tier 2) |
| `PLATINUM_THRESHOLD` | `850` | Score >= 850 = Platinum (tier 3) |
| Default `on_time_bonus` | `20` | +20 per on-time repayment |
| Default `late_payment_penalty` | `15` | -15 per late repayment |
| Default `default_penalty` | `50` | -50 per liquidation (2x for large debts) |

### Tier Mapping

| Tier ID | Name | Score Range |
|---------|------|-------------|
| `0` | Bronze | 0 – 299 |
| `1` | Silver | 300 – 599 |
| `2` | Gold | 600 – 849 |
| `3` | Platinum | 850 – 1000 |

---

## 4. Module Reference

### 4.1 Lending Pool

**For: Lenders (deposit/withdraw funds)**

#### `deposit(lender: &signer, pool_addr: address, amount: u64)`

Deposit USDC into the lending pool to earn interest.

| Parameter | Type | Description |
|-----------|------|-------------|
| `pool_addr` | `address` | Pool address (= MODULE_ADDRESS) |
| `amount` | `u64` | USDC units (6 decimals). Min: 1,000,000 |

**Prerequisites:** Sufficient USDC, pool not paused, amount >= 1 USDC

**What happens:**
1. USDC transferred from lender to pool
2. Pending interest settled (if existing lender)
3. `initial_deposit_timestamp` preserved on subsequent deposits
4. `DepositEvent` emitted

---

#### `withdraw(lender: &signer, pool_addr: address, amount: u64)`

Withdraw USDC (principal + interest).

**Withdrawal order:** Interest deducted first, then principal.

**Example:** 100 USDC principal + 5 USDC interest:
- Withdraw 3 → all from interest (100 principal + 2 interest left)
- Withdraw 10 → 5 interest + 5 principal (95 principal + 0 interest left)

If fully withdrawn (both = 0), lender removed from system.

---

### 4.2 Credit Manager

**For: Borrowers (credit line lifecycle)**

#### `open_credit_line(borrower: &signer, manager_addr: address, collateral_amount: u64)`

Open a new credit line by depositing collateral. Credit limit = collateral amount (1:1).

| Parameter | Type | Description |
|-----------|------|-------------|
| `manager_addr` | `address` | Manager address (= MODULE_ADDRESS) |
| `collateral_amount` | `u64` | Min: 1,000,000 (1 USDC) |

---

#### `add_collateral(borrower: &signer, manager_addr: address, collateral_amount: u64)`

Add more collateral. Can reactivate a closed/liquidated credit line. Min: 1 USDC.

---

#### `borrow(borrower: &signer, manager_addr: address, amount: u64)`

Borrow USDC to borrower's wallet. Min: 0.1 USDC. Must not exceed credit limit.

**Due date:** Set on first borrow only (grace period + 30 days). Subsequent borrows do NOT reset it.

---

#### `borrow_and_pay(borrower: &signer, manager_addr: address, recipient: address, amount: u64)`

Borrow and send to third party.

**Blocked recipients:** borrower self, `0x0`, pool addr, manager addr, reputation addr.

---

#### `repay(borrower: &signer, manager_addr: address, principal_amount: u64, interest_amount: u64)`

Repay principal and/or interest. At least one must be > 0.

**Important:** Interest accrues per-second. Call `get_credit_info()` to get current values and add a small buffer.

---

#### `withdraw_collateral(borrower: &signer, manager_addr: address, amount: u64)`

Withdraw collateral. **Requires zero outstanding debt** (both principal and interest = 0).

---

#### `liquidate(admin: &signer, manager_addr: address, borrower: address)`

**Admin only.** Liquidate when over-LTV (>110%) or overdue. Collateral seized (stays in pool), debt zeroed, default recorded.

---

### 4.3 Reputation Manager

Internal module — no direct user entry functions. Use view functions only.

---

## 5. User Flows

### 5.1 Lender Flow

```
1. DEPOSIT     → lending_pool::deposit(pool_addr, amount)
2. CHECK       → lending_pool::get_lender_info(pool_addr, lender)
                  Returns: (deposited, earned_interest, initial_timestamp)
3. WITHDRAW    → lending_pool::withdraw(pool_addr, amount)
                  Interest first, then principal
```

### 5.2 Borrower Flow

```
1. OPEN        → credit_manager::open_credit_line(manager_addr, collateral)
2. BORROW      → credit_manager::borrow(manager_addr, amount)
                  OR borrow_and_pay(manager_addr, recipient, amount)
3. CHECK       → credit_manager::get_credit_info(manager_addr, borrower)
4. REPAY       → credit_manager::repay(manager_addr, principal, interest)
5. ADD COLL    → credit_manager::add_collateral(manager_addr, amount)  [optional]
6. WITHDRAW    → credit_manager::withdraw_collateral(manager_addr, amount)
                  [only when debt = 0]
```

### 5.3 Admin Flow

```
PROTOCOL:     pause/unpause on all 3 modules
PARAMS:       credit_manager::update_parameters(addr, rate, threshold, multiplier)
              reputation_manager::update_parameters(addr, bonus, penalty, default, max)
FEES:         lending_pool::withdraw_protocol_fees(pool_addr, to, amount)
LIQUIDATION:  credit_manager::liquidate(manager_addr, borrower)
ADMIN:        transfer_admin → accept_admin (2-step, all 3 modules)
```

---

## 6. View Functions Reference

### Credit Manager

| Function | Returns | Description |
|----------|---------|-------------|
| `get_credit_info(mgr, borrower)` | `(u64, u64, u64, u64, u64, u64, bool)` | `(collateral, credit_limit, borrowed, interest, total_repaid, due_date, is_active)` |
| `get_collateral_details(mgr, borrower)` | `(u64, u64, u64)` | `(initial_collateral, current_collateral, earned_interest)` |
| `get_repayment_history(mgr, borrower)` | `(u64, u64, u64)` | `(total_repaid, on_time, late)` |
| `get_credit_line_status(mgr, borrower)` | `(bool, bool, bool)` | `(is_active, is_overdue, is_over_ltv)` |
| `check_credit_increase_eligibility(mgr, borrower)` | `(bool, u64, u64)` | `(eligible, current_limit, new_limit)` |
| `get_all_borrowers(mgr)` | `vector<address>` | All borrowers |
| `get_admin(mgr)` | `address` | Current admin |
| `get_fixed_interest_rate(mgr)` | `u256` | Rate in basis points |
| `get_token_metadata(mgr)` | `Object<Metadata>` | Token metadata |
| `is_paused(mgr)` | `bool` | Pause status |

### Lending Pool

| Function | Returns | Description |
|----------|---------|-------------|
| `get_lender_info(pool, lender)` | `(u64, u64, u64)` | `(deposited, earned_interest, initial_timestamp)` |
| `get_available_liquidity(pool)` | `u64` | Available for borrowing |
| `get_utilization_rate(pool)` | `u256` | In basis points (5000 = 50%) |
| `get_collateral_with_interest(pool, borrower)` | `(u64, u64, u64)` | `(principal, interest, total)` |
| `has_collateral(pool, borrower)` | `bool` | Has collateral |
| `get_total_deposited(pool)` | `u64` | Total lender deposits |
| `get_total_collateral(pool)` | `u64` | Total collateral |
| `get_total_borrowed(pool)` | `u64` | Cumulative borrowed |
| `get_total_repaid(pool)` | `u64` | Cumulative repaid (includes write-offs) |
| `get_protocol_fees_collected(pool)` | `u64` | Uncollected fees |
| `get_all_lenders(pool)` | `vector<address>` | All lenders |
| `get_all_collateral_depositors(pool)` | `vector<address>` | All collateral depositors |
| `get_admin(pool)` | `address` | Current admin |
| `is_paused(pool)` | `bool` | Pause status |

### Reputation Manager

| Function | Returns | Description |
|----------|---------|-------------|
| `get_reputation_score(mgr, user)` | `u256` | Score (0-1000) |
| `get_tier(mgr, user)` | `u8` | 0=Bronze, 1=Silver, 2=Gold, 3=Platinum |
| `get_reputation_data(mgr, user)` | `(u256, u64, u64, u64, u64, u64, u8, bool)` | `(score, last_updated, total, on_time, late, defaults, tier, initialized)` |
| `get_all_users(mgr)` | `vector<address>` | All users |
| `get_parameters(mgr)` | `(u256, u256, u256, u256)` | `(bonus, late_pen, default_pen, max_change)` |
| `get_tier_thresholds()` | `(u256, u256, u256, u256, u256)` | `(min, silver, gold, platinum, max)` |
| `get_user_count(mgr)` | `u64` | Total users |
| `is_user_initialized(mgr, user)` | `bool` | Has reputation data |
| `is_paused(mgr)` | `bool` | Pause status |

---

## 7. Events Reference

### Credit Manager Events

| Event | Key Fields | Trigger |
|-------|-----------|---------|
| `CreditOpenedEvent` | `borrower, collateral_amount, credit_limit` | Credit line opened |
| `CollateralAddedEvent` | `borrower, amount, new_total, new_credit_limit` | Collateral added |
| `BorrowedEvent` | `borrower, amount, total_debt` | Borrow to self |
| `DirectPaymentEvent` | `borrower, recipient, amount, total_debt` | Borrow to third party |
| `RepaidEvent` | `borrower, principal, interest, remaining_debt` | Repayment |
| `LiquidationEvent` | `borrower, collateral_seized, debt_written_off` | Liquidation |
| `CollateralWithdrawnEvent` | `borrower, amount, interest_earned, remaining` | Collateral withdrawn |
| `ParametersUpdatedEvent` | `fixed_interest_rate, reputation_threshold, credit_increase_multiplier` | Params changed |
| `PausedEvent` / `UnpausedEvent` | `admin` | Pause toggle |
| `AdminTransferInitiatedEvent` | `current_admin, pending_admin` | Transfer started |
| `AdminTransferCompletedEvent` | `old_admin, new_admin` | Transfer accepted |
| `AdminTransferCancelledEvent` | `admin, cancelled_pending_admin` | Transfer cancelled |

### Lending Pool Events

| Event | Key Fields | Trigger |
|-------|-----------|---------|
| `DepositEvent` | `lender, amount` | Lender deposit |
| `WithdrawEvent` | `lender, amount, interest` | Lender withdrawal |
| `CollateralDepositedEvent` | `borrower, amount, total_collateral` | Collateral in |
| `CollateralWithdrawnEvent` | `borrower, amount, interest_earned, remaining` | Collateral out |
| `CollateralSeizedEvent` | `borrower, amount_seized, interest_seized, remaining` | Liquidation |
| `BorrowEvent` | `borrower, recipient, amount` | Funds borrowed |
| `RepayEvent` | `borrower, principal, interest` | Repayment received |
| `BadDebtWrittenOffEvent` | `borrower, amount` | Bad debt written off |
| `ProtocolFeesWithdrawnEvent` | `admin, to, amount, remaining_fees` | Fees extracted |
| Plus admin events | Same pattern | Pause/admin transfer |

### Reputation Manager Events

| Event | Key Fields | Trigger |
|-------|-----------|---------|
| `UserInitializedEvent` | `user, initial_score, initial_tier` | User enters system |
| `ScoreUpdatedEvent` | `user, old_score, new_score, is_increase, reason` | Score change |
| `TierChangedEvent` | `user, old_tier, new_tier` | Tier crossing |
| `DefaultRecordedEvent` | `user, debt_amount, penalty_applied` | Default recorded |
| Plus admin events | Same pattern | Pause/params/admin transfer |

---

## 8. Error Codes

### Credit Manager

| Error Code | Name | Meaning |
|-----------|------|---------|
| `0x50001` | `E_NOT_AUTHORIZED` | Not admin |
| `0x30001` | `E_NOT_AUTHORIZED` | Protocol paused |
| `0x10002` | `E_INVALID_AMOUNT` | Zero/invalid amount |
| `0x80003` | `E_CREDIT_LINE_EXISTS` | Already has credit line |
| `0x30004` | `E_CREDIT_LINE_NOT_ACTIVE` | No active credit line |
| `0x30005` | `E_EXCEEDS_CREDIT_LIMIT` | Over credit limit |
| `0x30006` | `E_INSUFFICIENT_LIQUIDITY` | Pool empty |
| `0x10007` | `E_EXCEEDS_BORROWED_AMOUNT` | Repaying more than owed |
| `0x10008` | `E_EXCEEDS_INTEREST` | Repaying more interest than accrued |
| `0x30009` | `E_LIQUIDATION_NOT_ALLOWED` | Not over-LTV or overdue |
| `0x8000a` | `E_ALREADY_INITIALIZED` | Already initialized |
| `0x1000b` | `E_INVALID_ADDRESS` | Blocked/invalid recipient |
| `0x1000e` | `E_BELOW_MINIMUM_AMOUNT` | Below minimum |
| `0x30010` | `E_HAS_OUTSTANDING_DEBT` | Has debt (can't withdraw collateral) |
| `0x10011` | `E_INVALID_PARAMETERS` | Bad parameter values |

### Lending Pool

| Error Code | Name | Meaning |
|-----------|------|---------|
| `0x50001` | `E_NOT_AUTHORIZED` | Not admin |
| `0x30001` | `E_NOT_AUTHORIZED` | Pool paused |
| `0x10002` | `E_INSUFFICIENT_BALANCE` | Not enough balance |
| `0x30003` | `E_INSUFFICIENT_LIQUIDITY` | Pool illiquid |
| `0x10004` | `E_INVALID_AMOUNT` | Zero amount |
| `0x1000a` | `E_BELOW_MINIMUM_AMOUNT` | Below 1 USDC |
| `0x6000b` | `E_COLLATERAL_NOT_FOUND` | No collateral |

---

## 9. Integration Examples (TypeScript)

### Setup

```typescript
import { Aptos, AptosConfig, Network, Account } from "@aptos-labs/ts-sdk";

const config = new AptosConfig({ network: Network.MAINNET });
const aptos = new Aptos(config);

const MODULE = "0x<DEPLOYER_ADDRESS>";
const USDC_DECIMALS = 6;

const toUSDC = (n: number) => Math.floor(n * 10 ** USDC_DECIMALS);
const fromUSDC = (n: number) => n / 10 ** USDC_DECIMALS;
```

### Lender: Deposit

```typescript
async function deposit(lender: Account, amountUSDC: number) {
  const tx = await aptos.transaction.build.simple({
    sender: lender.accountAddress,
    data: {
      function: `${MODULE}::lending_pool::deposit`,
      functionArguments: [MODULE, toUSDC(amountUSDC)],
    },
  });
  const signed = await aptos.transaction.sign({ signer: lender, transaction: tx });
  const result = await aptos.transaction.submit.simple({ transaction: tx, senderAuthenticator: signed });
  return aptos.waitForTransaction({ transactionHash: result.hash });
}
```

### Lender: Withdraw

```typescript
async function withdraw(lender: Account, amountUSDC: number) {
  const tx = await aptos.transaction.build.simple({
    sender: lender.accountAddress,
    data: {
      function: `${MODULE}::lending_pool::withdraw`,
      functionArguments: [MODULE, toUSDC(amountUSDC)],
    },
  });
  const signed = await aptos.transaction.sign({ signer: lender, transaction: tx });
  const result = await aptos.transaction.submit.simple({ transaction: tx, senderAuthenticator: signed });
  return aptos.waitForTransaction({ transactionHash: result.hash });
}
```

### Lender: Check Earnings

```typescript
async function getLenderInfo(lenderAddr: string) {
  const [deposited, interest, timestamp] = await aptos.view({
    payload: {
      function: `${MODULE}::lending_pool::get_lender_info`,
      functionArguments: [MODULE, lenderAddr],
    },
  });
  return {
    deposited: fromUSDC(Number(deposited)),
    earnedInterest: fromUSDC(Number(interest)),
    firstDepositDate: new Date(Number(timestamp) * 1000),
  };
}
```

### Borrower: Open Credit Line

```typescript
async function openCreditLine(borrower: Account, collateralUSDC: number) {
  const tx = await aptos.transaction.build.simple({
    sender: borrower.accountAddress,
    data: {
      function: `${MODULE}::credit_manager::open_credit_line`,
      functionArguments: [MODULE, toUSDC(collateralUSDC)],
    },
  });
  const signed = await aptos.transaction.sign({ signer: borrower, transaction: tx });
  const result = await aptos.transaction.submit.simple({ transaction: tx, senderAuthenticator: signed });
  return aptos.waitForTransaction({ transactionHash: result.hash });
}
```

### Borrower: Borrow

```typescript
async function borrow(borrower: Account, amountUSDC: number) {
  const tx = await aptos.transaction.build.simple({
    sender: borrower.accountAddress,
    data: {
      function: `${MODULE}::credit_manager::borrow`,
      functionArguments: [MODULE, toUSDC(amountUSDC)],
    },
  });
  const signed = await aptos.transaction.sign({ signer: borrower, transaction: tx });
  const result = await aptos.transaction.submit.simple({ transaction: tx, senderAuthenticator: signed });
  return aptos.waitForTransaction({ transactionHash: result.hash });
}
```

### Borrower: Borrow and Pay Third Party

```typescript
async function borrowAndPay(borrower: Account, recipient: string, amountUSDC: number) {
  const tx = await aptos.transaction.build.simple({
    sender: borrower.accountAddress,
    data: {
      function: `${MODULE}::credit_manager::borrow_and_pay`,
      functionArguments: [MODULE, recipient, toUSDC(amountUSDC)],
    },
  });
  const signed = await aptos.transaction.sign({ signer: borrower, transaction: tx });
  const result = await aptos.transaction.submit.simple({ transaction: tx, senderAuthenticator: signed });
  return aptos.waitForTransaction({ transactionHash: result.hash });
}
```

### Borrower: Repay

```typescript
async function repay(borrower: Account, principalUSDC: number, interestUSDC: number) {
  const tx = await aptos.transaction.build.simple({
    sender: borrower.accountAddress,
    data: {
      function: `${MODULE}::credit_manager::repay`,
      functionArguments: [MODULE, toUSDC(principalUSDC), toUSDC(interestUSDC)],
    },
  });
  const signed = await aptos.transaction.sign({ signer: borrower, transaction: tx });
  const result = await aptos.transaction.submit.simple({ transaction: tx, senderAuthenticator: signed });
  return aptos.waitForTransaction({ transactionHash: result.hash });
}
```

### Borrower: Get Credit Status

```typescript
async function getCreditInfo(borrowerAddr: string) {
  const result = await aptos.view({
    payload: {
      function: `${MODULE}::credit_manager::get_credit_info`,
      functionArguments: [MODULE, borrowerAddr],
    },
  });

  return {
    collateral: fromUSDC(Number(result[0])),
    creditLimit: fromUSDC(Number(result[1])),
    borrowedAmount: fromUSDC(Number(result[2])),
    interestAccrued: fromUSDC(Number(result[3])),
    totalRepaid: fromUSDC(Number(result[4])),
    repaymentDueDate: new Date(Number(result[5]) * 1000),
    isActive: Boolean(result[6]),
  };
}
```

### Borrower: Check Liquidation Risk

```typescript
async function getCreditLineStatus(borrowerAddr: string) {
  const result = await aptos.view({
    payload: {
      function: `${MODULE}::credit_manager::get_credit_line_status`,
      functionArguments: [MODULE, borrowerAddr],
    },
  });

  return {
    isActive: Boolean(result[0]),
    isOverdue: Boolean(result[1]),
    isOverLTV: Boolean(result[2]),
    atRisk: Boolean(result[1]) || Boolean(result[2]),
  };
}
```

### Get Reputation

```typescript
async function getReputation(userAddr: string) {
  const tierNames = ["Bronze", "Silver", "Gold", "Platinum"];

  const result = await aptos.view({
    payload: {
      function: `${MODULE}::reputation_manager::get_reputation_data`,
      functionArguments: [MODULE, userAddr],
    },
  });

  return {
    score: Number(result[0]),
    lastUpdated: new Date(Number(result[1]) * 1000),
    totalRepayments: Number(result[2]),
    onTimeRepayments: Number(result[3]),
    lateRepayments: Number(result[4]),
    defaults: Number(result[5]),
    tier: Number(result[6]),
    tierName: tierNames[Number(result[6])],
    isInitialized: Boolean(result[7]),
  };
}
```

### Dashboard: Pool Statistics

```typescript
async function getPoolStats() {
  const view = (fn: string) =>
    aptos.view({ payload: { function: `${MODULE}::lending_pool::${fn}`, functionArguments: [MODULE] } });

  const [liq, dep, coll, borr, rep, fees, util, paused] = await Promise.all([
    view("get_available_liquidity"),
    view("get_total_deposited"),
    view("get_total_collateral"),
    view("get_total_borrowed"),
    view("get_total_repaid"),
    view("get_protocol_fees_collected"),
    view("get_utilization_rate"),
    view("is_paused"),
  ]);

  return {
    availableLiquidity: fromUSDC(Number(liq[0])),
    totalDeposited: fromUSDC(Number(dep[0])),
    totalCollateral: fromUSDC(Number(coll[0])),
    totalBorrowed: fromUSDC(Number(borr[0])),
    totalRepaid: fromUSDC(Number(rep[0])),
    outstandingLoans: fromUSDC(Number(borr[0]) - Number(rep[0])),
    protocolFees: fromUSDC(Number(fees[0])),
    utilizationRate: Number(util[0]) / 100, // basis points → percentage
    isPaused: Boolean(paused[0]),
  };
}
```

---

## 10. Token Amounts & Decimals

**USDC = 6 decimals on Aptos**

| Human | On-Chain | Note |
|-------|---------|------|
| 0.1 USDC | `100000` | MIN_BORROW_AMOUNT |
| 1 USDC | `1000000` | MIN_DEPOSIT / MIN_COLLATERAL |
| 10 USDC | `10000000` | |
| 100 USDC | `100000000` | |
| 1,000 USDC | `1000000000` | |

**Always use integer math:**
```typescript
// CORRECT
const amount = Math.floor(userInput * 1_000_000);

// WRONG
const amount = userInput * 1_000_000; // floating point issues
```

### Interest Rate Display

Stored in basis points (1 bp = 0.01%):
```typescript
const formatRate = (bp: number) => `${(bp / 100).toFixed(2)}%`;
// 500 → "5.00%"
```

---

## 11. Security Considerations

### For Frontend Developers

1. **No Token Approval Needed.** Aptos FA uses `&signer` — each transaction authorizes its own transfers.

2. **Interest is Slightly Stale.** View functions return accrued interest at the last update. Add a 1-2 second buffer when displaying repayment amounts.

3. **Simulate First.** Use `aptos.transaction.simulate.simple()` before submitting to catch errors client-side.

4. **Check Pause State.** Call `is_paused()` before showing action buttons. Paused contracts reject all user transactions.

5. **Due Date is Final.** Set on first borrow, never changes. Display as countdown.

6. **Blocked Recipients.** `borrow_and_pay` blocks: self, 0x0, pool address, manager address, reputation address. Validate client-side before submitting.

### For Administrators

1. **Use Multisig.** Compromised admin = full protocol control. Use 2-of-3 or 3-of-5.

2. **Monitor Events:** `LiquidationEvent`, `ProtocolFeesWithdrawnEvent`, `AdminTransferInitiatedEvent`, `PausedEvent`

3. **Parameter Bounds:** Rate 1-50%, reputation params 1-1000, multiplier 1x-3x.

---

## 12. FAQ

**Q: Do users need to approve USDC first?**
A: No. Aptos FA uses `&signer` in each transaction.

**Q: What happens when a borrower doesn't repay?**
A: After the due date, admin can `liquidate()`. Collateral seized (stays in pool), debt zeroed, default recorded.

**Q: How is interest calculated?**
A: Fixed annual rate, per-second: `interest = rate * borrowed * elapsed / (10000 * 31536000)`

**Q: Can a liquidated borrower borrow again?**
A: Yes, by adding new collateral via `add_collateral()`. Their default is recorded in reputation.

**Q: How does interest distribution work for lenders?**
A: Accumulator model. On repayment: 10% fee, 90% distributed pro-rata. Calculated lazily per user.

**Q: Difference between `borrow()` and `borrow_and_pay()`?**
A: `borrow()` → funds to borrower. `borrow_and_pay()` → funds to specified recipient. Same debt.

**Q: How to calculate outstanding loans?**
A: `outstanding = total_borrowed - total_repaid` (includes bad debt write-offs).

**Q: What modules were removed in v5.0?**
A: `interest_rate_model` and `collateral_vault` — both were dead code. Do NOT reference them.

---

*Document prepared by the AION Engineering Team*
*For questions, contact the development team*
