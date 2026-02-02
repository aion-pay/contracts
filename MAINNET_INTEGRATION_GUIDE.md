# AION Credit Protocol - Mainnet Integration Guide v4.0

## Overview

**Status:** **LIVE ON APTOS MAINNET**
**Network:** Aptos Mainnet
**Token:** Circle USDC (Native Fungible Asset)
**Last Updated:** February 2026
**Contract Version:** v2.0.0 (Collateral-Earns-Interest Update)
**Testing Status:** All functions verified with real USDC

This guide provides complete documentation for integrating with the AION Credit Protocol deployed on Aptos Mainnet. The protocol enables decentralized credit lines backed by USDC collateral that **earns interest**.

---

## Latest Update (February 2026) - v4.0

### Major Feature: Collateral Earns Interest

**What's New:** Borrower collateral is now deposited into the lending pool where it earns interest alongside lender deposits. This means your credit limit **grows automatically** as your collateral earns interest!

**Key Changes:**
- Collateral is stored in the Lending Pool (not separately)
- Credit limits are now **dynamic** - they grow as collateral earns interest
- New view functions for collateral details
- Interest is distributed proportionally to all depositors (lenders + collateral)

**New Functions:**
- `lending_pool::get_collateral_with_interest(pool_addr, borrower)` - Get collateral principal, earned interest, and total
- `lending_pool::has_collateral(pool_addr, borrower)` - Check if borrower has collateral
- `lending_pool::get_total_collateral(pool_addr)` - Total collateral in pool
- `lending_pool::get_all_collateral_depositors(pool_addr)` - List all collateral depositors
- `credit_manager::get_collateral_details(manager_addr, borrower)` - Get collateral breakdown

**Benefits:**
- Borrowers earn passive income on collateral
- Dynamic credit limits that grow over time
- More capital efficient for the protocol

---

## Mainnet Deployment Addresses

| Component | Address |
|-----------|---------|
| **Contract Package** | `0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78` |
| **Admin/Pool Address** | `0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78` |
| **Circle USDC Token** | `0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b` |

### RPC Endpoints
```
Mainnet: https://fullnode.mainnet.aptoslabs.com
GraphQL: https://api.mainnet.aptoslabs.com/v1/graphql
Explorer: https://explorer.aptoslabs.com/?network=mainnet
```

### Module Names
```
credit_protocol::lending_pool          - Liquidity & collateral management
credit_protocol::credit_manager        - Core credit operations
credit_protocol::collateral_vault      - Legacy collateral handling
credit_protocol::reputation_manager    - Credit scoring
credit_protocol::interest_rate_model   - Rate calculations
```

---

## Architecture

```
+-----------------------------------------------------------------------+
|                     AION Credit Protocol v2.0 (Mainnet)               |
+-----------------------------------------------------------------------+
|                                                                       |
|  +------------------+     +------------------+     +----------------+ |
|  |   Lending Pool   |<----|  Credit Manager  |---->| Interest Rate  | |
|  |  +-----------+   |     |      (Core)      |     |     Model      | |
|  |  | Lender    |   |     +--------+---------+     +----------------+ |
|  |  | Deposits  |   |              |                                  |
|  |  +-----------+   |              v                                  |
|  |  | Collateral|   |     +------------------+     +----------------+ |
|  |  | Deposits  |   |     |    Reputation    |     |  Circle USDC   | |
|  |  +-----------+   |     |     Manager      |     | (Fungible Asset)| |
|  +------------------+     +------------------+     +----------------+ |
|                                                                       |
|  * Collateral now stored in Lending Pool and earns interest!         |
+-----------------------------------------------------------------------+
```

### Data Flow (Updated)
1. **Lenders** deposit USDC -> Lending Pool
2. **Borrowers** deposit collateral -> Lending Pool (earns interest!)
3. **Credit line opens** -> Dynamic credit limit = collateral + earned interest
4. **Borrowing** -> Funds from Lending Pool
5. **Repayment** -> Interest distributed to ALL depositors (lenders + collateral)
6. **Collateral grows** -> Credit limit automatically increases
7. **Withdraw collateral** -> Get principal + earned interest

---

## Quick Start

### Prerequisites
- Aptos wallet with USDC balance
- APT for gas fees (~0.001 APT per transaction)
- Aptos CLI or TypeScript SDK

