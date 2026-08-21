# Lobbies

How to gather players before a game starts.

asobi has no `Lobby` object. A lobby is a state, not a type, and asobi already
has two things that hold players before a game begins. This guide is about
picking one and wiring it up.

## Which one

| | Waiting match | Persistent world |
|---|---|---|
| Use for | gather N players, play, done | a hub people return to between games |
| Who can create one | an Erlang caller in the release, or the matchmaker | any client, over `world.create` or `POST /api/v1/worlds` |
| Processes | 1 | 6 (instance sup, zone sup, zone manager, one zone, ticker, world server) |
| Ticks while idle | none | yes, at `tick_rate` |
| Presence | you broadcast it | free, from the tick loop |
| Lifetime | starts at `min_players`, gives up after 60s | survives empty if `persistent` |

A waiting match is the cheaper shape, but the row above that decides it is
"who can create one". Read the next section before choosing it.

## Waiting match

A match starts in the `waiting` state and transitions to `running` when
`min_players` is reached. That waiting period is the lobby.

**`match.find_or_create` is the client-facing route into a live match.** Send a
mode; the server returns the first listed match of that mode with room that is
still accepting players, and spawns one if there is none. The reply is
`match.joined`, the same frame `match.join` answers with.

```json
{"type": "match.find_or_create", "cid": "1", "payload": {"mode": "arena"}}
```

Opt in with `quick_play = true`. It defaults to `false` for match modes, so a
ranked mode the matchmaker owns is refused with `quick_play_disabled` until you
say otherwise - and a mode written before this frame existed is safe on upgrade
without touching it.

`quick_play` and `listed` are independent: `listed` decides whether a match
appears in `match.list`, `quick_play` decides whether a player may be dropped
into an existing one. Hidden but auto-filled is a legitimate combination.

Prefer it over `match.list` then `match.join`. Browsing and then joining is two
round trips with a race in the middle: two clients that both read an empty list
both create, and you get two half-empty matches that may each fail to reach
`min_players`. `find_or_create` resolves server-side, serialized, so
simultaneous callers land in the same match.

There is still no bare `match.create`, and no `POST /api/v1/matches`. Creating a
match without reusing one is what the matchmaker is for.

But the waiting state is reachable from mode config. Declare a `min_players`
higher than `match_size` and the matchmaker spawns on the group it formed while
the match sits in `waiting` until backfill brings it up to the threshold:

```lua
match_size  = 2   -- the matchmaker forms and spawns on two
min_players = 4   -- the loop does not start until four are in
max_players = 8
quick_play  = true   -- so match.find_or_create can bring the other two in
listed      = true   -- so match.list can find it too
```

It gives up at `?WAITING_TIMEOUT` (60s) if the fourth never arrives.

Before asobi v0.85.0 the matchmaker overwrote `min_players` with `match_size`,
so declaring it was silently ignored and a waiting lobby needed an Erlang module
in your release calling `asobi_match_sup:start_match/1`. That function still
exists for an operator shipping their own module, but nothing about a lobby
needs it any more.

