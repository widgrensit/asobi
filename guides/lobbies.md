# Lobbies

How to gather players before a game starts.

Asobi has no `Lobby` object. That is a deliberate choice, not a gap - a
lobby is a *state*, not a type, and asobi already has two things that hold
players before a game begins. This guide is about picking one and wiring it
up, because the pieces are documented separately and the flow is not
obvious from any one of them.

## Which one

| | Waiting match | Persistent world |
|---|---|---|
| Use for | gather N players, play, done | a hub people return to between games |
| Processes | 1 | ~6 (instance sup, zone sup, zone, ticker, server) |
| Ticks while idle | none | yes, at `tick_rate` |
| Presence | you broadcast it | free, from the tick loop |
| Lifetime | starts at `min_players`, times out after 60s | survives empty if `persistent` |

For "gather four players and start", use a **waiting match**. A world is a
spatial simulation; running one so people can stand still is the expensive
way round.

## Waiting match

A match starts in the `waiting` state and only transitions to `running`
when `min_players` is reached. That waiting period is the lobby.

```lua
-- arena.lua
match_size  = 4      -- min_players: the match starts when the 4th player joins
max_players = 4
listed      = true   -- so match.list can find it
```

A waiting match holds one process and one 60-second timer. It does not tick
until it starts, so idle lobbies cost close to nothing.

### Letting players find it

```
GET /api/v1/matches/live        REST
match.list                      WebSocket
```

Both filter on `mode` and `has_capacity`. Matches are **unlisted by
default** - a matchmaker-spawned match is already assigned to its players
and has no reason to be browsable - so a mode opts in with `listed = true`.

Do not use `GET /api/v1/matches` for this. It reads the match record table:
finished matches, an audit trail, nothing joinable. See
[REST API](rest-api.md).

### Private lobbies

Share a code out of band and check it on the way in. The join context is
whatever the client put in the join payload; asobi never reads it.

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

Combine with `listed = false` for a lobby that is reachable only by code.
See [Join context](websocket-protocol.md#join-context).

### Telling the room someone arrived

Core does not push a join notification to the players already waiting. That
is deliberate: `match.left` is a reply to the leaver rather than a
broadcast, so co-member notification is the game's decision throughout, and
what a lobby shows differs per game - a bare count, a full roster, nothing
until it fills.

`game.broadcast` from your join callback is the whole of it, as above. It
reaches every player currently in the match.

### Chat in a lobby

There is no `match:` chat channel scheme. `world:<WorldId>` exists and is
gated on world membership; matches have no equivalent. Use `game.broadcast`
with your own message shape.

The `room:` scheme is documented as open-join but is not - it resolves to a
group membership check. See
[asobi#209](https://github.com/widgrensit/asobi/issues/209).

### The 60-second timeout

A match that does not reach `min_players` within 60 seconds stops itself.
That value is currently fixed (`?WAITING_TIMEOUT` in `asobi_match_server`)
and is not exposed per mode. Fine for quick play; too short if you want
players assembling at their own pace.

## Persistent world as a hub

For a town square people return to between games, use a world.

```lua
-- hub.lua
game_type   = "world"
persistent  = true    -- stays alive when empty; without this it dies on the last leave
grid_size   = 1       -- one zone: no spatial partitioning needed to stand around
tick_rate   = 200     -- 5 Hz is plenty; the 50ms default is for action games
listed      = true
quick_play  = true    -- world.find_or_create drops everyone into the same one
match_size  = 1
```

`persistent` is the flag that makes it a hub rather than a session. Without
it a world finishes the moment the last player leaves, so the next player
gets a fresh empty one.

Presence is free here: worlds tick and broadcast zone state, so players see
each other without you broadcasting anything. `world:<WorldId>` chat works
and is gated on world membership.

Nothing creates the hub at boot. The first `world.find_or_create`
instantiates it and it stays up from then on; after a restart the first
player recreates it, restoring snapshots if `persistent`.

Worlds are subject to `world_max_per_player` (5) and `world_max` (1000) -
see [World capacity](configuration.md#world-capacity).

## Not included

- **Ready-up.** No first-class ready state. Track it in your own game state
  and broadcast it; the join context and `game.broadcast` are enough.
- **Party.** You cannot queue as a group through the matchmaker. Play with
  specific people by sharing a match id or a join code.
- **Rich filters.** Discovery filters on `mode` and `has_capacity` only.
  Anything richer belongs in your strategy module.
- **Member roster API.** The joiner receives the roster on `match.joined`;
  there is no separate "who is here" call. Keep the list in your game state.
