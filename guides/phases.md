# Phases and seasons

Two clocks, different scopes.

A **phase** is a stage in one session's lifecycle - lobby, then play, then
results - inside a single match or world. It starts and ends with that
session and is authored in the game script.

A **season** is a wall-clock window across the whole deployment - a
fortnight of ranked play, a themed event - shared by every session. It
lives in the database and is read by game logic.

They do not interact. This guide covers both because a reader who sees
`phase` on a `world.list` response, or hears "season", lands here.

## Phases

### Declare them in your game script

Phases are a list. The engine walks it in order: the first phase starts,
runs for its `duration`, ends, and the next begins.

```lua
-- king_of_the_hill.lua
function phases(config)
  return {
    { name = "warmup",  duration = 10000 },
    { name = "combat",  duration = 120000 },
    { name = "results", duration = 8000 },
  }
end
```

`duration` is milliseconds. When the last phase ends the session's phase
state is complete; a match reports `phases_complete` and finishes.

This is game logic. It runs identically whether you deploy to the managed
cloud or self-host - nothing here touches deployment, secrets, or the
database. Every phase example below is written once and is the same on both.

### Start conditions

By default each phase starts when the previous one ends (`prev_ended`). A
phase can instead wait for a condition:

```lua
function phases(config)
  return {
    { name = "lobby",  start = { players = 4 } },
    { name = "combat", duration = 120000 },
    { name = "results", duration = 8000 },
  }
end
```

Start conditions you can declare from Lua:

| `start` value        | Meaning                                  |
|----------------------|------------------------------------------|
| `"prev_ended"`       | when the previous phase ends (default)   |
| `{ players = N }`    | when the Nth player has joined           |
| `{ timer = Ms }`     | after Ms of waiting, whatever else       |
| `Ms` (a bare number) | shorthand for `{ timer = Ms }`           |
| `"all_ready"`        | when the game signals every player ready |

A waiting phase has no duration clock; it holds until its condition fires.

### React to transitions

Two optional callbacks fire as phases begin and end. Use them to reset
scores, open a gate, freeze input. The client sends intent; the server
decides the phase; the server broadcasts the result.

```lua
function on_phase_started(phase_name, state)
  if phase_name == "combat" then
    state.scores = {}
    game.broadcast("round_start", { phase = phase_name })
  end
  return state
end

function on_phase_ended(phase_name, state)
  if phase_name == "combat" then
    game.broadcast("round_over", { winner = leader(state) })
  end
  return state
end
```

`game.broadcast` is how the phase reaches your own clients with your own
shape. See the callback reference for the full callback list.

### What the client sees on the wire

A **world** pushes `world.phase_changed` on every transition and again
roughly every three seconds while a phase runs. The payload is the phase
info block:

```json
{
  "type": "world.phase_changed",
  "payload": {
    "status": "active",
    "phase": "combat",
    "remaining_ms": 118400,
    "config": {},
    "world_id": "..."
  }
}
```

A **match** does not push a phase event. The match server runs the phase
clock and your callbacks, but the client learns the phase by reading the
`phase` block on the listing and join reply - `status`, `phase`,
`remaining_ms` and the pending `start_condition`. Broadcast anything richer
yourself from `on_phase_started`.

