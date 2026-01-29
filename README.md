# AION Credit Protocol - Aptos Mainnet

A decentralized credit protocol built on Aptos blockchain using the Move programming language. The protocol enables overcollateralized lending with USDC, featuring a reputation-based credit system.

## Mainnet Deployment

### Contract Addresses

| Contract | Address |
|----------|---------|
| **Protocol (All Modules)** | `0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172` |
| **Admin** | `0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78` |
| **USDC Token (Metadata)** | `0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b` |

### Explorer Links

- **Contract:** [View on Explorer](https://explorer.aptoslabs.com/object/0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172?network=mainnet)
- **Deployment Tx:** [View Transaction](https://explorer.aptoslabs.com/txn/0xf636c220bbac036aafcff5d6eba2ef52569a81dee65ed97ae6abf6202bf54163?network=mainnet)

### Module Addresses

All modules are deployed under the protocol address. Access them using:

```
0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::credit_manager
0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::lending_pool
0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::collateral_vault
0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::reputation_manager
0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::interest_rate_model
```

### Initialization Transactions

| Module | Transaction Hash |
|--------|------------------|
| interest_rate_model | `0xf16be1090c4911d457a8aff5d0082e7a2e6d38b440fd3cc840e1652cf59beae3` |
| reputation_manager | `0x8e09d15a0ba458fc24ac6776695fe0a008d63dc896231118e5a3d2f048e705b2` |
| lending_pool | `0xe18de65db63dcd58d155161e22552a35902be761c5bc78be13178d1ea6caafdb` |
| collateral_vault | `0xbbb998bbc3f7ec3f31155b5ec8dc7d3f0242161bd212ea9ae875a11b616eda2a` |
| credit_manager | `0x625455aa42404cbe14bb7de99badc3b10667d200cc833791221c9f06e5e30cf8` |

---

## Architecture

The protocol consists of 5 main modules:

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│  Interest Rate  │    │   Reputation     │    │  Collateral     │
│     Model       │    │    Manager       │    │     Vault       │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌─────────────────────┐
                    │   Credit Manager    │
                    │   (Orchestrator)    │
                    └─────────────────────┘
                                 │
                    ┌─────────────────────┐
                    │    Lending Pool     │
                    │    (Liquidity)      │
                    └─────────────────────┘
```

### 1. Credit Manager (`credit_manager`)
- Core orchestration layer for the protocol
- Manages credit line creation and lifecycle
- Handles borrowing, repayment, and liquidation logic
- Integrates with all other modules
- Manages credit limit increases based on reputation

### 2. Lending Pool (`lending_pool`)
- Manages liquidity deposits and withdrawals from lenders
- Handles borrowing and repayment flows
- Distributes interest to lenders proportionally
- Collects protocol fees (10% of interest)
- Tracks utilization rates

### 3. Collateral Vault (`collateral_vault`)
- Manages borrower collateral deposits
- Handles collateral locking/unlocking
- Supports liquidation mechanisms
- Configurable collateralization ratio (default 150%)
- Liquidation threshold (default 120%)

### 4. Reputation Manager (`reputation_manager`)
- Tracks borrower credit scores (0-1000)
- Records on-time vs late payments
- Manages reputation tiers (Bronze, Silver, Gold, Platinum)
- Enables credit limit increases based on good behavior

### 5. Interest Rate Model (`interest_rate_model`)
- Manages interest rate calculations
- Default fixed rate: 15% APR
- Configurable grace period (default 30 days)
- Supports both fixed and dynamic rate models

---

## Token Standard

The protocol uses the **Aptos Fungible Asset Standard** with support for **Dispatchable Tokens**. This enables compatibility with:
- Native USDC on Aptos
- Any fungible asset following the Aptos FA standard

---

## Integration Guide

### For Frontend/SDK Integration

#### Constants
```typescript
const PROTOCOL_ADDRESS = "0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172";
const ADMIN_ADDRESS = "0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78";
const USDC_METADATA = "0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b";
```

### For Lenders

#### 1. Deposit USDC to Lending Pool
```bash
aptos move run \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::lending_pool::deposit \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 u64:<amount_in_micro_usdc>
```

#### 2. Withdraw from Lending Pool
```bash
aptos move run \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::lending_pool::withdraw \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 u64:<amount_in_micro_usdc>
```

#### 3. View Lender Info
```bash
aptos move view \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::lending_pool::get_lender_info \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 address:<lender_address>
```

### For Borrowers

#### 1. Open Credit Line (with collateral)
```bash
aptos move run \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::credit_manager::open_credit_line \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 u64:<collateral_amount>
```

#### 2. Add More Collateral
```bash
aptos move run \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::credit_manager::add_collateral \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 u64:<amount>
```

#### 3. Borrow USDC
```bash
aptos move run \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::credit_manager::borrow \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 u64:<amount>
```

#### 4. Borrow and Pay Directly to Recipient
```bash
aptos move run \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::credit_manager::borrow_and_pay \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 address:<recipient> u64:<amount>
```

#### 5. Repay Loan
```bash
aptos move run \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::credit_manager::repay \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 u64:<principal_amount> u64:<interest_amount>
```

#### 6. Withdraw Collateral (after repaying debt)
```bash
aptos move run \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::credit_manager::withdraw_collateral \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 u64:<amount>
```

#### 7. View Credit Info
```bash
aptos move view \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::credit_manager::get_credit_info \
  --args address:0xceb67803c3af67e2031e319f021e693ead697dda75e59a7b85a7e75a1cda4d78 address:<borrower_address>
```

Returns: `(collateral_deposited, credit_limit, borrowed_amount, interest_accrued, total_debt, repayment_due_date, is_active)`

---

## View Functions

### Lending Pool
| Function | Returns |
|----------|---------|
| `get_available_liquidity(pool_addr)` | Available USDC for borrowing |
| `get_utilization_rate(pool_addr)` | Pool utilization in basis points |
| `get_total_deposited(pool_addr)` | Total deposits |
| `get_total_borrowed(pool_addr)` | Total borrowed |
| `get_lender_info(pool_addr, lender)` | (deposited, earned_interest, timestamp) |

### Credit Manager
| Function | Returns |
|----------|---------|
| `get_credit_info(manager_addr, borrower)` | Full credit line details |
| `get_repayment_history(manager_addr, borrower)` | (on_time, late, total_repaid) |
| `check_credit_increase_eligibility(manager_addr, borrower)` | (eligible, new_limit) |

### Reputation Manager
| Function | Returns |
|----------|---------|
| `get_reputation_score(manager_addr, user)` | Score (0-1000) |
| `get_reputation_tier(manager_addr, user)` | Tier (0-3) |

### Collateral Vault
| Function | Returns |
|----------|---------|
| `get_collateral_balance(vault_addr, user)` | Collateral amount |
| `get_user_collateral(vault_addr, user)` | (amount, locked, available, status) |

---

## Protocol Parameters

### Interest Rate Model
| Parameter | Default Value |
|-----------|---------------|
| Base Rate | 15% APR (1500 basis points) |
| Max Rate | 20% APR |
| Penalty Rate | 30% APR |
| Grace Period | 30 days |

### Credit Manager
| Parameter | Default Value |
|-----------|---------------|
| Fixed Interest Rate | 15% APR |
| Reputation Threshold | 750 (for credit increase) |
| Credit Increase Multiplier | 120% |
| Min Collateral | 1 USDC |
| Min Borrow | 0.1 USDC |

### Collateral Vault
| Parameter | Default Value |
|-----------|---------------|
| Collateralization Ratio | 150% |
| Liquidation Threshold | 120% |
| Max Collateral | 1,000,000 USDC |

### Lending Pool
| Parameter | Default Value |
|-----------|---------------|
| Protocol Fee | 10% of interest |
| Min Deposit | 1 USDC |

---

## Events

The protocol emits events for all major actions:

### Credit Manager Events
- `CreditOpenedEvent` - Credit line opened
- `BorrowedEvent` - Funds borrowed
- `DirectPaymentEvent` - Borrow and pay to recipient
- `RepaidEvent` - Loan repaid
- `LiquidatedEvent` - Position liquidated
- `CreditLimitIncreasedEvent` - Credit limit increased
- `CollateralAddedEvent` - Collateral added
- `CollateralWithdrawnEvent` - Collateral withdrawn

### Lending Pool Events
- `DepositEvent` - Funds deposited
- `WithdrawEvent` - Funds withdrawn
- `BorrowEvent` - Funds borrowed
- `RepayEvent` - Loan repaid

### Reputation Manager Events
- `ReputationInitializedEvent` - User reputation initialized
- `ReputationUpdatedEvent` - Score updated
- `TierChangedEvent` - Tier changed

---

## Security Features

- **Move Resource Model**: Prevents reentrancy and ensures asset safety
- **Two-Step Admin Transfer**: Secure admin ownership changes
- **Pausable Modules**: Emergency stop functionality
- **Access Control**: Role-based permissions
- **Parameter Validation**: Comprehensive input validation
- **Overflow Protection**: Move's built-in safe math

---

## Admin Functions

### Pause/Unpause (Emergency)
```bash
# Pause
aptos move run --function-id <module>::pause --args address:<module_addr>

# Unpause
aptos move run --function-id <module>::unpause --args address:<module_addr>
```

### Transfer Admin (Two-Step)
```bash
# Step 1: Initiate transfer
aptos move run --function-id <module>::transfer_admin --args address:<module_addr> address:<new_admin>

# Step 2: New admin accepts
aptos move run --function-id <module>::accept_admin --args address:<module_addr>
```

### Update Parameters
```bash
# Update credit manager parameters
aptos move run \
  --function-id 0x636df8ee3f59dfe7d17ff23d3d072b13c38db48740ac18c27f558e6e26165172::credit_manager::update_parameters \
  --args address:<manager_addr> u256:<interest_rate> u256:<reputation_threshold> u256:<credit_multiplier>
```

---

## Development

### Compile
```bash
aptos move compile
```

### Test
```bash
aptos move test
```

### Deploy (New Instance)
```bash
# Set address to "_" in Move.toml first
aptos move deploy-object --address-name credit_protocol
```

---

## USDC on Aptos

### Mainnet USDC
- **Metadata Address:** `0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b`
- **Decimals:** 6
- **Standard:** Aptos Fungible Asset (with Dispatchable hooks)

### Testnet USDC
- **Metadata Address:** `0x69091fbab5f7d635ee7ac5098cf0c1efbe31d68fec0f2cd565e8d168daf52832`

---

## Amount Conversions

USDC has 6 decimals:
- 1 USDC = 1,000,000 (micro USDC)
- 0.1 USDC = 100,000
- 0.01 USDC = 10,000

---

## License

MIT License

---

## Support

For questions or issues, please open an issue in this repository.
