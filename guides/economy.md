# Economy

Asobi provides a full virtual economy system: wallets, transactions, item
definitions, a store catalog, and player inventory.

## Wallets

Each player can have multiple wallets, one per currency. All balance changes
are recorded as transactions for a full audit trail.

### List Wallets

```bash
curl http://localhost:8080/api/v1/wallets \
  -H 'Authorization: Bearer <token>'
```

```json
[
  {"id": "...", "currency": "gold", "balance": 1000},
  {"id": "...", "currency": "gems", "balance": 50}
]
```

### Transaction History

```bash
curl http://localhost:8080/api/v1/wallets/gold/history \
  -H 'Authorization: Bearer <token>'
```

## Items

Items are defined once via `asobi_item_def` and granted to players as
`asobi_player_item` instances.

### Item Definitions

Item definitions are global -- they describe what an item is:

- `slug` -- unique identifier (e.g., `"sword_of_fire"`)
- `name` -- display name
- `category` -- weapon, armor, consumable, etc.
- `rarity` -- common, rare, epic, legendary
- `stackable` -- whether multiple instances stack into one slot
- `metadata` -- arbitrary JSON for game-specific attributes

### Player Inventory

```bash
curl http://localhost:8080/api/v1/inventory \
  -H 'Authorization: Bearer <token>'
```

### Consuming Items

```bash
curl -X POST http://localhost:8080/api/v1/inventory/consume \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -d '{"item_id": "...", "quantity": 1}'
```

## Store

The store is a catalog of items available for purchase with in-game currency.

### Browse Store

```bash
curl http://localhost:8080/api/v1/store \
  -H 'Authorization: Bearer <token>'
```

```json
[
  {
    "id": "...",
    "item_def_id": "...",
    "currency": "gold",
    "price": 500,
    "active": true
  }
]
```

### Purchase

Purchases are atomic: the wallet is debited and the item is granted in a
single database transaction via Kura Multi.

```bash
curl -X POST http://localhost:8080/api/v1/store/purchase \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -d '{"listing_id": "..."}'
```

## Server-Side Operations

For admin or game logic that needs to grant/debit currency or items
programmatically:

```erlang
%% Grant currency
asobi_economy:credit(PlayerId, ~"gold", 100, #{reason => match_reward}).

%% Debit currency
asobi_economy:debit(PlayerId, ~"gold", 50, #{reason => store_purchase}).

%% Grant item
asobi_economy:grant_item(PlayerId, ~"sword_of_fire", 1).
```

All economy operations use ACID transactions to prevent double-spending
or inconsistent state.