### Minimum Amounts
| Operation | Minimum |
|-----------|---------|
| Deposit to Pool | 1 USDC |
| Open Credit Line | 1 USDC collateral |
| Borrow | 0.1 USDC |

---

## Module Reference

### 1. Lending Pool

Manages lender deposits, collateral deposits, and provides liquidity for borrowers.

#### Entry Functions

##### `deposit`
Deposit USDC to earn interest from borrower repayments.

```move
public entry fun deposit(
    lender: &signer,
    pool_addr: address,     // Admin address
    amount: u64,            // Amount in USDC (6 decimals)
)
```

**CLI Example:**
```bash
aptos move run \
  --function-id 0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78::lending_pool::deposit \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 u64:1000000 \
  --profile your_profile
```

##### `withdraw`
Withdraw deposited USDC plus earned interest.

```move
public entry fun withdraw(
    lender: &signer,
    pool_addr: address,
    amount: u64,
)
```

#### View Functions

```move
#[view]
public fun get_available_liquidity(pool_addr: address): u64

#[view]
public fun get_utilization_rate(pool_addr: address): u256

#[view]
public fun get_lender_info(pool_addr: address, lender: address): (u64, u64, u64)
// Returns: (deposited_amount, earned_interest, deposit_timestamp)

#[view]
public fun get_all_lenders(pool_addr: address): vector<address>

#[view]
public fun get_total_deposited(pool_addr: address): u64

#[view]
public fun get_total_borrowed(pool_addr: address): u64

#[view]
public fun is_paused(pool_addr: address): bool

// NEW: Collateral-related view functions
#[view]
public fun get_collateral_with_interest(pool_addr: address, borrower: address): (u64, u64, u64)
// Returns: (principal, earned_interest, total)

#[view]
public fun has_collateral(pool_addr: address, borrower: address): bool

#[view]
public fun get_total_collateral(pool_addr: address): u64

#[view]
public fun get_all_collateral_depositors(pool_addr: address): vector<address>
```

---

### 2. Credit Manager

Core module for credit lines, borrowing, and repayment. **Collateral now earns interest!**

#### Entry Functions

##### `open_credit_line`
Open a new credit line by depositing USDC collateral. Collateral is deposited into the lending pool where it earns interest.

```move
public entry fun open_credit_line(
    borrower: &signer,
    manager_addr: address,     // Admin address
    collateral_amount: u64,    // USDC amount (min: 1 USDC = 1000000)
)
```

**Credit Limit:** Dynamic! Equals your collateral + earned interest.

##### `add_collateral`
Add more collateral to increase credit limit. **Also reactivates inactive credit lines.**

```move
public entry fun add_collateral(
    borrower: &signer,
    manager_addr: address,
    collateral_amount: u64,
)
```

##### `borrow`
Borrow USDC against your credit line. Credit limit is dynamic based on collateral + earned interest.

```move
public entry fun borrow(
    borrower: &signer,
    manager_addr: address,
    amount: u64,               // Min: 0.1 USDC = 100000
)
```

##### `borrow_and_pay`
Borrow and send directly to a recipient (for payments).

```move
public entry fun borrow_and_pay(
    borrower: &signer,
    manager_addr: address,
    recipient: address,        // Payment recipient
    amount: u64,
)
```

##### `repay`
Repay borrowed principal and/or interest.

```move
public entry fun repay(
    borrower: &signer,
    manager_addr: address,
    principal_amount: u64,     // Principal to repay
    interest_amount: u64,      // Interest to repay
)
```

##### `withdraw_collateral`
Withdraw collateral plus earned interest (only when no outstanding debt).

```move
public entry fun withdraw_collateral(
    borrower: &signer,
    manager_addr: address,
    amount: u64,
)
```

**Note:** When withdrawing all collateral, you receive your principal + any earned interest!

#### View Functions

