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

Every active zone in a world ticks at the world's `tick_rate`, except in two
cases.

A zone that has not finished its previous tick is skipped rather than sent
another one, so `tick_rate` is a ceiling on how often a zone ticks, not a
promise. A zone consistently missing ticks is a zone whose `zone_tick` is over
budget, and `[asobi, zone, tick_skipped]` counts it.

A zone with **nothing to simulate** ticks once every `cold_tick_divisor` ticks
(default 10) instead of every tick. "Nothing to simulate" means no entities, no
queued input, no live entity timer and no pending respawn - subscribers
deliberately do not count, because a player watching an empty neighbouring zone
creates no work in it. The zone goes back to full rate on the message that
creates the work, not on its own next tick, so entering a zone costs no extra
latency.

This matters most on a Lua world, and the reason is in [Lua memory](#lua-memory)
below: an empty zone's tick is almost entirely the fixed per-callback cost of
the bridge rather than anything the game asked for. Measured on one machine, a
zone with no entities and an inert `zone_tick` costs about 2,400 reductions a
tick, of which roughly 90% is the bridge and most of that is the state copy. At
`tick_rate = 80` on a 225-zone grid that is the difference between a world
spending most of a core on empty space and spending a tenth of it.

Set `cold_tick_divisor = 1` if your game drives spawning from `zone_tick` on
zones that hold nothing - that is the one shape this changes, because such a
zone's `zone_tick` now runs at a tenth of the rate until something appears in
it.

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

That copy is the dominant cost of a Lua tick, and it is worth knowing what it
runs at: roughly 7 ms per MB of state. A callback that does nothing at all
measures 1.8 ms against a 0.4 MB state, 41 ms against 6 MB and 418 ms against
62 MB. A zone whose state reaches tens of MB is over its tick budget before
its script has run a single line.

A second, smaller fixed cost sits alongside it. With `reload_mode = auto`
(the default) each bridge polls its script's mtime so an edit reloads without a
restart. That poll is throttled to once per `reload_poll_interval_ms` (default
200) rather than once per tick: at 80 Hz across 225 zones the per-tick version
was 18,000 `stat()` calls a second to notice an edit made every few minutes.
Set it to 0 for the old per-tick behaviour, or `reload_mode = off` in a sealed
deployment where scripts never change under a running node.

**`lua_vm_mode = owned` removes that copy entirely** (ADR 0015). The state
moves into a process of its own, the bridge holds a handle, and every Luerl
operation becomes a small message to the process that owns it. The cost of a
callback stops tracking the size of the state:

| state | `copy` us/tick | `owned` us/tick |
|---|---|---|
| 0.1 MB | 151 | 16 |
| 3.2 MB | 3,733 | 18 |
| 15.7 MB | 20,385 | 16 |
| 62.6 MB | 111,444 | 19 |

Flat, not merely faster. Set it in `sys.config`:

```erlang
{asobi, [{lua_vm_mode, owned}]}
```

It is **off by default**, because the two modes differ in what a runaway
callback costs. Under `copy` the process killed on a timeout or heap overrun is
a throwaway holding a copy, so a bad callback costs one tick and the zone
carries on. Under `owned` the only killable thing is the process holding the
state, so an overrun kills the state: the zone dies with its VM and its
supervisor restarts it into the last snapshot. That is a better trade for a
large-state game and a worse one for a game whose scripts are unreliable and
whose state is small. `vm_max_heap_words` puts an absolute ceiling on the state
under `owned` - the first time that number can mean what it says, because the
capped process is the one holding it.

The win is smaller when the per-tick work itself grows with the state: a zone
holding 8,000 entities and encoding all of them every tick measured 1.4x, not
1,000x. `owned` removes a term that is O(state); it does not make encoding
cheaper.

asobi collects each Lua state periodically to keep that flat, immediately
before the tick's own callback so the copy is of the collected state. The
interval is not fixed: Luerl's collector walks the whole live set with a cost
that grows faster than linearly, so asobi times each collection and adapts.
What it compares that time against is the copy it saves, not a fixed ceiling -
a collection that shrinks a large state pays for itself many times over before
the next one, so a large state is collected often, and a state whose live set
is genuinely too expensive to walk is collected rarely.

That gives you one thing worth designing around: **what a script keeps alive
between callbacks is more expensive than what it allocates inside one.** A
`game_state` holding a table of ten thousand rows is paid for on every
collection; the same rows rebuilt per tick and dropped are not. If a
collection ever runs longer than a tick budget, asobi logs
`lua_gc_abandoned` and stops collecting that state rather than freezing the
zone for seconds at a time - Lua memory there will then grow unbounded, and
the fix is to keep less alive across callbacks.

`[asobi, lua, state]` reports the size of each Lua state as asobi measures it,
so this is visible before zones start dying of it; asobi also logs
`lua_state_large` once per state past ~100 MB. See
[Observability](observability.md).

Set `{asobi, [{lua_gc, false}]}` to turn the collector off entirely. There is
no reason to do this outside diagnosing a problem with the collector itself.

### Players in one zone

The entity map is encoded into Lua **once per tick**, not once per input. That
matters for any game where players cluster - a station, a battle, a spawn point
- because the alternative scales with the product of the two.

Measured on 2026-08-21, OTP 29.0.2 and luerl 1.5.1, 10 cores, on a zone holding
200 entities of 27 fields, applying one five-step input frame per player per
tick. One machine on one day, not a promise: measure your own game before you
size anything, the way [Benchmarks](benchmarks.md) says. The tick rate here is 12.5 Hz (`tick_rate =
80`), not the shipped default of 50 - the budget column says what each figure
costs against **the default 50 ms**:

| Players in the zone | Lua tables allocated per tick | Mean tick | Of a 50 ms budget |
|---|---|---|---|
| 1 | 386 | 16.0 ms | 32% |
| 8 | 435 | 16.6 ms | 33% |
| 32 | 603 | 17.3 ms | 35% |
| 64 | 827 | 19.3 ms | 39% |

The cost is dominated by entities: going from 1 player to 64 adds about seven
Lua tables per player and 21% to the tick, where the entity count sets
everything else. So the number to design around is how many entities a zone
holds, not how many players stand in it.

Before the entity map was hoisted out of the per-input path the same 64-player
row allocated 13,490 tables and took 439 ms, which is nearly nine times the
default budget and over five times an 80 ms one.

A game module can opt into the same shape from Erlang by exporting
`handle_input_batch/2` (see `asobi_world`); a module that does not gets
`handle_input/3` per input, unchanged.

Nothing about writing `handle_input` changes. Every input in a tick is handed
the same entity table rather than a fresh copy, but an empty or invalid return
still means "leave the entities alone" - asobi reverts the Lua state the call
produced, which reverts the mutation with it. So this stays correct, and costs
what it always did:

```lua
function handle_input(player_id, input, entities)
    local p = entities[player_id]
    if not p then return entities end
    if math.abs(input.dx) > MAX_STEP then return end   -- rejected, move discarded
    p.x = p.x + input.dx
    return entities
end
```

One thing the revert does take with it: a global the handler wrote before
returning, or randomness it consumed, is rolled back too, where the per-input
path kept those. Keep anything that must survive a rejection in `game_state` or
on an entity rather than in a Lua global.

The `nil` check is not decoration: an input can arrive for a player whose entity
is not in this zone, and a script that indexes `p` blindly raises. asobi catches
it and acks, so nothing corrupts, but the input is lost either way.

## Checkpoint

1. In a match where everyone shares one view, set `state_strategy = "shared"`
   and a one-argument `get_state(state)`. With 100+ players connected, encodes
   per tick drop from once-per-player to once total.
2. Leave a zone with no subscribers and no NPCs. Its process memory falls at
   the next tick (hibernation), and it stops entirely at the next sweep once
   it holds no entities at all.
3. Play in a Lua zone for a few minutes and watch `[asobi, lua, state]`. It
   should settle rather than climb. If it climbs, check the logs for
   `lua_gc_abandoned` and `lua_state_large`.

## Next

[Large worlds](large-worlds.md) - the zone lifecycle and terrain providers
these costs sit on top of.