**A match is a client-creatable session too.** That was not true before
`match.find_or_create`, and this page used to send Lua readers to a world for
that reason. A world is still the better hub when you want somewhere persistent
that survives empty - see [Persistent world as a hub](#persistent-world-as-a-hub)
- but it is a choice now, not the only option.

### Letting players find it

```
GET /api/v1/matches/live        REST
match.list                      WebSocket
```

Both filter on `mode`, `has_capacity` and `joinable`. Matches are unlisted by
default - a matchmaker-spawned match is already assigned to its players and has
no reason to be browsable - so a mode opts in with `listed = true`.

Do not use `GET /api/v1/matches` for this. It reads the match record table:
finished matches, an audit trail, nothing joinable. See
[REST API](rest-api.md).

### Joining a match already in progress

A `running` match accepts joins exactly as a `waiting` one does, so backfill is
`match.list` then `match.join` with the `match_id` - there is no separate call
and no backfill mode to turn on. Your `join` callback runs mid-match, so it has
to cope with a player arriving into a live game state.

Ask for both filters when you are looking for somewhere to play:

```json
{"type": "match.join", "payload": {"match_id": "..."}}
```

```
match.list  { "has_capacity": true, "joinable": true }
```

They are different questions. A match with three free slots may have closed
itself to new players; a full one has not closed, and may free a slot on the
next leave. Every listing carries `joinable`, so a browser can show both and
grey one out.

To close a match to backfill, call
[`game.match.set_joinable(false)`](lua-api.md#match) from the script - at the
end of round one, once the objective spawns, whenever the game says so. A
closed match answers `match.locked`; a full one answers `match.full`. To turn
away one specific player rather than everybody, return `nil` from
[`join`](lua-scripting.md#join-player_id-state-or-join-player_id-state-ctx) instead.

### The 60-second timeout

A match that does not reach `min_players` within 60 seconds stops itself. That
value is fixed (`?WAITING_TIMEOUT` in `asobi_match_server`) and is not exposed
per mode. Fine for quick play; too short if you want players assembling at their
own pace.

## Persistent world as a hub

For a town square people return to between games, use a world. This is the path
a client can drive on its own.

```lua
-- hub.lua
game_type   = "world"
persistent  = true    -- stays alive when empty; without this it dies on the last leave
grid_size   = 1       -- one zone: no spatial partitioning needed to stand around
tick_rate   = 200     -- 5 Hz is plenty; the 50ms default is for action games
match_size  = 1
```

`listed` and `quick_play` are Lua globals, both defaulting to true for a world -
which is what a hub wants: it is browsable and `world.find_or_create` drops
everyone into the same one. Set either to `false` in the script to change it.
An operator `game_modes` entry still wins, and it replaces the script's mode
config rather than merging into it - so if you add one, declare
`module => {lua, "hub.lua"}` and the rest of the shape in it too.

`persistent` is the flag that makes it a hub rather than a session. Without it a
world finishes the moment the last player leaves, so the next player gets a
fresh empty one.

Presence is free here: worlds tick and broadcast zone state, so players see each
other without you broadcasting anything. `world:<WorldId>` chat works and is
gated on world membership.

Nothing creates the hub at boot. The first `world.find_or_create` instantiates
it and it stays up from then on; after a restart the first player recreates it.

Worlds are subject to `world_max_per_player` (5) and `world_max` (1000) - see
[World capacity](configuration.md#instance-capacity).

### Private lobbies

A code-gated private lobby can be a match as well as a world: `match.find_or_create`
forwards the join context, so a `join` callback can refuse on a bad code. Share a code out of band and check it on the way in. The join context
is whatever the client put in the join payload; asobi never reads it.

```lua
function join(player_id, state, ctx)
	if ctx.code ~= state.room_code then
		return state                    -- refuse: player is not added
	end
	state.players[player_id] = true
	game.broadcast("lobby_update", { players = state.players })
	return state
end
```

Hide it from the browser with `listed = false` in the script. That is discovery
only - it never gates joining, so the join callback above is still the whole
gate. `listed` and `quick_play` are properties of the mode, not of one
instance, so every world of that mode is equally hidden. See
[Join context](websocket-protocol.md#match-join).

### Telling the room someone arrived

Core does not push a join notification to the players already waiting. That is
deliberate: what a lobby shows differs per game - a bare count, a full roster,
nothing until it fills.

`game.broadcast` from your join callback is the whole of it, as above. It
reaches every player currently in the session, and the example above arrives
client-side as `{"type": "world.lobby_update", "payload": {"players": ...}}` -
`match.lobby_update` from a match script. Naming rules and the SDK-side handler
are in [Custom events](websocket-protocol.md#custom-events).

### Chat in a lobby

There is no `match:` channel scheme. `world:<WorldId>`, `zone:<WorldId>:<X>,<Y>`
and `prox:<WorldId>:<X>,<Y>` exist and are gated on world membership; matches
have no equivalent, so a match lobby uses `game.broadcast` with your own message
shape.

The `room:` scheme is not open-join - `room:<GroupId>` resolves to a membership
check against that group.

## Seeing what players see

The console's Matches screen is the **finished-match record**, not the live
list: core writes one row when a match ends, so a waiting lobby never appears
there. To see what a player browsing sees, call `GET /api/v1/matches/live`.
There is no worlds screen either; use `GET /api/v1/worlds`. See
[Operator console](console.md).

## Not included

- **Ready-up.** No first-class ready state. Track it in your own game state and
  broadcast it; the join context and `game.broadcast` are enough. A game that
  wants a shared one can ship it as an extension method and call it over the
  `rpc.call` frame - see [Extensions](extensions.md).
- **Party.** You cannot queue as a group through the matchmaker. Play with
  specific people by sharing a world id or a join code, or add party grouping as
  an extension.
- **Rich filters.** Discovery filters on `mode`, `has_capacity` and `joinable`
  only. Anything richer belongs in your strategy module, or in an extension
  method that returns the filtered list.
- **Backfill matchmaking.** The matchmaker builds matches out of the queue; it
  never routes a queued player into a match that is already running. Backfill
  is a client browsing and joining, not a strategy the matchmaker runs.
- **Member roster API.** The joiner receives the roster on `match.joined` /
  `world.joined`; there is no separate "who is here" call. Keep the list in your
  game state, or expose it as an extension method.