```move
#[view]
public fun get_credit_info(
    manager_addr: address,
    borrower: address,
): (u64, u64, u64, u64, u64, u64, bool)
// Returns: (initial_collateral, credit_limit, borrowed, interest, total_repaid, due_date, is_active)
// Note: credit_limit is now DYNAMIC (collateral + earned interest)

#[view]
public fun get_collateral_details(
    manager_addr: address,
    borrower: address,
): (u64, u64, u64)
// Returns: (principal, earned_interest, total_collateral)
// NEW: See exactly how much interest your collateral has earned!

#[view]
public fun get_repayment_history(
    manager_addr: address,
    borrower: address,
): (u64, u64, u64)
// Returns: (on_time_repayments, late_repayments, total_repaid)

#[view]
public fun check_credit_increase_eligibility(
    manager_addr: address,
    borrower: address,
): (bool, u64)
// Returns: (eligible, new_limit)

#[view]
public fun get_all_borrowers(manager_addr: address): vector<address>

#[view]
public fun get_fixed_interest_rate(manager_addr: address): u256

#[view]
public fun is_paused(manager_addr: address): bool

#[view]
public fun has_credit_line(manager_addr: address, borrower: address): bool
// Returns true if credit line exists (regardless of active status)

#[view]
public fun get_credit_line_status(
    manager_addr: address,
    borrower: address,
): (bool, bool, u64, u64, u64)
// Returns: (exists, is_active, collateral_deposited, credit_limit, borrowed_amount)
```

#### Frontend Integration Pattern

```typescript
// Check collateral with earned interest
const [principal, earnedInterest, totalCollateral] = await aptos.view({
  payload: {
    function: `${CONTRACT}::lending_pool::get_collateral_with_interest`,
    functionArguments: [ADMIN, userAddress],
  },
});

console.log(`Principal: ${principal / 1e6} USDC`);
console.log(`Earned Interest: ${earnedInterest / 1e6} USDC`);
console.log(`Total (Credit Limit): ${totalCollateral / 1e6} USDC`);

// Check if user has credit line
const [hasCreditLine] = await aptos.view({
  payload: {
    function: `${CONTRACT}::credit_manager::has_credit_line`,
    functionArguments: [ADMIN, userAddress],
  },
});

if (hasCreditLine) {
  // Credit line exists -> use add_collateral (works even if inactive)
  await addCollateral(amount);
} else {
  // No credit line -> use open_credit_line
  await openCreditLine(amount);
}
```

---

### 3. Reputation Manager

Tracks borrower reputation based on repayment behavior.

#### View Functions

```move
#[view]
public fun get_reputation_score(manager_addr: address, user: address): u256
// Score range: 0-1000

#[view]
public fun get_user_stats(
    manager_addr: address,
    user: address,
): (u64, u64, u64, u64, u256)
// Returns: (on_time_payments, late_payments, total_repaid, last_activity, score)

#[view]
public fun get_all_users(manager_addr: address): vector<address>
```

**Score Thresholds:**
| Score Range | Rating |
|-------------|--------|
| 0-300 | Poor |
| 300-500 | Fair |
| 500-750 | Good |
| 750-1000 | Excellent (Credit increase eligible) |

---

### 4. Interest Rate Model

Calculates interest rates based on utilization.

#### View Functions

```move
#[view]
public fun calculate_interest_rate(
    model_addr: address,
    utilization_rate: u256,
): u256

#[view]
public fun get_model_parameters(
    model_addr: address,
): (u256, u256, u256, u256)
// Returns: (base_rate, slope1, slope2, optimal_utilization)
```

---

## TypeScript SDK

### Installation

```bash
npm install @aptos-labs/ts-sdk
```

### Complete SDK Implementation

