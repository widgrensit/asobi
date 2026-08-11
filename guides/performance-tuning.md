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
and sends that one binary to every connected session. At 200 players and 10
ticks/sec that is 10 encodes/sec instead of 2000.

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

Bot fill works under either strategy and does not cost the shared path its
encode: the one encode per tick is for the connected sessions, and each bot
is handed the state as a term instead of the frame, so no bot decodes JSON.
What you give up under `"shared"` is per-player filtering, for bots as much as
for clients - `think` sees exactly what a client sees. See
[Lua bots](lua-bots.md#what-a-bot-script-gets).

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

The one exception is a zone that has not finished its previous tick: it is
skipped rather than sent another one, so `tick_rate` is a ceiling on how often
a zone ticks, not a promise. A zone consistently missing ticks is a zone whose
`zone_tick` is over budget, and `[asobi, zone, tick_skipped]` counts it.

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

## Lua memory

Luerl never collects a long-lived Lua state on its own. Every tick, asobi
encodes the zone's entities into that state as fresh Lua tables, and nothing
in Luerl reclaims them - so an occupied zone's Lua heap grows for as long as
anyone is in it. Because each Lua callback runs in a spawned worker, the whole
state is copied into that worker and back on every tick, and the cost of a tick
therefore grows with everything the zone has ever encoded. Left alone, a busy
zone eventually takes longer to tick than the tick rate, at which point the
world ticker starts skipping it (see [Observability](observability.md) for the
`[asobi, zone, tick_skipped]` counter).

asobi collects each Lua state periodically to keep that flat. The interval is
not fixed: Luerl's collector walks the whole live set with a cost that grows
faster than linearly, so asobi times each collection and adapts. A zone holding
little across ticks gets collected often, which keeps both the collection and
the per-tick copies cheap. A zone holding a large table across ticks gets
collected rarely, because each collection is expensive and reclaims the same
per-tick garbage either way.

That gives you one thing worth designing around: **what a script keeps alive
between callbacks is more expensive than what it allocates inside one.** A
`game_state` holding a table of ten thousand rows is paid for on every
collection; the same rows rebuilt per tick and dropped are not. If a
collection ever runs longer than a tick budget, asobi logs
`lua_gc_abandoned` and stops collecting that state rather than freezing the
zone for seconds at a time - Lua memory there will then grow unbounded, and
the fix is to keep less alive across callbacks.

Set `{asobi, [{lua_gc, false}]}` to turn the collector off entirely. There is
no reason to do this outside diagnosing a problem with the collector itself.

## Checkpoint

1. In a match where everyone shares one view, set `state_strategy = "shared"`
   and a one-argument `get_state(state)`. With 100+ players connected, encodes
   per tick drop from once-per-player to once total.
2. Leave a zone with no subscribers and no NPCs. Its process memory falls at
   the next tick (hibernation), and it stops entirely at the next sweep once
   it holds no entities at all.
3. Play in a Lua zone for a few minutes and watch its process memory. It should
   settle rather than climb. If it climbs, check the logs for
   `lua_gc_abandoned`.

## Next

[Large worlds](large-worlds.md) - the zone lifecycle and terrain providers
these costs sit on top of.
