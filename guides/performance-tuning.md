# Performance tuning

What costs CPU in a busy world or match server, and what you can actually
change about it.

Everything here is game logic. It is the same whether you run the image and
write Lua or depend on the Hex package and write Erlang.

## Spatial queries

Spatial queries scan every entity in the zone. There is no index: the zone
falls back to a linear scan on every query, always. Budget for O(n) per query
and keep zone populations small enough that it does not matter.

Query from Lua through the `game.spatial` namespace:

```lua
-- inside zone_tick or handle_input, where the zone is in scope
local hits = game.spatial.query_radius(100, 200, 50)
```

In Erlang:

```erlang
Results = asobi_zone:query_radius(ZonePid, {100.0, 200.0}, 50.0).
```

Two forms read the zone and so need a zone in scope:

- `query_radius(x, y, radius)`
- `query_rect(x1, y1, x2, y2)`

The rest take their data as arguments and work anywhere:

- `query_radius(entities, x, y, radius[, opts])` and
  `nearest(entities, x, y, n[, opts])` take a table of entities.
- `in_range(entity_a, entity_b, range)` and `distance(entity_a, entity_b)` take
  two entities, not a list. There is no entity-list form of either.

`query_rect` has no entity-list form: it is zone-only.

## Broadcast batching

Zone deltas are JSON-encoded once per tick and the pre-encoded binary is sent
to every subscriber, replacing N `json:encode` calls with one. This is
automatic. Subscribers receive `zone_delta_raw` messages that the WebSocket
handler forwards without re-encoding.

## Match state: shared or per player

By default the match server calls `get_state(player_id, state)` once per player
per tick and encodes each result separately. For games where every player sees
the same world (free-for-all shooters, racing, party games), opt into a single
shared encode: the server calls the state function once per tick, encodes once,
and broadcasts the same binary to everyone. At 200 players and 10 ticks/sec
that is 10 encodes/sec instead of 2000.

Opt in from your match script by declaring `state_strategy = "shared"` and
defining a one-argument state function. Games that need per-player filtering
(fog of war, a hidden hand) keep the two-argument form and pay the per-player
cost.

```lua
-- match.lua
match_size     = 4
state_strategy = "shared"

function get_state(state)
    return state
end
```

A shared script is routed through `asobi_lua_match_shared`, which exports
`get_state/1`.

Lua bots do not work in a shared-state mode: they receive the pre-encoded
broadcast and cannot decode it, so `think` is called with an empty table and
never sees the match. Keep the two-argument form in any mode you fill with bots
- see [Lua bots](lua-bots.md#what-a-bot-script-gets).

In Erlang, export exactly one of `get_state/1` or `get_state/2`; the match
server detects which is exported and switches broadcast strategy accordingly.

```erlang
-callback get_state(GameState) -> SharedState.
```

For multi-mode games, declare `state_strategy` in the mode's config rather than
in a shared file - see [Configuration](configuration.md).

## Zone tick, hibernation and reaping

Every active zone in a world ticks at the world's `tick_rate`. There is no hot
and cold split and nothing promotes or demotes a zone; if the zone is active,
it ticks.

What does happen automatically:

- A zone whose subscribers have dropped to zero **and** which holds no NPC
  entities goes into BEAM hibernation on its next tick, collapsing its heap.
  NPCs are the only entity type that keeps a zone awake.
- The zone manager sweeps every 10s. A zone becomes eligible either the moment
  its last occupant leaves, or after 30s without a touch. It is then *asked* to
  stop: a zone still holding entities declines and re-touches its own timer, so
  only an empty zone actually goes away. A join or crossing that finds its zone
  reaped starts a replacement transparently.

Both of those are fixed in the deployment. See
[Large worlds](large-worlds.md#zone-lifecycle) for what that means for a big
map.

## Checkpoint

1. In a match where everyone shares one view, set `state_strategy = "shared"`
   and a one-argument `get_state(state)`. With 100+ players connected, encodes
   per tick drop from once-per-player to once total.
2. Leave a zone with no subscribers and no NPCs. Its process memory falls at
   the next tick (hibernation), and it stops entirely at the next sweep once
   it holds no entities at all.

## Next

[Large worlds](large-worlds.md) - the zone lifecycle and terrain providers
these costs sit on top of.