```typescript
import {
  Aptos,
  AptosConfig,
  Network,
  Account,
  Ed25519PrivateKey,
} from "@aptos-labs/ts-sdk";

// ============ CONFIGURATION ============

const CONTRACT = "0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78";
const ADMIN = "0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78";
const USDC_DECIMALS = 6;

// ============ SDK CLASS ============

export class AIONProtocol {
  private aptos: Aptos;
  private account: Account;

  constructor(privateKey: string, network: Network = Network.MAINNET) {
    const config = new AptosConfig({ network });
    this.aptos = new Aptos(config);
    this.account = Account.fromPrivateKey({
      privateKey: new Ed25519PrivateKey(privateKey),
    });
  }

  // ============ UTILITY METHODS ============

  private toRawAmount(usdc: number): number {
    return Math.floor(usdc * Math.pow(10, USDC_DECIMALS));
  }

  private fromRawAmount(raw: number): number {
    return raw / Math.pow(10, USDC_DECIMALS);
  }

  getAddress(): string {
    return this.account.accountAddress.toString();
  }

  // ============ LENDER FUNCTIONS ============

  async deposit(amountUsdc: number): Promise<string> {
    const amount = this.toRawAmount(amountUsdc);
    const tx = await this.aptos.transaction.build.simple({
      sender: this.account.accountAddress,
      data: {
        function: `${CONTRACT}::lending_pool::deposit`,
        functionArguments: [ADMIN, amount],
      },
    });
    const response = await this.aptos.signAndSubmitTransaction({
      signer: this.account,
      transaction: tx,
    });
    await this.aptos.waitForTransaction({ transactionHash: response.hash });
    return response.hash;
  }

  async withdrawFromPool(amountUsdc: number): Promise<string> {
    const amount = this.toRawAmount(amountUsdc);
    const tx = await this.aptos.transaction.build.simple({
      sender: this.account.accountAddress,
      data: {
        function: `${CONTRACT}::lending_pool::withdraw`,
        functionArguments: [ADMIN, amount],
      },
    });
    const response = await this.aptos.signAndSubmitTransaction({
      signer: this.account,
      transaction: tx,
    });
    await this.aptos.waitForTransaction({ transactionHash: response.hash });
    return response.hash;
  }

  async getLenderInfo(address?: string): Promise<{
    deposited: number;
    earnedInterest: number;
    depositTimestamp: Date;
  }> {
    const addr = address || this.getAddress();
    const result = await this.aptos.view({
      payload: {
        function: `${CONTRACT}::lending_pool::get_lender_info`,
        functionArguments: [ADMIN, addr],
      },
    });
    return {
      deposited: this.fromRawAmount(Number(result[0])),
      earnedInterest: this.fromRawAmount(Number(result[1])),
      depositTimestamp: new Date(Number(result[2]) * 1000),
    };
  }

  // ============ BORROWER FUNCTIONS ============

  async openCreditLine(collateralUsdc: number): Promise<string> {
    const amount = this.toRawAmount(collateralUsdc);
    const tx = await this.aptos.transaction.build.simple({
      sender: this.account.accountAddress,
      data: {
        function: `${CONTRACT}::credit_manager::open_credit_line`,
        functionArguments: [ADMIN, amount],
      },
    });
    const response = await this.aptos.signAndSubmitTransaction({
      signer: this.account,
      transaction: tx,
    });
    await this.aptos.waitForTransaction({ transactionHash: response.hash });
    return response.hash;
  }

  async addCollateral(amountUsdc: number): Promise<string> {
    const amount = this.toRawAmount(amountUsdc);
    const tx = await this.aptos.transaction.build.simple({
      sender: this.account.accountAddress,
      data: {
        function: `${CONTRACT}::credit_manager::add_collateral`,
        functionArguments: [ADMIN, amount],
      },
    });
    const response = await this.aptos.signAndSubmitTransaction({
      signer: this.account,
      transaction: tx,
    });
    await this.aptos.waitForTransaction({ transactionHash: response.hash });
    return response.hash;
  }

  async borrow(amountUsdc: number): Promise<string> {
    const amount = this.toRawAmount(amountUsdc);
    const tx = await this.aptos.transaction.build.simple({
      sender: this.account.accountAddress,
      data: {
        function: `${CONTRACT}::credit_manager::borrow`,
        functionArguments: [ADMIN, amount],
      },
    });
    const response = await this.aptos.signAndSubmitTransaction({
      signer: this.account,
      transaction: tx,
    });
    await this.aptos.waitForTransaction({ transactionHash: response.hash });
    return response.hash;
  }

  async borrowAndPay(recipientAddress: string, amountUsdc: number): Promise<string> {
    const amount = this.toRawAmount(amountUsdc);
    const tx = await this.aptos.transaction.build.simple({
      sender: this.account.accountAddress,
      data: {
        function: `${CONTRACT}::credit_manager::borrow_and_pay`,
        functionArguments: [ADMIN, recipientAddress, amount],
      },
    });
    const response = await this.aptos.signAndSubmitTransaction({
      signer: this.account,
      transaction: tx,
    });
    await this.aptos.waitForTransaction({ transactionHash: response.hash });
    return response.hash;
  }

  async repay(principalUsdc: number, interestUsdc: number = 0): Promise<string> {
    const principal = this.toRawAmount(principalUsdc);
    const interest = this.toRawAmount(interestUsdc);
    const tx = await this.aptos.transaction.build.simple({
      sender: this.account.accountAddress,
      data: {
        function: `${CONTRACT}::credit_manager::repay`,
        functionArguments: [ADMIN, principal, interest],
      },
    });
    const response = await this.aptos.signAndSubmitTransaction({
      signer: this.account,
      transaction: tx,
    });
    await this.aptos.waitForTransaction({ transactionHash: response.hash });
    return response.hash;
  }

  async withdrawCollateral(amountUsdc: number): Promise<string> {
    const amount = this.toRawAmount(amountUsdc);
    const tx = await this.aptos.transaction.build.simple({
      sender: this.account.accountAddress,
      data: {
        function: `${CONTRACT}::credit_manager::withdraw_collateral`,
        functionArguments: [ADMIN, amount],
      },
    });
    const response = await this.aptos.signAndSubmitTransaction({
      signer: this.account,
      transaction: tx,
    });
    await this.aptos.waitForTransaction({ transactionHash: response.hash });
    return response.hash;
  }

  // ============ NEW: COLLATERAL INFO FUNCTIONS ============

  /**
   * Get collateral details including earned interest
   * Returns: { principal, earnedInterest, total }
   */
  async getCollateralWithInterest(address?: string): Promise<{
    principal: number;
    earnedInterest: number;
    total: number;
  }> {
    const addr = address || this.getAddress();
    const result = await this.aptos.view({
      payload: {
        function: `${CONTRACT}::lending_pool::get_collateral_with_interest`,
        functionArguments: [ADMIN, addr],
      },
    });
    return {
      principal: this.fromRawAmount(Number(result[0])),
      earnedInterest: this.fromRawAmount(Number(result[1])),
      total: this.fromRawAmount(Number(result[2])),
    };
  }

  /**
   * Check if borrower has collateral deposited
   */
  async hasCollateral(address?: string): Promise<boolean> {
    const addr = address || this.getAddress();
    const result = await this.aptos.view({
      payload: {
        function: `${CONTRACT}::lending_pool::has_collateral`,
        functionArguments: [ADMIN, addr],
      },
    });
    return result[0] as boolean;
  }

  /**
   * Get credit line information (credit_limit is now dynamic!)
   */
  async getCreditInfo(address?: string): Promise<{
    initialCollateral: number;
    creditLimit: number;  // Dynamic: collateral + earned interest
    borrowed: number;
    interest: number;
    totalRepaid: number;
    dueDate: Date;
    isActive: boolean;
  }> {
    const addr = address || this.getAddress();
    const result = await this.aptos.view({
      payload: {
        function: `${CONTRACT}::credit_manager::get_credit_info`,
        functionArguments: [ADMIN, addr],
      },
    });
    return {
      initialCollateral: this.fromRawAmount(Number(result[0])),
      creditLimit: this.fromRawAmount(Number(result[1])),
      borrowed: this.fromRawAmount(Number(result[2])),
      interest: this.fromRawAmount(Number(result[3])),
      totalRepaid: this.fromRawAmount(Number(result[4])),
      dueDate: new Date(Number(result[5]) * 1000),
      isActive: result[6] as boolean,
    };
  }

  // ============ POOL INFO FUNCTIONS ============

  async getPoolInfo(): Promise<{
    totalDeposited: number;
    totalCollateral: number;
    totalBorrowed: number;
    availableLiquidity: number;
    utilizationRate: number;
  }> {
    const [deposited, collateral, borrowed, liquidity, utilization] = await Promise.all([
      this.aptos.view({
        payload: {
          function: `${CONTRACT}::lending_pool::get_total_deposited`,
          functionArguments: [ADMIN],
        },
      }),
      this.aptos.view({
        payload: {
          function: `${CONTRACT}::lending_pool::get_total_collateral`,
          functionArguments: [ADMIN],
        },
      }),
      this.aptos.view({
        payload: {
          function: `${CONTRACT}::lending_pool::get_total_borrowed`,
          functionArguments: [ADMIN],
        },
      }),
      this.aptos.view({
        payload: {
          function: `${CONTRACT}::lending_pool::get_available_liquidity`,
          functionArguments: [ADMIN],
        },
      }),
      this.aptos.view({
        payload: {
          function: `${CONTRACT}::lending_pool::get_utilization_rate`,
          functionArguments: [ADMIN],
        },
      }),
    ]);

    return {
      totalDeposited: this.fromRawAmount(Number(deposited[0])),
      totalCollateral: this.fromRawAmount(Number(collateral[0])),
      totalBorrowed: this.fromRawAmount(Number(borrowed[0])),
      availableLiquidity: this.fromRawAmount(Number(liquidity[0])),
      utilizationRate: Number(utilization[0]) / 100,
    };
  }

  // ============ CREDIT LINE STATUS FUNCTIONS ============

  async hasCreditLine(address?: string): Promise<boolean> {
    const addr = address || this.getAddress();
    const result = await this.aptos.view({
      payload: {
        function: `${CONTRACT}::credit_manager::has_credit_line`,
        functionArguments: [ADMIN, addr],
      },
    });
    return result[0] as boolean;
  }

  async getCreditLineStatus(address?: string): Promise<{
    exists: boolean;
    isActive: boolean;
    collateral: number;
    creditLimit: number;
    borrowed: number;
  }> {
    const addr = address || this.getAddress();
    const result = await this.aptos.view({
      payload: {
        function: `${CONTRACT}::credit_manager::get_credit_line_status`,
        functionArguments: [ADMIN, addr],
      },
    });
    return {
      exists: result[0] as boolean,
      isActive: result[1] as boolean,
      collateral: this.fromRawAmount(Number(result[2])),
      creditLimit: this.fromRawAmount(Number(result[3])),
      borrowed: this.fromRawAmount(Number(result[4])),
    };
  }

  async smartAddCollateral(amountUsdc: number): Promise<string> {
    const hasCreditLine = await this.hasCreditLine();
    if (hasCreditLine) {
      return await this.addCollateral(amountUsdc);
    } else {
      return await this.openCreditLine(amountUsdc);
    }
  }

  // ============ REPUTATION FUNCTIONS ============

  async getReputationScore(address?: string): Promise<number> {
    const addr = address || this.getAddress();
    const result = await this.aptos.view({
      payload: {
        function: `${CONTRACT}::reputation_manager::get_reputation_score`,
        functionArguments: [ADMIN, addr],
      },
    });
    return Number(result[0]);
  }

  async checkCreditIncreaseEligibility(address?: string): Promise<{
    eligible: boolean;
    newLimit: number;
  }> {
    const addr = address || this.getAddress();
    const result = await this.aptos.view({
      payload: {
        function: `${CONTRACT}::credit_manager::check_credit_increase_eligibility`,
        functionArguments: [ADMIN, addr],
      },
    });
    return {
      eligible: result[0] as boolean,
      newLimit: this.fromRawAmount(Number(result[1])),
    };
  }
}

// ============ USAGE EXAMPLE ============

async function main() {
  const protocol = new AIONProtocol("YOUR_PRIVATE_KEY_HERE");
  console.log(`Connected as: ${protocol.getAddress()}`);

  // Check pool info (now includes collateral)
  const poolInfo = await protocol.getPoolInfo();
  console.log("Pool Info:", poolInfo);

  // Open credit line with 10 USDC collateral
  const openTx = await protocol.openCreditLine(10);
  console.log(`Opened credit line: ${openTx}`);

  // Check collateral with earned interest
  const collateralInfo = await protocol.getCollateralWithInterest();
  console.log("Collateral Info:", collateralInfo);
  // { principal: 10, earnedInterest: 0.05, total: 10.05 }

  // Borrow (can borrow up to total collateral!)
  const borrowTx = await protocol.borrow(5);
  console.log(`Borrowed: ${borrowTx}`);

  // Repay
  const creditInfo = await protocol.getCreditInfo();
  const repayTx = await protocol.repay(5, creditInfo.interest);
  console.log(`Repaid: ${repayTx}`);

  // Withdraw collateral (includes earned interest!)
  const withdrawTx = await protocol.withdrawCollateral(10.05);
  console.log(`Withdrew collateral + interest: ${withdrawTx}`);
}

main().catch(console.error);
```

