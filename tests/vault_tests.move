#[test_only]
module vault::vault_tests;

use sui::coin::{Self, Coin, TreasuryCap};
use sui::test_scenario::{Self as test, next_tx, ctx, Scenario};
use vault::vault::{Self, Vault, VaultMetadata, OwnerCap, EInvalidRate, EWrongOwnerCap, EInsufficientReserves, EArithmeticOverflow, EDivisionByZero};

// === Test Coin Types ===
public struct INPUT_COIN has drop {}
public struct OUTPUT_COIN has drop {}

// === Test Constants ===
const ADMIN: address = @0x1;
const USER: address = @0x2;
const RATE: u64 = 200000000;

// === Test Only Functions ===

#[test_only]
fun setup(mut scenario: Scenario): Scenario {
    next_tx(&mut scenario, ADMIN);
    {
        let input_treasury = coin::create_treasury_cap_for_testing<INPUT_COIN>(scenario.ctx());
        let output_treasury = coin::create_treasury_cap_for_testing<OUTPUT_COIN>(scenario.ctx());

        vault::create_vault<INPUT_COIN, OUTPUT_COIN>(
            RATE,
            output_treasury,
            9,
            b"VAULT",
            b"Test Vault",
            b"A test vault for swapping coins",
            option::none(),
            scenario.ctx(),
        );

        transfer::public_transfer(input_treasury, ADMIN);
    };

    // Mint input coins for the user
    next_tx(&mut scenario, ADMIN);
    {
        let mut input_treasury = test::take_from_sender<TreasuryCap<INPUT_COIN>>(&scenario);
        let input_coin = input_treasury.mint(100000000, scenario.ctx());
        transfer::public_transfer(input_coin, USER);
        test::return_to_sender(&scenario, input_treasury);
    };
    scenario
}

#[test_only]
fun take_vault_objects(
    scenario: &Scenario,
): (Vault<INPUT_COIN, OUTPUT_COIN>, VaultMetadata<INPUT_COIN, OUTPUT_COIN>) {
    (
        test::take_shared<Vault<INPUT_COIN, OUTPUT_COIN>>(scenario),
        test::take_immutable<VaultMetadata<INPUT_COIN, OUTPUT_COIN>>(
            scenario,
        ),
    )
}

#[test_only]
fun mint_input_coins_for_user(scenario: &mut Scenario, recipient: address, amount: u64) {
    next_tx(scenario, ADMIN);
    {
        let mut input_treasury = test::take_from_sender<TreasuryCap<INPUT_COIN>>(scenario);
        let input_coin = input_treasury.mint(amount, scenario.ctx());
        transfer::public_transfer(input_coin, recipient);
        test::return_to_sender(scenario, input_treasury);
    };
}

#[test_only]
fun deposit_coins_to_vault(scenario: &mut Scenario) {
    next_tx(scenario, ADMIN);
    {
        let (mut vault, vault_metadata) = take_vault_objects(scenario);
        let owner_cap = test::take_from_sender<OwnerCap>(scenario);
        let input_coin = test::take_from_sender<Coin<INPUT_COIN>>(scenario);
        vault::deposit(&owner_cap, &mut vault, input_coin);
        test::return_immutable(vault_metadata);
        test::return_shared(vault);
        test::return_to_sender(scenario, owner_cap);
    };
}

#[test_only]
fun mint_output_coins(scenario: &mut Scenario, user: address): Coin<OUTPUT_COIN> {
    next_tx(scenario, user);
    let (mut vault, vault_metadata) = take_vault_objects(scenario);
    let input_coin = test::take_from_sender<Coin<INPUT_COIN>>(scenario);
    let output_coin = vault::mint(&mut vault, &vault_metadata, input_coin, ctx(scenario));
    test::return_immutable(vault_metadata);
    test::return_shared(vault);
    output_coin
}

// ==========================
// === Test Functionality ===
// ==========================

// === Owner Functions ===

