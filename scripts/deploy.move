// Deployment script for Credit Protocol
//
// IMPORTANT: For mainnet deployment, follow these steps:
//
// 1. First, publish the modules to the blockchain:
//    aptos move publish --named-addresses credit_protocol=<YOUR_ADDRESS>
//
// 2. Then call the initialization functions in this order with the USDC type parameter:
//
//    For Aptos Mainnet USDC (LayerZero):
//    USDC type: 0xf22bede237a07e121b56d91a491eb7bcdfd1f5907926a9e58338f964a01b17fa::asset::USDC
//
//    For Testnet (use AptosCoin as placeholder):
//    USDC type: 0x1::aptos_coin::AptosCoin
//
// 3. Initialization order:
//    a) Initialize Interest Rate Model
//    b) Initialize Reputation Manager
//    c) Initialize Collateral Vault
//    d) Initialize Lending Pool
//    e) Initialize Credit Manager (with addresses from steps a-d)
//
// 4. Update each module's credit_manager address using update_credit_manager()
//
// Example CLI commands for mainnet with USDC:
//
// # Interest Rate Model (no coin type needed)
// aptos move run --function-id <YOUR_ADDR>::interest_rate_model::initialize \
//   --args address:<YOUR_ADDR> 'Option<address>:none'
//
// # Reputation Manager (no coin type needed)
// aptos move run --function-id <YOUR_ADDR>::reputation_manager::initialize \
//   --args address:<YOUR_ADDR>
//
// # Collateral Vault with USDC type
// aptos move run --function-id <YOUR_ADDR>::collateral_vault::initialize \
//   --type-args 0xf22bede237a07e121b56d91a491eb7bcdfd1f5907926a9e58338f964a01b17fa::asset::USDC \
//   --args address:<YOUR_ADDR>
//
// # Lending Pool with USDC type
// aptos move run --function-id <YOUR_ADDR>::lending_pool::initialize \
//   --type-args 0xf22bede237a07e121b56d91a491eb7bcdfd1f5907926a9e58338f964a01b17fa::asset::USDC \
//   --args address:<YOUR_ADDR>
//
// # Credit Manager with USDC type
// aptos move run --function-id <YOUR_ADDR>::credit_manager::initialize \
//   --type-args 0xf22bede237a07e121b56d91a491eb7bcdfd1f5907926a9e58338f964a01b17fa::asset::USDC \
//   --args address:<YOUR_ADDR> address:<YOUR_ADDR> address:<YOUR_ADDR> address:<YOUR_ADDR>
//
// Note: Scripts cannot use type parameters directly. For programmatic deployment,
// use the module entry functions with type arguments as shown above.

script {
    use std::signer;
    use std::option;
    use aptos_framework::aptos_coin::AptosCoin;
    use credit_protocol::interest_rate_model;
    use credit_protocol::lending_pool;
    use credit_protocol::collateral_vault;
    use credit_protocol::reputation_manager;
    use credit_protocol::credit_manager;

    /// Deploy and initialize all contracts using AptosCoin (for testnet only)
    /// For mainnet, use CLI commands with proper USDC type parameter
    fun deploy_credit_protocol(deployer: &signer) {
        let deployer_addr = signer::address_of(deployer);

        // Step 1: Initialize Interest Rate Model (no coin type needed)
        interest_rate_model::initialize(
            deployer,
            deployer_addr, // credit_manager address (same as deployer for single-account deployment)
            option::none(), // Lending pool will be set via update_lending_pool()
        );

        // Step 2: Initialize Reputation Manager (no coin type needed)
        reputation_manager::initialize(
            deployer,
            deployer_addr, // credit_manager address
        );

        // Step 3: Initialize Collateral Vault with AptosCoin (testnet placeholder)
        // For mainnet: use USDC type parameter instead
        collateral_vault::initialize<AptosCoin>(
            deployer,
            deployer_addr, // credit_manager address
        );

        // Step 4: Initialize Lending Pool with AptosCoin (testnet placeholder)
        // For mainnet: use USDC type parameter instead
        lending_pool::initialize<AptosCoin>(
            deployer,
            deployer_addr, // credit_manager address
        );

        // Step 5: Initialize Credit Manager with all component addresses
        // For mainnet: use USDC type parameter instead
        // All modules are deployed to the same address (deployer_addr)
        credit_manager::initialize<AptosCoin>(
            deployer,
            deployer_addr, // lending_pool_addr
            deployer_addr, // collateral_vault_addr
            deployer_addr, // reputation_manager_addr
            deployer_addr, // interest_rate_model_addr
        );

        // After deployment, optionally update lending pool reference in interest rate model:
        // interest_rate_model::update_lending_pool(deployer, deployer_addr, option::some(deployer_addr));
    }
}