---

## CLI Integration

### Environment Setup

```bash
# Set variables
export CONTRACT="0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78"
export ADMIN="0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78"
export MAINNET_URL="https://fullnode.mainnet.aptoslabs.com"
```

### Borrower Commands

```bash
# Open credit line with 5 USDC collateral
aptos move run \
  --function-id ${CONTRACT}::credit_manager::open_credit_line \
  --args address:${ADMIN} u64:5000000 \
  --profile your_profile

# Check collateral with earned interest
aptos move view \
  --function-id ${CONTRACT}::lending_pool::get_collateral_with_interest \
  --args address:${ADMIN} address:YOUR_ADDRESS

# Borrow 2 USDC
aptos move run \
  --function-id ${CONTRACT}::credit_manager::borrow \
  --args address:${ADMIN} u64:2000000 \
  --profile your_profile

# Repay 2 USDC principal
aptos move run \
  --function-id ${CONTRACT}::credit_manager::repay \
  --args address:${ADMIN} u64:2000000 u64:0 \
  --profile your_profile

# Withdraw collateral (includes earned interest)
aptos move run \
  --function-id ${CONTRACT}::credit_manager::withdraw_collateral \
  --args address:${ADMIN} u64:5000000 \
  --profile your_profile

# Check credit info
aptos move view \
  --function-id ${CONTRACT}::credit_manager::get_credit_info \
  --args address:${ADMIN} address:YOUR_ADDRESS

# Check collateral details
aptos move view \
  --function-id ${CONTRACT}::credit_manager::get_collateral_details \
  --args address:${ADMIN} address:YOUR_ADDRESS
```