#[test]
fun test_create_vault_functionality() {
    let mut scenario = setup(test::begin(ADMIN));

    // Verify vault was created
    next_tx(&mut scenario, ADMIN);
    {
        let vault = test::take_shared<Vault<INPUT_COIN, OUTPUT_COIN>>(&scenario);
        let owner_cap = test::take_from_sender<OwnerCap>(&scenario);

        assert!(vault::rate(&vault) == RATE, 0);
        assert!(vault::reserve_value(&vault) == 0, 1);
        assert!(vault::is_valid_owner_cap(&vault, &owner_cap), 2);

        test::return_shared(vault);
        test::return_to_sender(&scenario, owner_cap);
    };

    test::end(scenario);
}

#[test]
fun test_deposit_functionality() {
    let mut scenario = setup(test::begin(ADMIN));

    // Mint input coins for ADMIN
    mint_input_coins_for_user(&mut scenario, ADMIN, 100000000);

    // Test depositing
    next_tx(&mut scenario, ADMIN);
    {
        let (mut vault, vault_metadata) = take_vault_objects(&scenario);
        let owner_cap = test::take_from_sender<OwnerCap>(&scenario);
        let input_coin = test::take_from_sender<Coin<INPUT_COIN>>(&scenario);
        vault::deposit(&owner_cap, &mut vault, input_coin);
        assert!(vault::reserve_value(&vault) == 100000000, 0);
        test::return_immutable(vault_metadata);
        test::return_shared(vault);
        test::return_to_sender(&scenario, owner_cap);
    };
    test::end(scenario);
}

#[test]
fun test_withdraw_functionality() {
    let mut scenario = setup(test::begin(ADMIN));

    // Mint input coins and deposit to vault
    mint_input_coins_for_user(&mut scenario, ADMIN, 100000000);
    deposit_coins_to_vault(&mut scenario);

    // Test withdrawing
    next_tx(&mut scenario, ADMIN);
    {
        let (mut vault, vault_metadata) = take_vault_objects(&scenario);
        let owner_cap = test::take_from_sender<OwnerCap>(&scenario);
        let input_coin = vault::withdraw(&owner_cap, &mut vault, 100000000, ctx(&mut scenario));
        assert!(vault::reserve_value(&vault) == 0, 0);
        assert!(input_coin.value() == 100000000, 1);
        transfer::public_transfer(input_coin, ADMIN);
        test::return_immutable(vault_metadata);
        test::return_shared(vault);
        test::return_to_sender(&scenario, owner_cap);
    };
    test::end(scenario);
}

// === User Functions ===

#[test]
fun test_mint_functionality() {
    let mut scenario = setup(test::begin(ADMIN));
    // Test minting
    mint_input_coins_for_user(&mut scenario, USER, 100000000);
    let output_coin = mint_output_coins(&mut scenario, USER);

    // Verify mint worked (rate = 0.2, so 100000000 input should give 20000000 output)
    assert!(coin::value(&output_coin) == 20000000, 0);
    
    // Check vault reserve after mint
    next_tx(&mut scenario, USER);
    {
        let (vault, vault_metadata) = take_vault_objects(&scenario);
        assert!(vault::reserve_value(&vault) == 100000000, 1);
        transfer::public_transfer(output_coin, USER);
        test::return_immutable(vault_metadata);
        test::return_shared(vault);
    };

    test::end(scenario);
}

#[test]
fun test_redeem_functionality() {
    let mut scenario = setup(test::begin(ADMIN));

    // Mint output coins for the user
    mint_input_coins_for_user(&mut scenario, USER, 100000000);
    let output_coin = mint_output_coins(&mut scenario, USER);
    transfer::public_transfer(output_coin, USER);

    // Test redeeming
    next_tx(&mut scenario, USER);
    {
        let (mut vault, vault_metadata) = take_vault_objects(&scenario);
        let output_coin = test::take_from_sender<Coin<OUTPUT_COIN>>(&scenario);
        let input_coin = vault::redeem(
            &mut vault,
            &vault_metadata,
            output_coin,
            ctx(&mut scenario),
        );
        // Verify redeem worked (rate = 0.2, so 20000000 output should give 100000000 input)
        assert!(coin::value(&input_coin) == 100000000, 0);
        assert!(vault::reserve_value(&vault) == 0, 1);

        transfer::public_transfer(input_coin, USER);
        test::return_immutable(vault_metadata);
        test::return_shared(vault);
    };

    test::end(scenario);
}

