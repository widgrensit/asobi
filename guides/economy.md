# Economy

Wallets, transactions, item definitions, a store catalogue and player
inventory.

Run the `curl` examples in Git Bash or WSL on Windows, or use PowerShell's
`Invoke-RestMethod` with the same URL and a JSON `-Body`. Authenticated calls
add `-Headers @{ Authorization = 'Bearer <token>' }`.

## Wallets

Each player can have one wallet per currency. Every balance change is recorded
as a transaction row, so the wallet's history is a full audit trail.

### List wallets

```bash
curl http://localhost:8084/api/v1/wallets \
  -H 'Authorization: Bearer <token>'
```

```json
{
  "wallets": [
    {"currency": "gold", "balance": 1000},
    {"currency": "gems", "balance": 50}
  ]
}
```

The response is an object, and each entry carries `currency` and `balance`
only - the wallet's `id` is stripped on the way out and no route accepts one.

### In Lua

`game.economy.*` calls return the wrapped envelope: a table with either an `ok`
field or an `error` field. `balance` never returns a number, so comparing its
result numerically silently misbehaves.

```lua
local result = game.economy.balance(player_id)
if result.error then
  game.log("warning", "balance lookup failed", { reason = result.error })
  return state
end

local gold = 0
for _, wallet in ipairs(result.ok) do
  if wallet.currency == "gold" then gold = wallet.balance end
end
```

`grant`, `debit` and `purchase` use the same envelope. See
[The game.* API](lua-api.md) for the full list and the two return conventions.

```lua
game.economy.grant(player_id, "gold", 100, "match_reward")
game.economy.debit(player_id, "gold", 50, "respawn_fee")
game.economy.purchase(player_id, listing_id)
```

### In Erlang

```erlang
{ok, Wallet} = asobi_economy:get_or_create_wallet(PlayerId, ~"gold"),
{ok, _} = asobi_economy:grant(PlayerId, ~"gold", 100, #{reason => ~"match_reward"}),
{ok, _} = asobi_economy:debit(PlayerId, ~"gold", 50, #{reason => ~"respawn_fee"}).
```

