# Riva Tokenized Vaults — Move Package

Type-safe Move module that implements a fixed-rate tokenized vault with reserves in `InputCoin` and mint/burn of `OutputCoin`. The module exposes entry functions for vault creation, mint/redeem, and owner operations, with comprehensive overflow and invariant checks.

## Module

- Module: `vault::vault`
- Type parameters: `InputCoin`, `OutputCoin`

## Core Types

- `struct Vault<phantom InputCoin, phantom OutputCoin> has key, store`
  - `id: UID`
  - `rate: u64` — exchange multiplier
  - `reserve: Balance<InputCoin>` — input reserves
  - `rate_decimals: u8` — precision for `rate`

- `struct VaultMetadata<phantom InputCoin, phantom OutputCoin> has key, store`
  - `id: UID`
  - `name: string::String`
  - `symbol: ascii::String`
  - `description: string::String`
  - `icon_url: Option<Url>`

- `struct OwnerCap has key, store`
  - `id: UID`
  - `vault_id: ID`

## Public Entry Functions

- `create_vault<InputCoin, OutputCoin>(rate: u64, output_coin_treasury: TreasuryCap<OutputCoin>, rate_decimals: u8, symbol: vector<u8>, name: vector<u8>, description: vector<u8>, icon_url: Option<Url>, ctx: &mut TxContext)`
  - Creates and shares the `Vault`, creates and freezes `VaultMetadata`, links `TreasuryCap<OutputCoin>` via dynamic fields, transfers `OwnerCap` to sender.

- `deposit<InputCoin, OutputCoin>(owner_cap: &OwnerCap, vault: &mut Vault<...>, amount: Coin<InputCoin>)`
  - Owner-only; joins `amount` into `reserve`.

- `withdraw<InputCoin, OutputCoin>(owner_cap: &OwnerCap, vault: &mut Vault<...>, amount: u64, ctx: &mut TxContext): Coin<InputCoin>`
  - Owner-only; splits `reserve` and returns input coins.

- `set_rate<InputCoin, OutputCoin>(owner_cap: &OwnerCap, vault: &mut Vault<...>, rate: u64)`
  - Owner-only; updates `rate` (must be > 0).

- `mint<InputCoin, OutputCoin>(vault: &mut Vault<...>, vault_metadata: &VaultMetadata<...>, input_coin: Coin<InputCoin>, ctx: &mut TxContext): Coin<OutputCoin>`
  - Checks metadata binding, computes output via safe math, adds input to `reserve`, mints `OutputCoin` via linked `TreasuryCap`.

- `redeem<InputCoin, OutputCoin>(vault: &mut Vault<...>, vault_metadata: &VaultMetadata<...>, output_coin: Coin<OutputCoin>, ctx: &mut TxContext): Coin<InputCoin>`
  - Checks metadata binding, computes input via safe math, burns `output_coin` via linked `TreasuryCap`, returns input from `reserve`.

### Views

- `rate(vault): u64`
- `reserve_value(vault): u64`
- `is_valid_owner_cap(vault, owner_cap): bool`

### Package-internal Safe Math

- `calculate_output_amount_safe(rate: u64, input_value: u64, rate_decimals: u8): u64`
- `calculate_input_amount_safe(rate: u64, output_value: u64, rate_decimals: u8): u64`

Both functions guard against division by zero and u64 overflow.

## Error Codes

- `EWrongOwnerCap = 1`
- `EInsufficientReserves = 2`
- `EInvalidRate = 3`
- `EInvalidMetadata = 4`
- `EArithmeticOverflow = 5`
- `EDivisionByZero = 6`

## Testing

Unit tests under `tests/vault_tests.move` cover:
- Creation, deposit, withdraw, mint, redeem
- Failure paths: invalid rate, wrong owner cap, insufficient reserves, arithmetic overflow, division by zero
- Calculation correctness for varying precisions and edge cases

Run tests:
```bash
sui move test
```

## CLI Examples

Create a vault (example; replace types/ids as needed):
```bash
sui client call \
  --package <PACKAGE_ID> \
  --module vault \
  --function create_vault \
  --type-args <INPUT_COIN_TYPE> <OUTPUT_COIN_TYPE> \
  --args <RATE:u64> <OUTPUT_TREASURY_CAP:ObjectID> <RATE_DECIMALS:u8> \
         "$(printf 'VAULT' | xxd -p -c 256)" \
         "$(printf 'My Vault' | xxd -p -c 256)" \
         "$(printf 'Fixed-rate tokenized vault' | xxd -p -c 256)" \
         none
```

Mint:
```bash
sui client call \
  --package <PACKAGE_ID> \
  --module vault \
  --function mint \
  --type-args <INPUT_COIN_TYPE> <OUTPUT_COIN_TYPE> \
  --args <VAULT:ObjectID> <VAULT_METADATA:ObjectID> <INPUT_COIN:ObjectID>
```

Redeem:
```bash
sui client call \
  --package <PACKAGE_ID> \
  --module vault \
  --function redeem \
  --type-args <INPUT_COIN_TYPE> <OUTPUT_COIN_TYPE> \
  --args <VAULT:ObjectID> <VAULT_METADATA:ObjectID> <OUTPUT_COIN:ObjectID>
```

Owner operations (`deposit`, `withdraw`, `set_rate`) require `OwnerCap` that matches the vault id.
