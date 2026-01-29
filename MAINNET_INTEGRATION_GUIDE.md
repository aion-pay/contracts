# AION Credit Protocol - Mainnet Integration Guide v3.0

## Overview

**Status:** ✅ **LIVE ON APTOS MAINNET**
**Network:** Aptos Mainnet
**Token:** Circle USDC (Native Fungible Asset)
**Last Updated:** January 2026
**Testing Status:** All functions verified with real USDC ✅

This guide provides complete documentation for integrating with the AION Credit Protocol deployed on Aptos Mainnet. The protocol enables decentralized credit lines backed by USDC collateral.

---

## Mainnet Deployment Addresses

| Component | Address |
|-----------|---------|
| **Contract Package** | `0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172` |
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
credit_protocol::lending_pool          - Liquidity management
credit_protocol::credit_manager        - Core credit operations
credit_protocol::collateral_vault      - Collateral handling
credit_protocol::reputation_manager    - Credit scoring
credit_protocol::interest_rate_model   - Rate calculations
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     AION Credit Protocol (Mainnet)                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────┐    ┌────────────────┐    ┌──────────────────┐  │
│  │  Lending Pool  │◄───│ Credit Manager │───►│ Collateral Vault │  │
│  │   (Liquidity)  │    │    (Core)      │    │   (Collateral)   │  │
│  └────────────────┘    └───────┬────────┘    └──────────────────┘  │
│                                │                                    │
│         ┌──────────────────────┼──────────────────────┐            │
│         ▼                      ▼                      ▼            │
│  ┌────────────────┐    ┌────────────────┐    ┌──────────────────┐  │
│  │   Reputation   │    │ Interest Rate  │    │   Circle USDC    │  │
│  │    Manager     │    │     Model      │    │ (Fungible Asset) │  │
│  └────────────────┘    └────────────────┘    └──────────────────┘  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Data Flow
1. **Lenders** deposit USDC → Lending Pool
2. **Borrowers** deposit collateral → Credit Manager
3. **Credit line opens** → 1:1 collateral-to-credit ratio
4. **Borrowing** → Funds from Lending Pool
5. **Repayment** → Interest distributed to lenders
6. **Reputation updates** → Credit limit adjustments

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

Manages lender deposits and provides liquidity for borrowers.

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
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::lending_pool::deposit \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 u64:1000000 \
  --url https://fullnode.mainnet.aptoslabs.com \
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
```

---

### 2. Credit Manager

Core module for credit lines, borrowing, and repayment.

#### Entry Functions

##### `open_credit_line`
Open a new credit line by depositing USDC collateral.

```move
public entry fun open_credit_line(
    borrower: &signer,
    manager_addr: address,     // Admin address
    collateral_amount: u64,    // USDC amount (min: 1 USDC = 1000000)
)
```

**Credit Limit:** 1:1 ratio (e.g., 10 USDC collateral = 10 USDC credit limit)

##### `add_collateral`
Add more collateral to increase credit limit.

```move
public entry fun add_collateral(
    borrower: &signer,
    manager_addr: address,
    collateral_amount: u64,
)
```

##### `borrow`
Borrow USDC against your credit line.

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
Withdraw collateral (only when no outstanding debt).

```move
public entry fun withdraw_collateral(
    borrower: &signer,
    manager_addr: address,
    amount: u64,
)
```

#### View Functions

```move
#[view]
public fun get_credit_info(
    manager_addr: address,
    borrower: address,
): (u64, u64, u64, u64, u64, u64, bool)
// Returns: (collateral, credit_limit, borrowed, interest, total_debt, due_date, is_active)

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

### 4. Collateral Vault

Manages collateral deposits (used internally by Credit Manager).

#### View Functions

```move
#[view]
public fun get_collateral_balance(vault_addr: address, user: address): u64

#[view]
public fun get_user_collateral(
    vault_addr: address,
    user: address,
): (u64, u64, u64, u8)
// Returns: (total_amount, locked_amount, available_amount, status)

#[view]
public fun get_total_collateral(vault_addr: address): u64

#[view]
public fun get_collateralization_ratio(vault_addr: address): u256

#[view]
public fun get_liquidation_threshold(vault_addr: address): u256
```

