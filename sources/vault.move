/// Vault module for swapping between InputCoin and OutputCoin with configurable rates
module vault::vault;

// === Imports ===

use std::string::String;
use std::u64::pow;
use sui::balance::{Self, Balance};
use sui::coin::{Coin, TreasuryCap};
use sui::dynamic_object_field as dof;
use sui::url::Url;


// === Error Constants ===

/// When the provided OwnerCap doesn't match the vault's ID
const EWrongOwnerCap: u64 = 1;
/// When trying to withdraw more than available in reserves
const EInsufficientReserves: u64 = 2;
/// When the exchange rate is zero
const EInvalidRate: u64 = 3;
/// When the provided VaultMetadata doesn't belong to this vault
const EInvalidMetadata: u64 = 4;
/// When arithmetic operation would cause overflow
const EArithmeticOverflow: u64 = 5;
/// When division by zero would occur
const EDivisionByZero: u64 = 6;

// === Structs ===

/// Main vault struct for managing coin exchanges
public struct Vault<phantom InputCoin, phantom OutputCoin> has key, store {
    id: UID,
    /// Exchange rate multiplier for input to output conversion
    rate: u64,
    /// Balance of input coins held in reserve
    reserve: Balance<InputCoin>,
    /// Decimals of the rate
    rate_decimals: u8,
}

// Multiple InputCoins inside of a Bag

/// Metadata for the vault containing display information
public struct VaultMetadata<phantom InputCoin, phantom OutputCoin> has key, store {
    id: UID,
    name: String,
    symbol: String,
    description: String,
    icon_url: Option<Url>,
}

/// Owner capability for vault administration
public struct OwnerCap has key, store {
    id: UID,
    vault_id: ID,
}

// === Public Functions ===

/// Creates a new vault with the specified parameters
/// Returns the vault shared object and transfers ownership capability to sender
#[allow(lint(self_transfer))]
public fun create_vault<InputCoin, OutputCoin>(
    rate: u64,
    output_coin_treasury: TreasuryCap<OutputCoin>,
    rate_decimals: u8,
    symbol: vector<u8>,
    name: vector<u8>,
    description: vector<u8>,
    icon_url: Option<Url>,
    ctx: &mut TxContext,
) {
    let mut vault = create_vault_inner<InputCoin, OutputCoin>(
        rate,
        rate_decimals,
        ctx,
    );
    
    let vault_metadata = create_vault_metadata_inner<InputCoin, OutputCoin>(
        name,
        symbol,
        description,
        icon_url,
        ctx,
    );

    let owner_cap = OwnerCap {
        id: object::new(ctx),
        vault_id: vault.id.to_inner(),
    };

    dof::add(&mut vault.id, vault_metadata.id.to_inner(), output_coin_treasury);

    transfer::freeze_object(vault_metadata);
    transfer::public_transfer(owner_cap, ctx.sender());
    transfer::share_object(vault);
}

// === Owner Functions ===

/// Deposits input coins into the vault (owner only)
/// Returns the owner capability to the sender
public fun deposit<InputCoin, OutputCoin>(
    owner_cap: &OwnerCap,
    vault: &mut Vault<InputCoin, OutputCoin>,
    amount: Coin<InputCoin>,
) {
    assert_owner_cap_matches(vault, owner_cap);

    vault.reserve.join(amount.into_balance());
}