### Pool View Commands

```bash
# Pool liquidity
aptos move view \
  --function-id ${CONTRACT}::lending_pool::get_available_liquidity \
  --args address:${ADMIN}

# Total collateral in pool
aptos move view \
  --function-id ${CONTRACT}::lending_pool::get_total_collateral \
  --args address:${ADMIN}

# Check if user has collateral
aptos move view \
  --function-id ${CONTRACT}::lending_pool::has_collateral \
  --args address:${ADMIN} address:YOUR_ADDRESS
```

---

## Protocol Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Minimum Deposit | 1 USDC | Minimum lending pool deposit |
| Minimum Collateral | 1 USDC | Minimum to open credit line |
| Minimum Borrow | 0.1 USDC | Minimum borrow amount |
| Collateralization Ratio | 100% | 1:1 collateral to credit limit |
| Credit Limit | Dynamic | Collateral + earned interest |
| Fixed Interest Rate | 15% APR | Annual interest on borrowed funds |
| Protocol Fee | 10% | Fee on interest (to protocol) |
| Grace Period | 30 days | Time before late penalties |
| Repayment Term | 60 days | Total repayment window |
| Reputation Threshold | 750 | Score for credit increase |
| Credit Increase | 120% | Multiplier on eligibility |
| Liquidation Threshold | 110% LTV | Position can be liquidated |