// === Calculation Tests ===

#[test]
fun test_output_amount_calculation() {
    let mut scenario = setup(test::begin(ADMIN));
    
    // Test different input amounts with known rate
    mint_input_coins_for_user(&mut scenario, USER, 1000000000); // 10^9
    let output_coin = mint_output_coins(&mut scenario, USER);
    
    // With rate=200000000 (0.2) and rate_decimals=9
    // Expected: 1000000000 * 0.2 = 200000000
    assert!(coin::value(&output_coin) == 200000000, 0);
    transfer::public_transfer(output_coin, USER);
    
    // Test small amounts
    mint_input_coins_for_user(&mut scenario, USER, 1000); 
    let output_coin2 = mint_output_coins(&mut scenario, USER);
    // Expected: 1000 * 200000000 / 1000000000 = 200
    assert!(coin::value(&output_coin2) == 200, 1);
    transfer::public_transfer(output_coin2, USER);
    
    test::end(scenario);
}

#[test]
fun test_input_amount_calculation() {
    let mut scenario = setup(test::begin(ADMIN));
    
    // Create reserves and mint output coins for redeem test
    mint_input_coins_for_user(&mut scenario, ADMIN, 1000000000);
    deposit_coins_to_vault(&mut scenario);
    
    mint_input_coins_for_user(&mut scenario, USER, 500000000);
    let output_coin = mint_output_coins(&mut scenario, USER);
    let output_value = coin::value(&output_coin);
    
    // Test redeeming - uses calculate_input_amount internally
    next_tx(&mut scenario, USER);
    {
        let (mut vault, vault_metadata) = take_vault_objects(&scenario);
        let input_coin = vault::redeem(&mut vault, &vault_metadata, output_coin, ctx(&mut scenario));
        
        // Verify: output_value * 10^9 / 200000000 = input_value
        let expected_input = output_value * 1000000000 / 200000000;
        assert!(coin::value(&input_coin) == expected_input, 0);
        
        transfer::public_transfer(input_coin, USER);
        test::return_immutable(vault_metadata);
        test::return_shared(vault);
    };
    
    test::end(scenario);
}

#[test]
fun test_underflow_and_precision_loss() {
    let mut scenario = setup(test::begin(ADMIN));
    
    // Test with very small amounts that might cause precision loss
    mint_input_coins_for_user(&mut scenario, USER, 1); // Minimum possible amount
    let output_coin = mint_output_coins(&mut scenario, USER);
    
    // With rate=200000000 (0.2), input=1
    // Expected: 1 * 200000000 / 1000000000 = 0 (due to integer division)
    assert!(coin::value(&output_coin) == 0, 0);
    transfer::public_transfer(output_coin, USER);
    
    // Test with amount that gives fractional result but rounds down
    mint_input_coins_for_user(&mut scenario, USER, 3); 
    let output_coin2 = mint_output_coins(&mut scenario, USER);
    // Expected: 3 * 200000000 / 1000000000 = 0 (rounds down)
    assert!(coin::value(&output_coin2) == 0, 1);
    transfer::public_transfer(output_coin2, USER);
    
    // Test minimum amount that gives non-zero result
    mint_input_coins_for_user(&mut scenario, USER, 5); 
    let output_coin3 = mint_output_coins(&mut scenario, USER);
    // Expected: 5 * 200000000 / 1000000000 = 1
    assert!(coin::value(&output_coin3) == 1, 2);
    transfer::public_transfer(output_coin3, USER);
    
    test::end(scenario);
}

