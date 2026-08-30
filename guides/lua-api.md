# The game.* API

Everything a game script can call. [Lua scripting](lua-scripting.md) is the
walkthrough; this is the reference.

The `game` table is installed into match, world and zone VMs. Bot scripts load
into a sandboxed VM with **no `game` table at all** - see
[Lua bots](lua-bots.md).

## How to read this page

There are two return conventions and you have to know which one you are
looking at.

The persistence-style calls - `economy.*`, `storage.*`,
`leaderboard.top/rank/around`, `terrain.get_chunk`, `notify`, `notify_many` -
return a wrapped table. Index into `.ok`:

```lua
local result = game.economy.balance(player_id)
if result.error then
  game.log("warning", "balance lookup failed", { reason = result.error })
  return
end
for _, wallet in ipairs(result.ok) do
  game.log("info", wallet.currency .. " = " .. wallet.balance)
end
```

The plain calls - `broadcast`, `send`, `chat.send`, `match.set_joinable`,
`bots.add`, `bots.remove`, `zone.spawn`, `zone.despawn`, `terrain.preload`,
`leaderboard.submit`, `spatial.*` - return their value directly:

```lua
local hits = game.spatial.query_radius(state.entities, 100, 100, 50)
for _, hit in ipairs(hits) do
  game.log("info", hit.id .. " at " .. hit.distance)
end
```

One exception cuts across both: calling anything with the wrong number or type
of arguments returns `{ error = "..." }` naming the shape it wanted, whichever
convention that call normally uses. So a plain call that suddenly returns a
table is an argument mistake, not a failure of the operation.

## Identity and logging

```lua
game.id()                                -- a UUIDv7 string
game.log(level, message)
game.log(level, message, meta)
```

`level` is one of `"debug"`, `"info"`, `"warn"`, `"warning"` or `"error"`.
`"warn"` and `"warning"` are the same level. Anything else returns
`{ error = "..." }`.

The line goes through the host logger, so it lands in the node's structured
JSON stream rather than breaking it. `print` and `eprint` do not exist for that
reason.

`message` is capped at 500 characters and is **truncated** past that. `meta` is
capped at 2 KB of encoded JSON and is **not** truncated: over the cap the whole
table is replaced by `{"_truncated": true}`, and a table that will not encode
becomes `{"_unencodable": true}`. Keep meta small and structured.

Logging is rate limited: 30 lines a second per match or per zone, and 300 a
second across the node. Over budget `game.log` returns `false` and the line is
dropped, so a script failing on every tick cannot drown its neighbours.

## Messaging

```lua
game.broadcast(event, payload)           -- to every player in the match
game.send(player_id, message)            -- to one player
```

`event` must be 1-64 characters of `[A-Za-z0-9_-]` and must not be one of the
names asobi emits itself: `state`, `tick`, `terrain`, `list`, `left`, `joined`,
`finished`, `phase_changed`, `matched`, `matchmaker_failed`,
`matchmaker_expired`, `vote_start`, `vote_tally`, `vote_result`,
`vote_vetoed`. A rejected name returns `{ error = "..." }` at the call site
rather than being dropped silently downstream - the client would otherwise be
unable to tell a forged `match.finished` from a real one.

`broadcast` works from a match, a world and a zone. A match script's event
reaches clients as `match.<event>`; a world or zone script's reaches them as
`world.<event>`, because the world server is bound as the broadcast target in
both.

The encoded payload is capped at 64 KB. Past that the event is dropped and the
node logs `game_broadcast_rejected` - `broadcast` has already returned `true`
by then, because the fan-out is asynchronous. Do not put a whole world snapshot
in one event.

`send` reaches the client as a `module.message` frame carrying
`{"module": "lua", "message": ...}`, which is why it takes any Lua value rather
than a table. See [WebSocket protocol](websocket-protocol.md).

## Match

```lua
game.match.set_joinable(open)            -- open or close the match to new joins
```

Match only - a world or zone script gets `{ error = "..." }` back, because the
call would otherwise reach the world server. A closed match keeps running and
keeps everyone already in it; the next player to try is answered
`match.locked`, and `match.list` reports it with `joinable = false` so a
browser can leave it out.

There is no config key and no default to set: a match opens joinable and the
game closes it when the game decides. An Erlang game module does the same
thing with `asobi_match_server:set_joinable(self(), false)` - its callbacks
run in the match process, so `self()` is the match.

This is the runtime half of joinability. `listed` decides whether a match is
advertised at all, and an unlisted match is still joinable by id - hiding a
match is not closing it.