---

## Error Codes

### Common Errors

| Code | Constant | Description |
|------|----------|-------------|
| 1 | `E_NOT_AUTHORIZED` | Not authorized or paused |
| 2 | `E_INSUFFICIENT_BALANCE` | Insufficient funds |
| 3 | `E_INSUFFICIENT_LIQUIDITY` | Pool lacks liquidity |
| 4 | `E_INVALID_AMOUNT` | Invalid amount (zero) |
| 5 | `E_ALREADY_INITIALIZED` | Already exists |
| 6 | `E_NOT_INITIALIZED` | Not initialized |
| 7 | `E_INVALID_ADDRESS` | Invalid address |

### Credit Manager Errors

| Code | Constant | Description |
|------|----------|-------------|
| 3 | `E_CREDIT_LINE_EXISTS` | Credit line already exists |
| 4 | `E_CREDIT_LINE_NOT_ACTIVE` | No active credit line |
| 5 | `E_EXCEEDS_CREDIT_LIMIT` | Borrow exceeds limit |
| 6 | `E_INSUFFICIENT_LIQUIDITY` | Insufficient pool funds |
| 7 | `E_EXCEEDS_BORROWED_AMOUNT` | Repay exceeds debt |
| 14 | `E_BELOW_MINIMUM_AMOUNT` | Below minimum |
| 15 | `E_NO_ACTIVE_DEBT` | No debt to repay |
| 16 | `E_HAS_OUTSTANDING_DEBT` | Cannot withdraw with debt |

### Lending Pool Errors

| Code | Constant | Description |
|------|----------|-------------|
| 8 | `E_COLLATERAL_NOT_FOUND` | No collateral deposited |

---

## Tested Transactions (Mainnet v2.0)

### v2.0 Deployment & Testing (February 2026)

**Contract Deployment:** `0xc4a46542e5938edff0bd04465b031f397ee5d3e273cbcef12f60002b20017e72`