#[test]
fun test_edge_cases_zero_values() {
    let mut scenario = setup(test::begin(ADMIN));
    
    // Test with zero input (should create zero output)
    mint_input_coins_for_user(&mut scenario, USER, 0);
    let output_coin = mint_output_coins(&mut scenario, USER);
    assert!(coin::value(&output_coin) == 0, 0);
    transfer::public_transfer(output_coin, USER);
    
    test::end(scenario);
}

#[test]
fun test_different_rate_decimals() {
    // Test with different rate_decimals values
    let mut scenario = test::begin(ADMIN);
    next_tx(&mut scenario, ADMIN);
    {
        let input_treasury = coin::create_treasury_cap_for_testing<INPUT_COIN>(scenario.ctx());
        let output_treasury = coin::create_treasury_cap_for_testing<OUTPUT_COIN>(scenario.ctx());
        
        // Create vault with rate_decimals = 6 instead of 9
        vault::create_vault<INPUT_COIN, OUTPUT_COIN>(
            2000000, // Rate = 2.0 with 6 decimals
            output_treasury,
            6,
            b"DECVAULT",
            b"Decimal Test Vault",
            b"Testing different decimal places",
            option::none(),
            scenario.ctx(),
        );
        
        transfer::public_transfer(input_treasury, ADMIN);
    };
    
    // Test minting with this vault
    mint_input_coins_for_user(&mut scenario, USER, 1000000); // 10^6
    next_tx(&mut scenario, USER);
    {
        let (mut vault, vault_metadata) = take_vault_objects(&scenario);
        let input_coin = test::take_from_sender<Coin<INPUT_COIN>>(&scenario);
        
        let output_coin = vault::mint(&mut vault, &vault_metadata, input_coin, ctx(&mut scenario));
        // With rate=2000000 (2.0) and rate_decimals=6, input=1000000
        // Expected: 1000000 * 2000000 / 1000000 = 2000000
        assert!(coin::value(&output_coin) == 2000000, 0);
        
        transfer::public_transfer(output_coin, USER);
        test::return_immutable(vault_metadata);
        test::return_shared(vault);
    };
    
    test::end(scenario);
}


// === Test Failure Scenarios ===

#[test, expected_failure(abort_code = EInvalidRate)]
fun test_create_vault_zero_rate_fails() {
    let mut scenario = test::begin(ADMIN);

    next_tx(&mut scenario, ADMIN);
    {
        let input_treasury = coin::create_treasury_cap_for_testing<INPUT_COIN>(scenario.ctx());

        let output_treasury = coin::create_treasury_cap_for_testing<OUTPUT_COIN>(scenario.ctx());

        // This should fail with EInvalidRate
        vault::create_vault<INPUT_COIN, OUTPUT_COIN>(
            0, // Invalid rate
            output_treasury,
            18,
            b"VAULT",
            b"Test Vault",
            b"A test vault for swapping coins",
            option::none(),
            scenario.ctx(),
        );

        transfer::public_transfer(input_treasury, ADMIN);
    };

    test::end(scenario);
}

#[test, expected_failure(abort_code = EWrongOwnerCap)]
fun test_wrong_owner_cap_fails() {
    let mut scenario = setup(test::begin(ADMIN));

    // Create a fake owner cap with wrong vault_id
    next_tx(&mut scenario, ADMIN);
    {
        vault::create_owner_cap_for_testing(scenario.ctx());
    };

    // Mint input coins for deposit
    mint_input_coins_for_user(&mut scenario, ADMIN, 100000000);

    // Try to deposit using the fake owner cap (should fail)
    next_tx(&mut scenario, ADMIN);
    {
        let (mut vault, vault_metadata) = take_vault_objects(&scenario);
        let fake_owner_cap = test::take_from_sender<OwnerCap>(&scenario);
        let input_coin = test::take_from_sender<Coin<INPUT_COIN>>(&scenario);
        
        // This should fail with EWrongOwnerCap because fake_owner_cap has wrong vault_id
        vault::deposit(&fake_owner_cap, &mut vault, input_coin);
        
        test::return_immutable(vault_metadata);
        test::return_shared(vault);
        test::return_to_sender(&scenario, fake_owner_cap);
    };

    test::end(scenario);
}