```lua
function tick(state)
    if state.round > 1 then
        game.match.set_joinable(false)   -- no backfill past round one
    end
    return state
end
```

Asynchronous, like `broadcast`: a join already in the mailbox ahead of the flag
still gets in. Closing a match stops the next joiner, not one already through
the door. To refuse a specific player instead, return `nil` from
[`join`](lua-scripting.md#join-player_id-state-or-join-player_id-state-ctx).

## Bots

```lua
game.bots.add(name)                      -- place a bot in this match
game.bots.remove(bot_id)                 -- take one out
```

Match only - a world or zone script gets `{ error = "..." }` back. `name` is
bare and the roster id is built from it: the `bot_` prefix every bot id
carries, the name, and a short random discriminator, so
`game.bots.add("Spark")` puts something of the shape `bot_Spark_a3f91c` in the
roster. `remove` accepts the bare name or the full id. Names are 1-32
characters of `[A-Za-z0-9_-]`.

This is the script-driven route in. The other one is queue fill - `bots.enabled`
on a game mode, which tops the *matchmaker queue* up before a match exists (see
[Bots](lua-bots.md)). The two are independent: leave `bots.enabled` off and
nothing arrives that your script did not ask for.

```lua
function tick(state)
    if state.humans_waiting and count(state.players) < 4 then
        game.bots.add("Spark")
    end
    return state
end
```

Both are asynchronous and neither reports failure at the call site: a match that
is full, already holds that bot, or is at the 64-bot ceiling is a no-op with a
line in the node log. A bot runs the mode's `bots.script` if it has one and the
built-in AI otherwise.

## Economy

```lua
game.economy.grant(player_id, currency, amount)
game.economy.grant(player_id, currency, amount, reason)
game.economy.debit(player_id, currency, amount)
game.economy.debit(player_id, currency, amount, reason)
game.economy.balance(player_id)
game.economy.purchase(player_id, listing_id)
```

`amount` is truncated to an integer. `reason` is a free-form string that lands
on the transaction row.

`balance` returns `{ ok = { { currency = "...", balance = N }, ... } }` - every
wallet the player holds, not one figure.

`purchase` takes a **store-listing id**, not an item slug. That is the `id`
field of an entry in `GET /api/v1/store`, a UUID. Passing a slug fails.

There is no inventory namespace. Inventory is REST (`GET /api/v1/inventory`,
`POST /api/v1/inventory/consume`) and Erlang only.

## Leaderboards

```lua
game.leaderboard.submit(board_id, player_id, score)   -- true | false
game.leaderboard.top(board_id, count)                 -- { ok = entries }
game.leaderboard.rank(board_id, player_id)            -- { ok = rank }
game.leaderboard.around(board_id, player_id, count)   -- { ok = entries }
```

`score` is truncated to an integer. `submit` is the odd one out: it returns a
plain boolean, not a wrapped result. `rank` returns
`{ error = "not_found" }` for a player with no entry on the board.

## Notifications

```lua
game.notify(player_id, type, subject)
game.notify(player_id, type, subject, data)
game.notify_many(player_ids, type, subject)
game.notify_many(player_ids, type, subject, data)
```

`notify_many` returns `{ ok = ids }` listing the players it reached. A partial
fan-out is a shorter list, not an error, so compare the length if that matters
to you.

## Storage

```lua
game.storage.get(collection, key)
game.storage.set(collection, key, value)
game.storage.player_get(player_id, collection, key)
game.storage.player_set(player_id, collection, key, value)
```

Two distinct namespaces, not one with an optional owner. `get`/`set` write
global rows; `player_get`/`player_set` write rows owned by a player. A global
key and a player key of the same name are different rows.

The global namespace is reachable **only from Lua**. The REST storage routes
are hard-scoped to per-player rows, so nothing a client sends can read or
overwrite what `game.storage.set` wrote. That makes it the right place for
server-authoritative configuration and the wrong place for anything a client
needs to fetch directly.

## Chat

```lua
game.chat.send(channel_id, sender_id, content)        -- true
```

`sender_id` is whoever the message should appear to be from; nothing here
checks that the sender is in the channel. The channel process is started if it
is not already running, with `channel_type` `"room"`. Delivery and persistence
are asynchronous, so `true` means the message was handed off, not that it is on
disk.

## Spatial

Four shapes, and mixing them up is the usual mistake.

**Entity-list and zone forms.** `query_radius` takes either:

```lua
game.spatial.query_radius(entities, x, y, radius)
game.spatial.query_radius(entities, x, y, radius, opts)
game.spatial.query_radius(x, y, radius)               -- zone context required
```

`query_rect` is zone-only:

```lua
game.spatial.query_rect(x1, y1, x2, y2)               -- zone context required
```

The entity-list forms return `{ id = ..., entity = ..., distance = ... }` per
hit. The zone forms return `{ id = ..., x = ..., y = ... }` per hit - no
`entity` and no `distance`. Without zone context the zone forms return
`{ error = "... requires zone context" }`.

**Neighbour forms.** These read the eight zones touching the caller's, and
nothing else - not the caller's own zone, which is already in `entities`:

```lua
game.spatial.neighbours_radius(x, y, radius)          -- zone context required
game.spatial.neighbours_radius(x, y, radius, opts)
game.spatial.neighbours_rect(x1, y1, x2, y2)          -- zone context required
game.spatial.neighbours_rect(x1, y1, x2, y2, opts)
```

`neighbours_radius` returns `{ id = ..., entity = ..., distance = ... }` per
hit and `neighbours_rect` the same without `distance`. The entities are
**copies**: the neighbour still owns them, and writing to what comes back
changes nothing. They return nothing at all unless the world sets
`border_band`, which is off by default - see
[World server](world-server.md#seeing-across-a-seam) for what it costs and how
to act on what you find. They see only the band along each zone's edges, so
size the radius against the ring rather than the zone: from your own centre the
far corner of a diagonal neighbour is 2.12 zones away, and `zone_size * 2.2`
is the radius that covers all eight.

**Entity-list only.**

```lua
game.spatial.nearest(entities, x, y, n)
game.spatial.nearest(entities, x, y, n, opts)
```

**Two entities.**

```lua
game.spatial.in_range(entity_a, entity_b, range)      -- boolean
game.spatial.distance(entity_a, entity_b)             -- number
```

An entity with no numeric `x` and `y` is not a position, and the two answer it
differently on purpose. `in_range` returns **`false`** - something with no
position is not in range, and returning an error table instead would be
*truthy*, so `if game.spatial.in_range(a, b, r) then` would take the success
branch. `distance` returns `{ error = "entity_a needs numeric x and y" }`,
naming which of the two, because there is no number it could honestly answer
with. Both also log, rate-limited, so the mistake is findable.

```lua
```

`opts` accepts four keys, and not every entry point honours all four. The
zone-context form `query_radius(x, y, radius)` takes no options at all - pass an
entity map to use them.

| Key | Value | entity-list `query_radius` / `neighbours_radius` | `neighbours_rect` | `nearest` |
| --- | --- | --- | --- | --- |
| `type` | A type string, or a list of them, to include | yes | yes | yes |
| `exclude` | An entity id, or a list of them, to drop | yes | yes | yes |
| `max_results` | Cap on hits returned | yes | yes | no, `n` is the cap |
| `sort` | `"nearest"` or `"farthest"` | yes | no distance to sort by | yes |

`nearest` with `sort = "farthest"` returns the `n` *farthest* matches, which is
the query for disengaging from a threat or pruning the most distant node.

**Upgrading.** Before v0.99.0 an option a query did not read was ignored, so a
script passing `{ types = "npc" }` got unfiltered results and a script passing
`sort` to `nearest` got the nearest anyway. Both are now errors that name the
option. If you are upgrading, grep your scripts for `game.spatial` calls with an
`opts` table and check the keys against the table above. The reasoning is in
`docs/adr/0020-spatial-opts-are-validated-per-query.md`.

A `no` is an error, not a silent no-op: `neighbours_rect(x1, y1, x2, y2, { sort
= "nearest" })` returns `{ error = ... }` rather than an arbitrary order. Omit
`opts` entirely, or pass `nil` or `{}`, to use none of them.

Anything else is an error: an unknown key, a value of the wrong shape, or a
`type` list holding no strings all return `{ error = ... }` naming the option.
A misspelled filter has two silent failures otherwise - it either drops the
filter and returns everything, or it matches nothing and reads exactly like an
empty result - and neither is distinguishable from a correct query at the call
site. An empty table means no options.

## World mode only

```lua
game.zone.spawn(template_id, x, y)                    -- true | false
game.zone.spawn(template_id, x, y, overrides)         -- true | false
game.zone.despawn(entity_id)                          -- true
game.zone.apply(entity_id, event)                     -- true | false
game.zone.park()                                      -- true
game.terrain.get_chunk(cx, cy)                        -- { ok = data }
game.terrain.preload(coords_list)                     -- true
```

`spawn` returns `false` for a template the zone does not declare - the spawn
itself is asynchronous, so the return says "the template resolved", not
"something exists now". It reads the zone's live template set, so a hot reload
that adds a template takes effect without a restart.

`apply` asks the *neighbouring* zone that owns `entity_id` to act on it, and
returns `false` when no neighbour currently publishes that entity - you can
only affect what `neighbours_radius`/`neighbours_rect` would have shown you.
The owning zone runs the event through its own `handle_effects(effects,
entities)` on its next tick. A script that calls `apply` without defining
`handle_effects` gets a rate-limited error and dropped effects.

`park` asks the zone to stop after this tick even though it still holds
entities - the thing the idle reaper will not do on its own. `true` means
"asked": it is a cast, like every `game.zone.*` call, because this runs inside
the zone's own tick. It is declined outright while anyone is subscribed to the
zone, and asobi logs when it is. What a parked zone gets back when it next
loads depends on `persistent` - see
[Large worlds](large-worlds.md#stopping-a-zone-that-still-holds-something).

`terrain.preload` takes a list of tables carrying `cx`/`cy` (or `x`/`y`).
Entries it cannot read are skipped rather than raising.

`zone.*` needs zone context and `terrain.*` needs a terrain store, so all of
these are world-mode only. Called anywhere else they return
`{ error = "... not available ..." }`. See [World server](world-server.md).

## Extension namespaces

An installed [extension](extensions.md) declares its own `game.<namespace>`,
installed in the same window as core's, so it reads like a core call:

```lua
local result = game.quests.progress(player_id, "first_blood")
if result.ok then
  game.log("info", "quest advanced")
end
```

Extension bindings use the wrapped `{ ok = ... }` / `{ error = "..." }`
envelope, whoever wrote them. An extension may bind into match, world and zone
VMs; `bot` is refused at `rebar3 asobi check` rather than installing nothing.

## Standard library

The Lua standard library is present apart from what the sandbox clears, with
two functions replaced:

- `math.random()` returns a float in `[0, 1)`. `math.random(n)` returns an
  integer in `[1, n]`. `math.random(a, b)` returns an integer in `[a, b]`; an
  empty interval (`a > b`) raises, as in standard Lua. Non-integer bounds are
  truncated towards zero, where standard Lua raises.
- `math.sqrt(n)` returns `0.0` for negative input rather than NaN.

Both are backed by the BEAM's `rand` and `math`. `math.randomseed` still
exists, but it seeds Luerl's own generator, which the replaced `math.random`
never reads - so seeded determinism is not available.

`os` keeps `os.clock`, `os.date`, `os.difftime` and `os.time`.

`require("name")` and `require("dir.name")` load `<dir of the loaded
script>/name.lua` and `<dir of the loaded script>/dir/name.lua`. Results are
cached, and the cache is cleared on hot reload so an edited module is re-read.
A symlinked module file is refused.

## What is not there

- **No `package` table and no `package.path`.** `require` is asobi's own and
  resolves relative to the directory of the script that was loaded. Dotted
  names work (`require("bots.chaser")`); parent traversal and absolute paths do
  not.
- **No `coroutine`.** Luerl 1.5.1 does not implement it.
- **No `io`, `load`, `loadstring`, `dofile`, `loadfile`, `print` or
  `eprint`**, and `os` keeps only its harmless half - `os.execute`, `os.exit`,
  `os.getenv`, `os.remove`, `os.rename` and `os.tmpname` are cleared to `nil`,
  so `os.execute == nil` is a predicate a script can check.
- Scripts run on **Luerl 1.5.1**, with Lua 5.3 semantics, not the reference
  implementation. Upstream describes the 5.2-to-5.3 migration as in progress,
  so treat anything exotic as worth testing rather than assumed.

## Limits

Every callback except `handle_input` runs in a child process under a
wall-clock budget, a 5,000,000-word per-eval heap cap and a reduction budget.
Exceeding any of them discards that callback's result and keeps the previous
Lua state; the match or zone survives.

`handle_input` is the exception, and it is deliberate: it runs inline, because
at high input rates the spawn cost dominates the Lua work. It has no budget of
any kind, so an infinite loop there hangs that one match or zone indefinitely,
with no supervisor restart to recover it. Bound your own loops.
[Sandbox and limits](security-sandbox.md) has the numbers and the reasoning.

## Next

- [Lua scripting](lua-scripting.md) - callbacks, modules, the walkthrough.
- [World server](world-server.md) - zones, terrain, the world callbacks.
- [Extensions](extensions.md) - adding a `game.<namespace>` of your own.