/// Withdraws input coins from the vault reserves (owner only)
/// Returns the withdrawn coins and owner capability to the sender
public fun withdraw<InputCoin, OutputCoin>(
    owner_cap: &OwnerCap,
    vault: &mut Vault<InputCoin, OutputCoin>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<InputCoin> {
    assert_owner_cap_matches(vault, owner_cap);
    assert!(vault.reserve.value() >= amount, EInsufficientReserves);

    vault.reserve.split(amount).into_coin(ctx)
}

/// Updates the exchange rate for the vault (owner only)
/// Returns the owner capability to the sender
public fun set_rate<InputCoin, OutputCoin>(
    owner_cap: &OwnerCap,
    vault: &mut Vault<InputCoin, OutputCoin>,
    rate: u64,
) {
    assert_owner_cap_matches(vault, owner_cap);
    assert!(rate > 0, EInvalidRate);

    vault.rate = rate;
}

// === User Functions ===

/// Exchanges input coins for output coins based on vault's exchange rate
/// Input coins are added to reserves, output coins are minted from supply
public fun mint<InputCoin, OutputCoin>(
    vault: &mut Vault<InputCoin, OutputCoin>,
    vault_metadata: &VaultMetadata<InputCoin, OutputCoin>,
    input_coin: Coin<InputCoin>,
    ctx: &mut TxContext,
): Coin<OutputCoin> {
    assert_metadata_matches(vault, vault_metadata);
    
    let input_value = input_coin.value();
    let output_amount = calculate_output_amount_safe(
        vault.rate,
        input_value,
        vault.rate_decimals,
    );


    vault.reserve.join(input_coin.into_balance());
    
    dof::borrow_mut<ID, TreasuryCap<OutputCoin>>(
        &mut vault.id,
        vault_metadata.id.to_inner(),
    ).mint(output_amount, ctx)
}

/// Exchanges output coins for input coins based on vault's exchange rate
/// Output coins are burned from supply, input coins are taken from reserves
public fun redeem<InputCoin, OutputCoin>(
    vault: &mut Vault<InputCoin, OutputCoin>,
    vault_metadata: &VaultMetadata<InputCoin, OutputCoin>,
    output_coin: Coin<OutputCoin>,
    ctx: &mut TxContext,
): Coin<InputCoin> {
    assert_metadata_matches(vault, vault_metadata);
    
    let output_value = output_coin.value();
    let input_amount = calculate_input_amount_safe(
        vault.rate,
        output_value,
        vault.rate_decimals,
    );
    
    // Check sufficient reserves
    assert!(vault.reserve.value() >= input_amount, EInsufficientReserves);

    let input_coin = vault.reserve.split(input_amount).into_coin(ctx);
    
    // Burn the output coin (external call)
    dof::borrow_mut<ID, TreasuryCap<OutputCoin>>(
        &mut vault.id,
        vault_metadata.id.to_inner(),
    ).burn(output_coin);

    input_coin
}

// === View Functions ===

/// Returns the current exchange rate of the vault
/// Rate decimals and output coin decimals are the same
public fun rate<InputCoin, OutputCoin>(vault: &Vault<InputCoin, OutputCoin>): u64 {
    vault.rate
}

/// Returns the current reserve balance in the vault
public fun reserve_value<InputCoin, OutputCoin>(vault: &Vault<InputCoin, OutputCoin>): u64 {
    vault.reserve.value()
}

/// Checks if the owner capability is valid for the given vault
public fun is_valid_owner_cap<InputCoin, OutputCoin>(
    vault: &Vault<InputCoin, OutputCoin>,
    owner_cap: &OwnerCap,
): bool {
    vault.id.to_inner() == owner_cap.vault_id
}

// === Package Functions ===

/// Creates the core vault object (package internal)
public(package) fun create_vault_inner<InputCoin, OutputCoin>(
    rate: u64,
    rate_decimals: u8,
    ctx: &mut TxContext,
): Vault<InputCoin, OutputCoin> {
    assert!(rate > 0, EInvalidRate);

    Vault<InputCoin, OutputCoin> {
        id: object::new(ctx),
        rate,
        reserve: balance::zero<InputCoin>(),
        rate_decimals,
    }
}

/// Creates the vault metadata object (package internal)
public(package) fun create_vault_metadata_inner<InputCoin, OutputCoin>(
    name: vector<u8>,
    symbol: vector<u8>,
    description: vector<u8>,
    icon_url: Option<Url>,
    ctx: &mut TxContext,
): VaultMetadata<InputCoin, OutputCoin> {
    VaultMetadata<InputCoin, OutputCoin> {
        id: object::new(ctx),
        name: name.to_string(),
        symbol: symbol.to_string(),
        description: description.to_string(),
        icon_url,
    }
}


/// Calculates output coin amount with overflow protection
public(package) fun calculate_output_amount_safe(
    rate: u64,
    input_value: u64,
    rate_decimals: u8,
): u64 {
    assert!(rate > 0, EDivisionByZero);
    
    let divisor = pow(10, rate_decimals);
    assert!(divisor > 0, EDivisionByZero);
    
    // Check for multiplication overflow: rate * input_value <= u64::MAX
    let max_input = 18446744073709551615u64 / rate; // u64::MAX / rate
    assert!(input_value <= max_input, EArithmeticOverflow);
    
    (rate * input_value) / divisor
}

/// Calculates required input coin amount with overflow protection
public(package) fun calculate_input_amount_safe(
    rate: u64,
    output_value: u64,
    rate_decimals: u8,
): u64 {
    assert!(rate > 0, EDivisionByZero);
    
    let multiplier = pow(10, rate_decimals);
    
    // Check for multiplication overflow: output_value * multiplier <= u64::MAX
    let max_output = 18446744073709551615u64 / multiplier; // u64::MAX / multiplier
    assert!(output_value <= max_output, EArithmeticOverflow);
    
    (output_value * multiplier) / rate
}

// === Private Functions ===

/// Verifies that the owner capability matches the vault
fun assert_owner_cap_matches<InputCoin, OutputCoin>(
    vault: &Vault<InputCoin, OutputCoin>,
    owner_cap: &OwnerCap,
) {
    assert!(vault.id.to_inner() == owner_cap.vault_id, EWrongOwnerCap);
}

/// Verifies that the vault metadata belongs to this vault
fun assert_metadata_matches<InputCoin, OutputCoin>(
    vault: &Vault<InputCoin, OutputCoin>,
    vault_metadata: &VaultMetadata<InputCoin, OutputCoin>,
) {
    // Check if the treasury exists in this vault's dynamic object fields
    assert!(
        dof::exists_with_type<ID, TreasuryCap<OutputCoin>>(&vault.id, vault_metadata.id.to_inner()),
        EInvalidMetadata
    );
}

// === Test Only Functions ===
#[test_only]
public fun take_vault_id<InputCoin, OutputCoin>(vault: &mut Vault<InputCoin, OutputCoin>): &mut UID {
    &mut vault.id
}

#[test_only]
public fun take_vault_metadata_id<InputCoin, OutputCoin>(vault_metadata: &VaultMetadata<InputCoin, OutputCoin>): ID {
    vault_metadata.id.to_inner()
}

#[test_only]
public fun create_owner_cap_for_testing(ctx: &mut TxContext) {
    let owner_cap = OwnerCap {
        id: object::new(ctx),
        vault_id: object::last_created(ctx),
    };
    transfer::public_transfer(owner_cap, ctx.sender())
}