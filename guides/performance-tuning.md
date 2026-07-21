# Performance Tuning

Optimisation features for high-throughput world and match servers. All are
opt-in and backward compatible; existing configurations work unchanged.

Every feature here is game config or logic. It is identical on managed Cloud
(`asobi deploy`, console.asobi.dev) and on a self-hosted release - the same
script, the same globals. Only the base server URL your client SDK points at
differs, and that is covered in [Getting Started](getting-started.md).

## Spatial Grid Index

By default, spatial queries scan all entities in a zone (O(n)). For zones with
many entities, enable the cell-based spatial grid for O(1) cell lookup plus a
local scan. Set the cell size as a global in your world script.

<!-- tabs -->
**Lua**
```lua
-- world.lua
game_type              = "world"
spatial_grid_cell_size = 16
```

**Erlang**
```erlang
Config = #{
    game_module => my_world,
    spatial_grid_cell_size => 16
}.
```
<!-- /tabs -->

The grid is maintained automatically as entities are added, removed, or moved
during ticks. Query it through the `game.spatial` namespace:

<!-- tabs -->
**Lua**
```lua
-- inside zone_tick or handle_input, where the zone is in scope
local hits = game.spatial.query_radius(100, 200, 50)
```

**Erlang**
```erlang
Results = asobi_zone:query_radius(ZonePid, {100.0, 200.0}, 50.0).
```
<!-- /tabs -->

`game.spatial` also offers `query_rect`, `nearest`, `in_range` and `distance`.
Only `query_radius` and `query_rect` have zone-based forms and need a zone in
scope; `nearest`, `in_range` and `distance` are entity-list forms
(`game.spatial.query_radius(entities, x, y, radius)`) and work anywhere.

When no `spatial_grid_cell_size` is configured, the zone falls back to the
brute-force scan.

### Cell Size Guidelines

| Entity Density | Recommended Cell Size |
|---------------|----------------------|
| Sparse (< 50/zone) | Do not enable (overhead not worth it) |
| Medium (50-200/zone) | 32-64 units |
| Dense (200+/zone) | 8-16 units |

## Broadcast Batching

Zone deltas are JSON-encoded once and the pre-encoded binary is sent to all
subscribers, replacing N `json:encode` calls with exactly 1. This is automatic;
no configuration needed. Subscribers receive `zone_delta_raw` messages that the
WebSocket handler forwards without re-encoding.

## Match State Broadcast (Shared vs Per-Player)

By default the match server calls `get_state(player_id, state)` once per player
per tick and JSON-encodes each result. For games where every player sees the
same world (FFA shooters, racing, party games), opt into a single shared encode:
the server calls the state function once per tick, encodes once, and broadcasts
the same binary to everyone. At 200 players and 10 ticks/sec this drops 2000
encodes/sec to 10.

Opt in from your match script by declaring `state_strategy = "shared"` and
defining a one-arg state function. Games that need per-player filtering (fog of
war, hidden hand) keep the two-arg form and pay the per-player cost.

<!-- tabs -->
**Lua**
```lua
-- match.lua
state_strategy = "shared"

function get_state(state)
    return state
end
```

**Erlang**
```erlang
-callback get_state(GameState) -> SharedState.
```
<!-- /tabs -->

The asobi_lua bridge routes a shared script through `asobi_lua_match_shared`,
which exports `get_state/1`. In Erlang, export exactly one of `get_state/1` or
`get_state/2`; the match server detects which and switches broadcast strategy.
For multi-mode games, declare `state_strategy` in the mode's config, not in a
shared file - see [Configuration](configuration.md).

## Adaptive Tick Rates

Zones with no subscribers tick at a reduced rate to save CPU. Set the divisor as
a global.

<!-- tabs -->
**Lua**
```lua
-- world.lua
cold_tick_divisor = 10
```

**Erlang**
```erlang
Config = #{cold_tick_divisor => 10}.
```
<!-- /tabs -->

| Zone State | Tick Rate | When |
|-----------|-----------|------|
| Hot | Full (every tick) | Has subscribers |
| Cold | 1/N (every Nth tick) | Entities but no subscribers |
| Empty | Not ticked | No entities, no subscribers |

Promotion and demotion between hot and cold are handled automatically by the
zone manager based on subscriber presence, so a game script never manages tick
state directly.

## Binary Protocol

For maximum throughput, a client can negotiate binary WebSocket frames instead
of JSON. This is a client-side choice, identical on Cloud and self-hosted: set
`binary_protocol: true` in the `session.connect` payload. JSON remains the
default; binary is opt-in per connection.

Binary frames use a Tag-Length-Value format:

```
[type:u8][length:u32be][payload:bytes]
```

| Tag | Type | Payload |
|-----|------|---------|
| 0x01 | Terrain chunk | coords (2x i32) + compressed data |
| 0x02 | Entity deltas | tick (u64) + counted delta list |
| 0x03 | Match state | Reserved |

Terrain chunks save ~25% versus JSON+base64; entity deltas save 15-30% depending
on field count. Frame encoding and decoding is handled by the server and SDKs -
see the [WebSocket protocol](websocket-protocol.md) guide.

## Checkpoint

1. Add `spatial_grid_cell_size = 16` to a busy `world.lua`, redeploy (Cloud:
   `asobi deploy`; self-hosted: your release), and call
   `game.spatial.query_radius(x, y, r)` from `zone_tick`. It returns the same
   hits as before, now backed by the grid rather than a full scan.
2. In a match where everyone shares one view, set `state_strategy = "shared"`
   and a one-arg `get_state(state)`. With 100+ players connected, server encode
   count per tick should drop from once-per-player to once total.
3. Leave a zone with no subscribers. Confirm it ticks at roughly
   `1 / cold_tick_divisor` of the hot rate, and that an empty zone stops ticking
   entirely.

## Next

[Large Worlds](large-worlds.md) - lazy zone loading, terrain providers, and the
zone lifecycle these tuning knobs sit on top of.