---

### 5. Interest Rate Model

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
  AccountAddress,
} from "@aptos-labs/ts-sdk";

// ============ CONFIGURATION ============

const CONTRACT = "0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172";
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

  /**
   * Deposit USDC to the lending pool
   * @param amountUsdc Amount in USDC (e.g., 10 for 10 USDC)
   */
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

  /**
   * Withdraw USDC from the lending pool
   * @param amountUsdc Amount in USDC
   */
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

  /**
   * Get lender information
   */
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

  /**
   * Open a new credit line with USDC collateral
   * @param collateralUsdc Collateral amount in USDC (min: 1 USDC)
   */
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

  /**
   * Add collateral to existing credit line
   * @param amountUsdc Additional collateral in USDC
   */
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

  /**
   * Borrow USDC against credit line
   * @param amountUsdc Amount to borrow (min: 0.1 USDC)
   */
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

  /**
   * Borrow and pay directly to a recipient
   * @param recipientAddress Recipient's address
   * @param amountUsdc Amount to borrow and send
   */
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

  /**
   * Repay borrowed amount
   * @param principalUsdc Principal amount to repay
   * @param interestUsdc Interest amount to repay (optional)
   */
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

  /**
   * Withdraw collateral (requires no outstanding debt)
   * @param amountUsdc Amount to withdraw
   */
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

  /**
   * Get credit line information
   */
  async getCreditInfo(address?: string): Promise<{
    collateral: number;
    creditLimit: number;
    borrowed: number;
    interest: number;
    totalDebt: number;
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
      collateral: this.fromRawAmount(Number(result[0])),
      creditLimit: this.fromRawAmount(Number(result[1])),
      borrowed: this.fromRawAmount(Number(result[2])),
      interest: this.fromRawAmount(Number(result[3])),
      totalDebt: this.fromRawAmount(Number(result[4])),
      dueDate: new Date(Number(result[5]) * 1000),
      isActive: result[6] as boolean,
    };
  }

  // ============ POOL INFO FUNCTIONS ============

  /**
   * Get lending pool statistics
   */
  async getPoolInfo(): Promise<{
    totalDeposited: number;
    totalBorrowed: number;
    availableLiquidity: number;
    utilizationRate: number;
  }> {
    const [deposited, borrowed, liquidity, utilization] = await Promise.all([
      this.aptos.view({
        payload: {
          function: `${CONTRACT}::lending_pool::get_total_deposited`,
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
      totalBorrowed: this.fromRawAmount(Number(borrowed[0])),
      availableLiquidity: this.fromRawAmount(Number(liquidity[0])),
      utilizationRate: Number(utilization[0]) / 100,
    };
  }

  // ============ REPUTATION FUNCTIONS ============

  /**
   * Get user's reputation score (0-1000)
   */
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

  /**
   * Check credit increase eligibility
   */
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
  // Initialize with your private key (without 0x prefix)
  const protocol = new AIONProtocol("YOUR_PRIVATE_KEY_HERE");

  console.log(`Connected as: ${protocol.getAddress()}`);

  // === LENDER FLOW ===

  // Check pool info
  const poolInfo = await protocol.getPoolInfo();
  console.log("Pool Info:", poolInfo);

  // Deposit 5 USDC
  const depositTx = await protocol.deposit(5);
  console.log(`Deposited: ${depositTx}`);

  // === BORROWER FLOW ===

  // Open credit line with 10 USDC collateral
  const openTx = await protocol.openCreditLine(10);
  console.log(`Opened credit line: ${openTx}`);

  // Borrow 5 USDC
  const borrowTx = await protocol.borrow(5);
  console.log(`Borrowed: ${borrowTx}`);

  // Check credit info
  const creditInfo = await protocol.getCreditInfo();
  console.log("Credit Info:", creditInfo);

  // Repay the loan
  const repayTx = await protocol.repay(5, creditInfo.interest);
  console.log(`Repaid: ${repayTx}`);

  // Withdraw collateral
  const withdrawTx = await protocol.withdrawCollateral(10);
  console.log(`Withdrew collateral: ${withdrawTx}`);
}

main().catch(console.error);
```

---

## CLI Integration

### Environment Setup

```bash
# Set variables
export CONTRACT="0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172"
export ADMIN="0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78"
export MAINNET_URL="https://fullnode.mainnet.aptoslabs.com"
```

### Lender Commands

```bash
# Deposit 10 USDC (10000000 = 10 * 10^6)
aptos move run \
  --function-id ${CONTRACT}::lending_pool::deposit \
  --args address:${ADMIN} u64:10000000 \
  --url ${MAINNET_URL} \
  --profile your_profile \
  --assume-yes

# Withdraw 5 USDC
aptos move run \
  --function-id ${CONTRACT}::lending_pool::withdraw \
  --args address:${ADMIN} u64:5000000 \
  --url ${MAINNET_URL} \
  --profile your_profile \
  --assume-yes

# Check lender info
aptos move view \
  --function-id ${CONTRACT}::lending_pool::get_lender_info \
  --args address:${ADMIN} address:YOUR_ADDRESS \
  --url ${MAINNET_URL}
```

### Borrower Commands

```bash
# Open credit line with 5 USDC collateral
aptos move run \
  --function-id ${CONTRACT}::credit_manager::open_credit_line \
  --args address:${ADMIN} u64:5000000 \
  --url ${MAINNET_URL} \
  --profile your_profile \
  --assume-yes

# Borrow 2 USDC
aptos move run \
  --function-id ${CONTRACT}::credit_manager::borrow \
  --args address:${ADMIN} u64:2000000 \
  --url ${MAINNET_URL} \
  --profile your_profile \
  --assume-yes

# Borrow and pay directly to recipient
aptos move run \
  --function-id ${CONTRACT}::credit_manager::borrow_and_pay \
  --args address:${ADMIN} address:RECIPIENT_ADDRESS u64:1000000 \
  --url ${MAINNET_URL} \
  --profile your_profile \
  --assume-yes

# Repay 2 USDC principal, 0 interest
aptos move run \
  --function-id ${CONTRACT}::credit_manager::repay \
  --args address:${ADMIN} u64:2000000 u64:0 \
  --url ${MAINNET_URL} \
  --profile your_profile \
  --assume-yes

# Withdraw collateral
aptos move run \
  --function-id ${CONTRACT}::credit_manager::withdraw_collateral \
  --args address:${ADMIN} u64:5000000 \
  --url ${MAINNET_URL} \
  --profile your_profile \
  --assume-yes

# Check credit info
aptos move view \
  --function-id ${CONTRACT}::credit_manager::get_credit_info \
  --args address:${ADMIN} address:YOUR_ADDRESS \
  --url ${MAINNET_URL}
```

### View Commands

```bash
# Pool liquidity
aptos move view \
  --function-id ${CONTRACT}::lending_pool::get_available_liquidity \
  --args address:${ADMIN} \
  --url ${MAINNET_URL}

# Reputation score
aptos move view \
  --function-id ${CONTRACT}::reputation_manager::get_reputation_score \
  --args address:${ADMIN} address:YOUR_ADDRESS \
  --url ${MAINNET_URL}

# Credit increase eligibility
aptos move view \
  --function-id ${CONTRACT}::credit_manager::check_credit_increase_eligibility \
  --args address:${ADMIN} address:YOUR_ADDRESS \
  --url ${MAINNET_URL}
```

---

## Protocol Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Minimum Deposit | 1 USDC | Minimum lending pool deposit |
| Minimum Collateral | 1 USDC | Minimum to open credit line |
| Minimum Borrow | 0.1 USDC | Minimum borrow amount |
| Collateralization Ratio | 100% | 1:1 collateral to credit limit |
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
| 8 | `E_EXCEEDS_INTEREST` | Interest exceeds accrued |
| 9 | `E_LIQUIDATION_NOT_ALLOWED` | Cannot liquidate |
| 14 | `E_BELOW_MINIMUM_AMOUNT` | Below minimum |
| 15 | `E_NO_ACTIVE_DEBT` | No debt to repay |
| 16 | `E_HAS_OUTSTANDING_DEBT` | Cannot withdraw with debt |

---

## Events

### Credit Manager Events

```move
#[event]
struct CreditOpenedEvent {
    borrower: address,
    collateral_amount: u64,
    credit_limit: u64,
    timestamp: u64,
}

#[event]
struct BorrowedEvent {
    borrower: address,
    amount: u64,
    total_borrowed: u64,
    due_date: u64,
    timestamp: u64,
}

#[event]
struct DirectPaymentEvent {
    borrower: address,
    recipient: address,
    amount: u64,
    total_borrowed: u64,
    due_date: u64,
    timestamp: u64,
}

#[event]
struct RepaidEvent {
    borrower: address,
    principal_amount: u64,
    interest_amount: u64,
    remaining_balance: u64,
    timestamp: u64,
}

#[event]
struct CreditLimitIncreasedEvent {
    borrower: address,
    old_limit: u64,
    new_limit: u64,
    reputation_score: u256,
    timestamp: u64,
}
```

### Lending Pool Events

```move
#[event]
struct DepositEvent {
    lender: address,
    amount: u64,
    timestamp: u64,
}

#[event]
struct WithdrawEvent {
    lender: address,
    amount: u64,
    interest: u64,
    timestamp: u64,
}
```

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
- Collateral held in protocol-controlled stores
- Cannot withdraw with outstanding debt
- Liquidation for unhealthy positions

### Best Practices
1. Always check pool liquidity before borrowing
2. Monitor your debt-to-collateral ratio
3. Repay on time to improve reputation
4. Keep buffer collateral to avoid liquidation

---

## Tested Transactions (Mainnet)

The following transactions verify full functionality on mainnet:

| Operation | Transaction Hash | Status |
|-----------|------------------|--------|
| Deposit 2 USDC | `0x10a39b2de4a605eb5aaa79ab4883542bd9cb276cbd3570809df198cabb58eb5b` | ✅ |
| Open Credit Line | `0x89723d6d61795fbad77878229561720cea2876bc4cc5fc796068a5e311a9af62` | ✅ |
| Borrow 1 USDC | `0xdbd318b155d78de9802da728287278b82741741a74e3f422b50126d6b70520ed` | ✅ |
| Repay 1 USDC | `0x85e10211bcc470901e706b0681a97291a615ae00b13a16eae93bc24906b5ade6` | ✅ |
| Withdraw Collateral | `0x38dbbf52bf369004eb62ccf1078da6940285070f427190fd3e25947e19c07b7c` | ✅ |
| Withdraw from Pool | `0x8001d759bb1e03f65c05b0e719a1e99a20eb70f46413c83f8998ae3ad54f05a0` | ✅ |

View on Explorer: `https://explorer.aptoslabs.com/txn/{hash}?network=mainnet`

---

## Support

### Resources
- **Explorer:** [Aptos Explorer](https://explorer.aptoslabs.com/account/0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172?network=mainnet)
- **Aptos SDK:** [@aptos-labs/ts-sdk](https://www.npmjs.com/package/@aptos-labs/ts-sdk)
- **Aptos CLI:** [Install Guide](https://aptos.dev/cli-tools/aptos-cli-tool/install-aptos-cli)

### USDC on Aptos
- **Bridge:** [Circle CCTP](https://www.circle.com/en/cross-chain-transfer-protocol)
- **Token Address:** `0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b`

---

*Last Updated: January 2026*
*Version: 3.0 (Mainnet)*
*Status: Production Ready ✅*