#[test, expected_failure(abort_code = EInsufficientReserves)]
fun test_insufficient_reserves_fails() {
    let mut scenario = setup(test::begin(ADMIN));

    // Mint input coins for deposit
    mint_input_coins_for_user(&mut scenario, ADMIN, 100000000);

    // Deposit coins to vault
    deposit_coins_to_vault(&mut scenario);

    // Try to withdraw more than the vault has (should fail)
    next_tx(&mut scenario, ADMIN);
    {
        let (mut vault, vault_metadata) = take_vault_objects(&scenario);
        let owner_cap = test::take_from_sender<OwnerCap>(&scenario);
        let input_coin = vault::withdraw(&owner_cap, &mut vault, 100000001, ctx(&mut scenario));
        transfer::public_transfer(input_coin, ADMIN);
        test::return_immutable(vault_metadata);
        test::return_shared(vault);
        test::return_to_sender(&scenario, owner_cap);
    };

    test::end(scenario);
}

#[test, expected_failure(abort_code = EArithmeticOverflow)]
fun test_overflow_protection_mint_fails() {
    let mut scenario = setup(test::begin(ADMIN));
    
    // Create vault with maximum rate to trigger balance overflow during mint
    next_tx(&mut scenario, ADMIN);
    {
        let input_treasury = coin::create_treasury_cap_for_testing<INPUT_COIN>(scenario.ctx());
        let output_treasury = coin::create_treasury_cap_for_testing<OUTPUT_COIN>(scenario.ctx());
        
        vault::create_vault<INPUT_COIN, OUTPUT_COIN>(
            18446744073709551615u64, // u64::MAX rate
            output_treasury,
            0, // No decimals to maximize mint amount
            b"OVERFLOW",
            b"Overflow Test Vault",
            b"Security test vault",
            option::none(),
            scenario.ctx(),
        );
        
        transfer::public_transfer(input_treasury, ADMIN);
    };
    
    // Attempt mint with large amount that causes balance overflow - MUST FAIL
    mint_input_coins_for_user(&mut scenario, USER, 10000000000u64);
    next_tx(&mut scenario, USER);
    {
        let (mut vault, vault_metadata) = take_vault_objects(&scenario);
        let input_coin = test::take_from_sender<Coin<INPUT_COIN>>(&scenario);
        
        // This MUST fail with EArithmeticOverflow when result > u64::MAX
        let output_coin = vault::mint(&mut vault, &vault_metadata, input_coin, ctx(&mut scenario));
        
        transfer::public_transfer(output_coin, USER);
        test::return_immutable(vault_metadata);
        test::return_shared(vault);
    };
    
    test::end(scenario);
}

#[test, expected_failure(abort_code = EArithmeticOverflow)]
fun test_overflow_protection_redeem_fails() {
    // Direct test of safe calculation function with overflow values
    let rate = 1000000000u64; // 1 billion
    let output_value = 1000000000000000000u64; // Values that cause u64 overflow
    let rate_decimals = 18u8; // 10^18 multiplier causes overflow
    
    // This MUST fail with EArithmeticOverflow when result > u64::MAX
    vault::calculate_input_amount_safe(rate, output_value, rate_decimals);
}

#[test, expected_failure(abort_code = EDivisionByZero)]
fun test_division_by_zero_protection_fails() {
    // Test safe calculation functions prevent division by zero
    let rate = 0u64; // Zero rate
    let input_value = 100u64;
    let rate_decimals = 9u8;
    
    // This MUST fail with EDivisionByZero - critical protection
    vault::calculate_output_amount_safe(rate, input_value, rate_decimals);
}