| Operation | Transaction Hash | Status |
|-----------|------------------|--------|
| Deploy Contracts | `0xc4a46542e5938edff0bd04465b031f397ee5d3e273cbcef12f60002b20017e72` | ✅ |
| Initialize Collateral Vault | `0x1c2f4752ceee11006e4e6c972b7b1002b6890334ef4b07c096458087fd7c7f89` | ✅ |
| Initialize Reputation Manager | `0x3011915f9f11c2c50f43d8ce35d8a9e717dedc194bd009ff438ea48a9427458d` | ✅ |
| Initialize Interest Rate Model | `0x699f6a4c0c83602a6d6059e8e208a8ebb80a53ec016fd194317a7450a499ef1f` | ✅ |
| Initialize Lending Pool | `0x3ccabd5533aa5fbfcd26d43e3944df9fd0899a3bbfb2dc7fe5f0e5c5ea69646b` | ✅ |
| Initialize Credit Manager | `0x9e301729eedf18d8fd65af8dd758aab3a8ecd80678b7448699d79509a13f5f7c` | ✅ |
| Open Credit Line (1.5 USDC) | `0xd2e09b481f3dc4869d847750d70e128a3d4be6cbcaf2fea5851607a49448d1c6` | ✅ |
| Borrow (0.5 USDC) | `0x9a3a5483b58700f3a097294a7d1d8aba16ac6757e39dfb97826ef231756eea6c` | ✅ |
| Repay (0.5 USDC) | `0xee666007ffb235907b9225531c42cd8ede984aef0397c8065efcd9d3ac1a2042` | ✅ |
| Withdraw Collateral | `0xbea546644737206d59570ace2d232b6f0f1351f89867a53013c7990cc8a7535e` | ✅ |

**Test Wallet:** `0x39eafa52cae5498eca230e656f0e7f3cfb627387276360d36e660336f8b905d3`

View on Explorer: `https://explorer.aptoslabs.com/txn/{hash}?network=mainnet`

---

## Security Considerations

### USDC Integration
- Uses Circle's native USDC on Aptos (Fungible Asset standard)
- Utilizes `dispatchable_fungible_asset` for compatibility
- No separate approval needed

### Access Control
- Admin functions require admin signature
- 2-step admin transfer (initiate + accept)
- Pause mechanism for emergencies

### Collateral Safety
- Collateral held in lending pool stores
- Cannot withdraw with outstanding debt
- Liquidation for unhealthy positions
- Interest earned increases collateral value

### Best Practices
1. Always check pool liquidity before borrowing
2. Monitor your debt-to-collateral ratio
3. Repay on time to improve reputation
4. Keep buffer collateral to avoid liquidation
5. Check `get_collateral_with_interest` to see your earned interest

---

## Support

### Resources
- **Explorer:** [Aptos Explorer](https://explorer.aptoslabs.com/account/0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78?network=mainnet)
- **Aptos SDK:** [@aptos-labs/ts-sdk](https://www.npmjs.com/package/@aptos-labs/ts-sdk)
- **Aptos CLI:** [Install Guide](https://aptos.dev/cli-tools/aptos-cli-tool/install-aptos-cli)

### USDC on Aptos
- **Bridge:** [Circle CCTP](https://www.circle.com/en/cross-chain-transfer-protocol)
- **Token Address:** `0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b`

---

## Changelog

### v4.0 / v2.0.0 (February 2026) - Collateral Earns Interest
- **Major:** Collateral is now deposited into lending pool and earns interest
- **Major:** Credit limits are now dynamic (collateral + earned interest)
- **New:** `lending_pool::get_collateral_with_interest` view function
- **New:** `lending_pool::has_collateral` view function
- **New:** `lending_pool::get_total_collateral` view function
- **New:** `lending_pool::get_all_collateral_depositors` view function
- **New:** `credit_manager::get_collateral_details` view function
- **New Contract Address:** `0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78`

### v3.1 (February 2026)
- **Fix:** `add_collateral` now reactivates inactive credit lines
- **New:** `has_credit_line` view function
- **New:** `get_credit_line_status` view function

### v3.0 (January 2026)
- Initial mainnet deployment
- Full Fungible Asset support for Circle USDC
- Core modules: Lending Pool, Credit Manager, Collateral Vault, Reputation Manager, Interest Rate Model

---

*Last Updated: February 2026*
*Version: 4.0 (Mainnet)*
*Contract: 0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78*
*Status: Production Ready*
