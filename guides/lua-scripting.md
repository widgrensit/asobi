# Lua scripting

asobi is one Erlang/OTP node containing the game backend, the Lua runtime and
the operator console. There are two ways in: run the image and write Lua, which
is what this guide covers, or depend on the Hex package and write Erlang, which
is the same node through its other surface.

Lua runs inside the BEAM via [Luerl](https://github.com/rvirding/luerl), so a
script gets OTP's fault tolerance and concurrency without a separate process,
a compilation step or a toolchain.

## Quick start

```bash
mkdir my_game && cd my_game
mkdir -p game/bots
```

Write `game/match.lua`:

```lua
match_size = 2
max_players = 8
strategy = "fill"

function init(config)
    return {
        players = {},
        tick_count = 0
    }
end

function join(player_id, state)
    state.players[player_id] = {
        x = 400, y = 300, hp = 100, score = 0
    }
    return state
end

function leave(player_id, state)
    state.players[player_id] = nil
    return state
end

function handle_input(player_id, input, state)
    local p = state.players[player_id]
    if not p then return state end

    if input.right then p.x = p.x + 5 end
    if input.left then p.x = p.x - 5 end
    if input.down then p.y = p.y + 5 end
    if input.up then p.y = p.y - 5 end

    state.players[player_id] = p
    return state
end

function tick(state)
    state.tick_count = state.tick_count + 1
    return state
end

function get_state(player_id, state)
    return {
        players = state.players,
        tick_count = state.tick_count
    }
end
```

Write `docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: my_game_dev
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  asobi:
    image: ghcr.io/widgrensit/asobi:latest
    depends_on:
      postgres: { condition: service_healthy }
    ports:
      - "8084:8084"
    volumes:
      - ./game:/app/game
    environment:
      ASOBI_DB_HOST: postgres
      ASOBI_DB_NAME: my_game_dev
      ASOBI_DB_PASSWORD: postgres
```

```bash
docker compose up -d
```

asobi reads the scripts from the mounted directory, derives the game mode from
`match.lua`, and serves the database, authentication, matchmaking and
WebSocket layers around it.

The directory it reads is `/app/game`. Change it with `{asobi, [{game_dir,
"/some/other/path"}]}` in `sys.config` if you are not using this compose file.

## Editing while it runs

Edit a script and save it; the next tick picks it up. There is no restart and
no rebuild.

The bridge stats the script on every tick and re-evaluates the new file body
against the running Luerl state when the mtime moves. Re-evaluating the body
redeclares globals and redefines functions in place, so in-flight state
survives: players, counters and tables stay exactly as they were, because
nothing re-runs `init()`. Changing what `tick` does takes effect on the next
tick, for matches already in progress.

A file that fails to load logs `lua hot reload failed` with the reason, records
the new mtime so the same broken file is not retried every tick, and keeps
running the last good code. Fix the file and save again.

The `require` cache is cleared on reload, so an edited module a script
`require`s is re-read too.

Mode-shape edits are separate. `match_size`, `max_players`, `strategy`, the
`bots` table and the `config.lua` manifest are consumed when a match is
*formed*, before any match server exists, so a per-tick reload is structurally
blind to them. A watcher polls the manifest and every registered mode script
every 1500 ms and re-runs the config loader when an mtime moves. New matches
get the new shape; running matches keep the values they started with.

Turn the whole thing off with `ASOBI_LUA_RELOAD=off` or `{asobi,
[{reload_mode, off}]}`. That skips the per-tick stat and stops the watcher
polling, which is what a sealed production image wants: its mtimes never move
anyway. Anything other than `off` means `auto`, so a typo cannot silently
disable reload.

Put all of it under `{asobi, [...]}`. An existing `{asobi_lua, [...]}` block
from before the merge still works for the runtime's own settings - see
[Which application key](configuration.md#which-application-key).

## Multiple game modes

For more than one mode, add a `config.lua` manifest:

```lua
return {
    arena = "arena/match.lua",
    ctf   = "ctf/match.lua"
}
```

```
my_game/
├── game/
│   ├── config.lua
│   ├── arena/
│   │   └── match.lua
│   └── ctf/
│       └── match.lua
└── docker-compose.yml
```

Each match script declares its own config as globals. When `config.lua` exists
it is read instead of a top-level `match.lua`. With no `config.lua`, a single
`match.lua` is loaded as the `"default"` mode. A mode script path that escapes
the game directory is rejected.

## Match script globals

Declare the mode's settings as globals at the top of the script. asobi reads
them before any callback runs.

```lua
match_size   = 4                          -- required: min players to start
max_players  = 10                         -- optional: max per match
strategy     = "fill"                     -- optional: "fill" or "skill_based"
bots         = { script = "bots/ai.lua" } -- optional: enable bot filling
guest_auth   = true                       -- optional: allow anonymous guest play
registration = "closed"                   -- optional: signup posture
```

| Global | Required | Default | Description |
|--------|----------|---------|-------------|
| `match_size` | yes | - | Minimum players needed to start a match. Must be a positive integer |
| `max_players` | no | `match_size` | Maximum players per match |
| `strategy` | no | `"fill"` | `"fill"` or `"skill_based"` |
| `game_type` | no | `"match"` | `"world"` routes the script through the world bridge - see [World server](world-server.md) |
| `state_strategy` | no | per-player | `"shared"` broadcasts one payload to everyone; see below |
| `bots` | no | none | Bot configuration - see [Bots](lua-bots.md) |
| `guest_auth` | no | `false` | Offer anonymous no-account play. Also requires an operator-supplied pepper; on only when both are present (ADR 0004) |
| `registration` | no | `"open"` | `"open"`, `"oauth_only"` (no password signup) or `"closed"` (no new players). The operator layer wins: this applies only when the release's `sys.config` leaves `registration` unset |

`strategy` is not validated. A value that is neither `"fill"` nor
`"skill_based"` falls back to `fill`, and nothing is logged - check the
spelling yourself.

`state_strategy = "shared"` routes the mode to a different bridge, one that
calls `get_state` **once per tick with one argument** and broadcasts a single
pre-encoded payload to every subscriber. It is the right choice when every
player sees the same world, and it changes the signature you must write:

```lua
state_strategy = "shared"

function get_state(state)
    return { players = state.players }
end
```

A script written against the two-argument `get_state(player_id, state)` will
not work under `"shared"`, and vice versa. Bots do not work under `"shared"`
either - see [Lua bots](lua-bots.md#what-a-bot-script-gets).

World mode adds its own globals (`tick_rate`, `grid_size`, `zone_size`,
`view_radius`, `player_ttl_ms` and more). They live in
[World server](world-server.md) rather than here.

For a single-mode game these globals live in `match.lua`. In a multi-mode game,
the deployment-wide ones - `guest_auth` and `registration` - are read from
`config.lua`, not from the per-mode scripts.

## Callbacks

Six callbacks are required.

### `init(config)`

Called once when a match is created. Returns the initial game state table.

```lua
function init(config)
    return {
        players = {},
        arena_w = config.arena_w or 800,
        arena_h = config.arena_h or 600
    }
end
```

### `join(player_id, state)` or `join(player_id, state, ctx)`

Called when a player joins. Returns the updated state.

```lua
function join(player_id, state)
    state.players[player_id] = {
        x = math.random(state.arena_w),
        y = math.random(state.arena_h),
        hp = 100
    }
    return state
end
```

The optional third argument carries the join context the client sent with
`match.join`, and it is the only way a Lua game implements join codes, invites
or passwords:

```lua
function join(player_id, state, ctx)
    state.players[player_id] = {
        hp = 100,
        spectator = state.join_code ~= nil and ctx.code ~= state.join_code
    }
    return state
end
```

Declaring two parameters keeps working unchanged - Lua discards the extra
argument.

`ctx` is validated before it reaches the script: a flat table, at most 8 keys,
keys up to 64 bytes, scalar values up to 256 bytes, no nesting. asobi never
interprets, echoes or logs it. Returning the updated state is the only
supported outcome, so a failed check has to be expressed in the state you
return, as above.

### `leave(player_id, state)`

Called when a player leaves. Returns the updated state.

```lua
function leave(player_id, state)
    state.players[player_id] = nil
    return state
end
```

### `handle_input(player_id, input, state)`

Called when a player sends input over the WebSocket. `input` is whatever the
client sent. Returns the updated state.

```lua
function handle_input(player_id, input, state)
    local p = state.players[player_id]
    if not p or p.hp <= 0 then return state end

    if input.right then p.x = p.x + p.speed end
    if input.left then p.x = p.x - p.speed end

    if input.shoot and input.aim_x then
        table.insert(state.projectiles, {
            x = p.x, y = p.y,
            vx = input.aim_x - p.x,
            vy = input.aim_y - p.y,
            owner = player_id
        })
    end

    state.players[player_id] = p
    return state
end
```

This is the one callback with no execution budget - see
[Limits](#limits-and-what-happens-when-you-hit-them).

### `tick(state)`

Called every tick. A match ticks every 100 ms, and a match script cannot
change that. Advance the simulation and return the updated state.

```lua
function tick(state)
    state.time_elapsed = state.time_elapsed + 1

    if state.time_elapsed >= 900 then -- 90 seconds at 10 ticks/sec
        state._finished = true
        state._result = {
            status = "completed",
            winner = find_winner(state)
        }
    end

    return state
end
```

### `get_state(player_id, state)`

Called every tick for each player. Returns the state that player may see - use
it for fog of war, hidden hands, anything the client must not be told.

```lua
function get_state(player_id, state)
    return {
        phase = "playing",
        players = state.players,
        time_remaining = 900 - state.time_elapsed
    }
end
```

Under `state_strategy = "shared"` this becomes `get_state(state)`.

### Optional callbacks

`vote_requested(state)` is called after each tick. Return a vote configuration
to start a player vote, or `nil` to skip. Votes can start at any point:
between rounds, after a boss kill, on a level-up.

```lua
function vote_requested(state)
    if state.phase == "vote_pending" then
        return {
            template = "next_map",
            options = {
                { id = "forest", label = "Forest" },
                { id = "desert", label = "Desert" },
                { id = "snow", label = "Snow" }
            },
            method = "plurality",
            window_ms = 15000
        }
    end
    return nil
end
```

The match keeps running while a vote is active, and several votes can run at
once. See [Voting](voting.md).

`vote_resolved(template, result, state)` is called when a vote completes;
`result.winner` is the winning option id.

```lua
function vote_resolved(template, result, state)
    if template == "next_map" then
        state.next_map = result.winner
    end
    return state
end
```

`phases(config)`, `on_phase_started(phase_name, state)` and
`on_phase_ended(phase_name, state)` drive a session's lifecycle stages -
warmup, combat, results. Define `phases/1` and the engine walks the list in
order. See [Phases](phases.md).

## Modules and `require()`

Split a game across files with `require()`. There is no `package` table and no
`package.path` to set: `require` is asobi's own and resolves relative to the
directory of the script that was loaded.

```
game/
├── match.lua
├── physics.lua
├── boons.lua
└── bots/
    ├── chaser.lua
    └── sniper.lua
```

In `match.lua`:

```lua
local physics = require("physics")
local boons = require("boons")

function tick(state)
    state = physics.move_projectiles(state)
    state = physics.check_collisions(state)
    return state
end
```

In `physics.lua`:

```lua
local M = {}

function M.move_projectiles(state)
    for i, p in ipairs(state.projectiles or {}) do
        p.x = p.x + p.vx
        p.y = p.y + p.vy
    end
    return state
end

function M.check_collisions(state)
    return state
end

return M
```

Dotted names work: `require("bots.chaser")` loads `bots/chaser.lua`. Parent
traversal, absolute paths and symlinked module files are rejected.

## Finishing a match

Set `_finished = true` and `_result` on the state table in `tick()`:

```lua
function tick(state)
    if game_over(state) then
        state._finished = true
        state._result = {
            status = "completed",
            standings = build_standings(state),
            winner = find_winner(state)
        }
    end
    return state
end
```

`_result` is sent to every player as the `match.finished` event. Structure it
however you like; clients receive it as JSON.

## The game.* API

Scripts call engine features through the `game` table: logging, broadcasts,
economy, leaderboards, notifications, storage, chat, spatial queries, and any
namespace an installed [extension](extensions.md) declares. Around thirty
functions, each with its own argument shapes and return convention.

They are all in [The game.\* API](lua-api.md).

## World mode

Persistent or large-area games (open worlds, MMOs, big co-op maps) set
`game_type = "world"` and use a different callback set built around zones,
terrain and interest management.

[World server](world-server.md) owns that, and
[Large worlds](large-worlds.md) covers scaling it.

## Logging

`game.log` writes a structured line through the node's logger, so it lands in
the container's JSON log stream:

```lua
function handle_input(player_id, input, state)
    game.log("info", "input received", { player = player_id, kind = input.kind })
    return state
end
```

- Levels are `"debug"`, `"info"`, `"warn"`/`"warning"` and `"error"`. Anything
  else returns `{ error = ... }`.
- `message` may be a string or any value (tables are rendered as JSON), and is
  truncated at 500 characters.
- `meta` is an optional table. Over 2 KB of encoded JSON it is **dropped
  whole** and logged as `{"_truncated": true}`, not shortened - so split a
  large payload across several calls, or log a summary instead.
- Logging is rate limited to 30 lines a second per match or zone, with a
  node-wide ceiling of 300. Over budget `game.log` returns `false` and the line
  is dropped, so a log call in a tight tick loop degrades instead of flooding.
  Self-hosters can tune both budgets via the `rate_limits` key.

`print` and `eprint` do not exist: they wrote straight to stdout, breaking the
structured stream and giving a tight loop an unmetered flood path.

## Debugging script errors

A runtime error in a callback does not crash the match. The server logs it,
keeps the previous state and carries on, which from the client looks exactly
like the callback doing nothing. The classic first-hour version is
`state.counter = state.counter + 1` when `init` never set `counter`.

### Finding it in the logs

Grep for `lua callback failed`. The line carries:

- `callback` - which function failed.
- `script` - the script's basename.
- `reason_class` - `timeout` or `runtime_error`.
- `detail` - the Lua error message, capped at 500 characters.
- `suppressed_since_last` - how many identical failures were dropped since the
  last line got through.

That last field exists because these lines are rate limited to three every ten
seconds per script and callback. A gap in the log is not the failure stopping;
`suppressed_since_last` tells you what it really was. The telemetry counter
behind it is not rate limited, so a dashboard sees the true rate.

### Pushing errors to the client during development

Set `ASOBI_DEV_ERRORS=true` (`1` also works) on the container, or
`{asobi, [{dev_errors, true}]}` in `sys.config`. A failing `handle_input` then
also sends a `module.error` event to the player whose input triggered it:

```json
{"type": "module.error", "payload": {
    "module": "lua",
    "callback": "handle_input",
    "script": "match.lua",
    "message": "bad arithmetic + on nil, 1"
}}
```

The application-env key is consulted first and wins: with `{dev_errors,
false}` set, `ASOBI_DEV_ERRORS=true` does nothing.

These events come from a failing `handle_input` in a match, and from a failing
`handle_input` in a zone when the game runs in world mode. The rate limit is
one event per second per bridge process, so per match or per zone. The
deprecated `game.error` name carries the same payload alongside it until the
1.0 wire break - see [WebSocket protocol](websocket-protocol.md).

Leave the flag off in production; it is off by default. Error messages can
reveal script internals and players should never see them.

## Limits and what happens when you hit them

Every callback except `handle_input` runs in a child process under a wall-clock
budget, a heap cap and a reduction budget. A `while true do end` there is
killed at the deadline: the bridge logs, discards that call's result, keeps the
previous state and carries on with the next tick.

`handle_input` is the exception. It runs inline, because at high input rates
the spawn cost dominates the actual Lua work, and it therefore has no budget at
all. A runaway `handle_input` hangs that one match or zone indefinitely - no
timeout fires and no supervisor restarts it. Bound your own loops.

[Sandbox and limits](security-sandbox.md) has the per-callback numbers and the
reasoning.

## In Erlang

The same node, configured from `sys.config` instead of from script globals:

```erlang
{deps, [
    {asobi, "~> 0.68"}
]}.
```

```erlang
{asobi, [
    {game_modes, #{
        ~"arena" => #{
            module => {lua, "game/match.lua"},
            match_size => 4,
            max_players => 8
        }
    }}
]}
```

The operator's `game_modes` is never written by asobi and always wins a name
clash with a script-declared mode of the same name. The Lua loader itself still
runs at boot whether or not a game directory exists: with no `match.lua` and no
`config.lua` it declares no modes, but it does write `guest_auth` (to `false`),
which is what stops a stale `true` from a previous bundle surviving.

## Next steps

- [The game.\* API](lua-api.md) - everything a script can call.
- [Bots](lua-bots.md) - AI-controlled players.
- [World server](world-server.md) - zones and large sessions.
- [Configuration](configuration.md) - every asobi setting.
- [WebSocket protocol](websocket-protocol.md) - the client-server message
  format.
- [Self-hosting](self-hosting.md) - production deployment.