`get_or_create_wallet/2` creates the wallet with balance 0 if it is missing.
`grant/4` and `debit/4` each run in one transaction holding the wallet lock
described under [Purchase](#purchase).

### Transaction history

```bash
curl 'http://localhost:8084/api/v1/wallets/gold/history?limit=100' \
  -H 'Authorization: Bearer <token>'
```

```json
{
  "transactions": [
    {
      "id": "...",
      "wallet_id": "...",
      "amount": -500,
      "balance_after": 500,
      "reason": "purchase",
      "reference_type": "store_listing",
      "reference_id": "...",
      "metadata": {},
      "inserted_at": "..."
    }
  ]
}
```

Newest first. `limit` defaults to 50 and is clamped to 1-200.

## Items

Items are defined once as `asobi_item_def` rows and granted to players as
`asobi_player_item` instances.

### Item definitions

An item definition is global and describes what an item is:

| Column | Meaning |
|---|---|
| `slug` | Unique identifier, e.g. `"sword_of_fire"` |
| `name` | Display name |
| `category` | Free-form, e.g. weapon, armour, consumable |
| `rarity` | One of `common`, `uncommon`, `rare`, `epic`, `legendary`. Defaults to `common` and is validated |
| `stackable` | A boolean, defaulting to `true` |
| `metadata` | Arbitrary JSON for game-specific attributes |

`stackable` is metadata for your game to interpret. Nothing in asobi reads it:
the purchase path always inserts a fresh `asobi_player_item` row with
`quantity` 1 and never merges into an existing stack, whatever `stackable`
says. If you want stacking, do it in your own grant path.

### Player inventory

```bash
curl 'http://localhost:8084/api/v1/inventory?limit=100' \
  -H 'Authorization: Bearer <token>'
```

```json
{
  "items": [
    {
      "id": "...",
      "item_def_id": "...",
      "player_id": "...",
      "quantity": 1,
      "metadata": {},
      "acquired_at": "...",
      "updated_at": "..."
    }
  ]
}
```

Newest acquisition first. `limit` defaults to 50 and is clamped to 1-200.

There is no Lua call for inventory. Read it over REST, or query
`asobi_player_item` from Erlang.

### Consuming items

```bash
curl -X POST http://localhost:8084/api/v1/inventory/consume \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -d '{"item_id": "...", "quantity": 1}'
```

```json
{"success": true, "remaining_quantity": 0}
```

Consuming the whole stack deletes the row. `quantity` must be a positive
integer no greater than 1,000,000.

## Store

The store is a catalogue of items purchasable with in-game currency.

### Browse the store

```bash
curl 'http://localhost:8084/api/v1/store?currency=gold' \
  -H 'Authorization: Bearer <token>'
```

```json
{
  "listings": [
    {
      "id": "...",
      "item_def_id": "...",
      "currency": "gold",
      "price": 500,
      "active": true,
      "valid_from": null,
      "valid_until": null,
      "metadata": {}
    }
  ]
}
```

Only `active` listings are returned. The optional `currency` parameter filters
to one currency.

`valid_from` and `valid_until` are columns on the listing and are returned, but
**asobi does not enforce the window**. A listing with a `valid_until` in the
past is still purchasable as long as `active` is true. Treat the two columns as
data for your own scheduling job to act on by flipping `active`.

### Purchase

`listing_id` is the store listing's **UUID**, the `id` from the browse
response. Listings have no slug, and no route accepts one.

```bash
curl -X POST http://localhost:8084/api/v1/store/purchase \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -d '{"listing_id": "0198c4f2-..."}'
```

```json
{
  "success": true,
  "item": {
    "id": "...",
    "item_def_id": "...",
    "player_id": "...",
    "quantity": 1,
    "metadata": {},
    "acquired_at": "...",
    "updated_at": "..."
  }
}
```

`item` is the inserted `player_items` row, not the item definition. Read
`item_def_id` to find out what it is.

<!-- tabs -->
**Lua**
```lua
local result = game.economy.purchase(player_id, listing_id)
if result.error then
  game.log("info", "purchase refused", { reason = result.error })
end
```
**Erlang**
```erlang
{ok, Item} = asobi_economy:purchase(PlayerId, ListingId).
```
<!-- /tabs -->

The debit and the item grant happen in **one database transaction**, serialised
by a Postgres advisory lock keyed on `(player_id, currency)`. Any concurrent
transaction touching the same wallet blocks until this one commits or rolls
back, which is what makes a double-spend impossible without rewriting the query
layer to use `SELECT ... FOR UPDATE`.

Items are granted through this path or by writing an `asobi_player_item` row
via `asobi_repo`. There is no `grant_item/3` helper.

## Error codes

| Status | Code | Meaning |
|---|---|---|
| `402` | `economy.insufficient_funds` | The wallet does not hold enough of this currency |
| `400` | `economy.listing_inactive` | The listing exists but `active` is false |
| `500` | `economy.purchase_failed` | The purchase could not be completed |
| `404` | `inventory.item_not_found` | No inventory item with this id |
| `403` | `forbidden` | The item exists but belongs to another player |
| `400` | `inventory.insufficient_quantity` | The stack holds fewer than the amount asked |
| `400` | `inventory.invalid_quantity` | `quantity` is missing, not a positive integer, or over the cap |

Every one arrives in the shared shape:

```json
{"error": {"code": "economy.insufficient_funds", "message": "...", "details": {}}}
```

## Inspecting the economy

The console has an Economy screen: the item catalogue, then the store listings
below it. It is the catalogue only - it reads, and it cannot
create a listing, grant an item or adjust a balance. Wallets and inventory are
not on that plane at all; query the `wallets`, `transactions` and
`player_items` tables directly for those. See
[Operator console](console.md).

## Next steps

- [Authentication](authentication.md) - player identity behind wallets and purchases.
- [In-app purchases](iap.md) - real-money receipts, which do not touch wallets on their own.
- [REST API](rest-api.md) - the wallet, store and inventory endpoints.