See [WebSocket protocol](websocket-protocol.md#worldphase_changed-server-push)
for the frame envelope and [Lobbies](lobbies.md) for `game.broadcast`.

### Erlang games

An Erlang match or world module implements the same three callbacks and has
the full phase feature set, including per-phase `timers`, an `end_condition`
predicate, and the `players_ratio` and `event` start conditions that the Lua
decoder does not expose.

```erlang
phases(_Config) ->
    [
        #{name => ~"warmup", duration => 10000},
        #{name => ~"combat", duration => 120000,
          timers => [#{id => ~"suddendeath", type => countdown, duration => 100000}]},
        #{name => ~"results", duration => 8000}
    ].

on_phase_started(~"combat", GameState) ->
    {ok, GameState#{scores => #{}}};
on_phase_started(_Name, GameState) ->
    {ok, GameState}.
```

### Limits when authoring in Lua

The Lua `phases()` decoder reads `name`, `duration`, `start` and `config`
only. From Lua you cannot declare per-phase `timers`, an `end_condition`
function, or the `players_ratio` and `event` start conditions - those need
an Erlang game module. If a phase needs a timer, drive it from your own tick
logic and `game.broadcast`, or move that game to Erlang.

## Seasons

A season is a named, dated window stored in the `seasons` table. A
background manager checks the clock once a minute and moves each season
`upcoming -> active -> ended` as its `starts_at` and `ends_at` pass. Exactly
the parts of a game you want gated on "the current event" - a ranked ladder,
a reward set - key off the active season.

Seasons are a server-side primitive today. There is no Lua binding, no
WebSocket event and no REST endpoint. You seed a season row into the
database and read it from Erlang game logic.

### Seed a season

A season is one row. `starts_at` and `ends_at` are millisecond epochs.

```erlang
Now = erlang:system_time(millisecond),
CS = kura_changeset:cast(asobi_season, #{}, #{
    name      => ~"Spring Ladder",
    starts_at => Now,
    ends_at   => Now + 14 * 24 * 60 * 60 * 1000,
    status    => ~"active",
    config    => #{theme => ~"spring"},
    rewards   => #{top10 => ~"gold_frame"}
}, [name, starts_at, ends_at, status, config, rewards]),
{ok, _} = asobi_repo:insert(CS).
```

Where that row goes differs by deployment:

**Cloud.** The per-project database is provisioned for you and the `seasons`
table already exists. Open a console against your project
(`console.asobi.dev`) and insert the row - or run the snippet above from a
release remote shell attached to your project's node.

**Self-hosted.** Point `ASOBI_*` at your own Postgres, apply migrations so
the `seasons` table exists (`rebar3 kura migrate`), then insert the row from
your release's remote shell. See [Configuration](configuration.md) for the
`ASOBI_*` database variables.

Once the row exists the season manager runs the same on both: it flips
`status` by wall clock with no further action from you.

### Read the active season from game logic

```erlang
case asobi_season:current() of
    {ok, #{name := Name, rewards := Rewards}} ->
        %% gate ranked play, pick the reward table, etc.
        {ranked, Name, Rewards};
    {error, no_active_season} ->
        casual
end.
```

Other queries: `asobi_season:config(Key)` pulls one key from the active
season's `config`; `upcoming/0` and `history/0` list scheduled and past
seasons; `time_remaining/0` returns milliseconds left in the active season
(or `infinity` if none is active).

To surface the season to players, read it in your game module and put it in
the state you already send - there is no season frame to subscribe to.

## Checkpoint

Phases, with a Lua world game running locally:

1. Add a `phases()` returning `warmup` (5000) then `active` (10000) to your
   world script.
2. Join the world over the WebSocket and watch the frames. Within a few
   seconds you see `world.phase_changed` with `"phase": "warmup"`, then
   after five seconds another with `"phase": "active"`.
3. Call `world.list`; the entry carries a `phase` block with the live
   `phase` and `remaining_ms`.

Seasons:

1. Insert a season row with `status = "active"` and an `ends_at` a minute
   out (cloud console, or self-hosted remote shell as above).
2. From a remote shell, `asobi_season:current()` returns `{ok, Season}` and
   `asobi_season:time_remaining()` counts down.
3. Wait past `ends_at`; within a minute the manager logs `season_ended` and
   `current()` returns `{error, no_active_season}`.

If the phase frames never arrive, confirm the game is a **world** (matches
run phases but do not push them) and that `phases()` returns a list. A
non-list logs a warning and is ignored.

## Next

[Voting](voting.md) - run a vote inside a phase to let players pick what
happens in the next one.
