# Lua Scripting

Write your game logic in Lua instead of Erlang. Asobi runs Lua scripts
inside the BEAM via [Luerl](https://github.com/rvirding/luerl), giving you
the fault tolerance and concurrency of OTP with a language game developers
already know.

No Erlang knowledge required. No compilation step. Just Lua files and Docker.

## Quick Start with Docker

The fastest way to get started -- no Erlang toolchain needed:

```bash
mkdir my_game && cd my_game
mkdir -p lua/bots
```

Create your match script:

```lua
-- lua/match.lua

-- Game mode config
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

Create a `docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16
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
    image: ghcr.io/widgrensit/asobi_lua:latest
    depends_on:
      postgres: { condition: service_healthy }
    ports:
      - "8084:8084"
    volumes:
      - ./lua:/app/game:ro
    environment:
      ASOBI_DB_HOST: postgres
      ASOBI_DB_NAME: my_game_dev
```

Start it:

```bash
docker compose up -d
```

That's it. Your game is running. Asobi reads your Lua scripts from the
mounted volume, discovers the game mode from `match.lua`, and handles
everything else -- database, authentication, matchmaking, WebSockets.

### Multiple Game Modes

For games with more than one mode, add a `config.lua` manifest:

```lua
-- lua/config.lua
return {
    arena = "arena/match.lua",
    ctf   = "ctf/match.lua"
}
```

```
my_game/
├── lua/
│   ├── config.lua
│   ├── arena/
│   │   └── match.lua
│   └── ctf/
│       └── match.lua
└── docker-compose.yml
```

Each match script declares its own config as globals. When `config.lua`
exists, Asobi reads it instead of looking for a top-level `match.lua`.
When there is no `config.lua`, a single `match.lua` is loaded as the
`"default"` game mode.

## Match Script Globals

Declare your game mode settings as globals at the top of your match script.
Asobi reads these at startup before calling any callbacks.

```lua
match_size   = 4                          -- required: min players to start
max_players  = 10                         -- optional: max per match (defaults to match_size)
strategy     = "fill"                     -- optional: "fill" or "skill_based"
bots         = { script = "bots/ai.lua" } -- optional: enable bot filling
guest_auth   = true                       -- optional: allow anonymous guest play
```

| Global | Required | Default | Description |
|--------|----------|---------|-------------|
| `match_size` | yes | -- | Minimum players needed to start a match |
| `max_players` | no | `match_size` | Maximum players per match |
| `strategy` | no | `"fill"` | Matchmaking strategy |
| `bots` | no | none | Bot configuration (see [Bots](lua-bots.md)) |
| `guest_auth` | no | `false` | Enable anonymous guest play. Also requires an operator-supplied pepper; on iff both are present (asobi ADR 0004) |
| `lazy_zones` | no | auto | On-demand zone loading (auto-enabled for grids > 100) |
| `zone_idle_timeout` | no | 30000 | Milliseconds before an idle zone is reaped |
| `max_active_zones` | no | 10000 | Maximum concurrent zones in memory |
| `spatial_grid_cell_size` | no | none | Cell size for spatial grid indexing (enables grid acceleration) |
| `cold_tick_divisor` | no | 10 | Tick rate divisor for cold (unoccupied) zones |

For a single-mode game these globals live in `match.lua`. In a multi-mode game
(a `config.lua` manifest that maps modes to match scripts), deployment-wide
settings such as `guest_auth` go in `config.lua`, not the per-mode scripts.

## Using with Erlang Projects

If you're building an Erlang OTP application, add `asobi_lua` as a
dependency in your `rebar.config`:

```erlang
{deps, [
    {asobi_lua, {git, "https://github.com/widgrensit/asobi_lua.git", {tag, "v0.1.0"}}}
]}.
```

Configure Lua game modes in your `sys.config`:

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

The Lua config loader only runs when a game directory with scripts exists.
Erlang projects with their own `sys.config` are completely unaffected.

## Callbacks

Every Lua match script must define these functions:

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

### `join(player_id, state)`

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

### `leave(player_id, state)`

Called when a player leaves. Returns the updated state.

```lua
function leave(player_id, state)
    state.players[player_id] = nil
    return state
end
```

### `handle_input(player_id, input, state)`

Called when a player sends input via WebSocket. The `input` table contains
whatever the client sent. Returns the updated state.

```lua
function handle_input(player_id, input, state)
    local p = state.players[player_id]
    if not p or p.hp <= 0 then return state end

    -- Movement
    if input.right then p.x = p.x + p.speed end
    if input.left then p.x = p.x - p.speed end

    -- Shooting
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

### `tick(state)`

Called every tick (default 10 times per second). Advance your simulation here.
Returns the updated state.

To signal that the match is finished, set `_finished` and `_result` on the
state:

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

Called every tick for each player. Returns the state visible to that player.
Use this for fog-of-war, hiding other players' data, etc.

```lua
function get_state(player_id, state)
    return {
        phase = "playing",
        players = state.players,
        time_remaining = 900 - state.time_elapsed
    }
end
```

### `vote_requested(state)` (optional)

Called after each tick. Return a vote configuration table to start a player
vote, or `nil` to skip. Votes can be triggered at any point during gameplay -
between rounds, after a boss kill, when a player levels up, or any other
game event.

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

Mid-game example (roguelike ability choice):

```lua
function vote_requested(state)
    if state.pending_vote then
        local vote = state.pending_vote
        state.pending_vote = nil
        return vote
    end
    return nil
end

function tick(state)
    -- Trigger a vote when party reaches XP threshold
    if state.party_xp >= state.next_level_xp and not state.pending_vote then
        state.pending_vote = {
            template = "choose_ability",
            options = random_abilities(3),
            method = "plurality",
            window_ms = 15000
        }
    end
    return state
end
```

The game keeps running while a vote is active. Multiple votes can run
simultaneously.

### `vote_resolved(template, result, state)` (optional)

Called when a vote completes. `result.winner` contains the winning option ID.

```lua
function vote_resolved(template, result, state)
    if template == "next_map" then
        state.next_map = result.winner
    end
    return state
end
```

## Modules and `require()`

Split your game into multiple files using Lua's `require()`. Asobi
automatically sets `package.path` to your script's directory.

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
    -- collision detection logic
    return state
end

return M
```

## Finishing a Match

Set `_finished = true` and `_result` on your state table in `tick()`:

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

The `_result` table is sent to all players via the `match.finished` WebSocket
event. Structure it however you like -- clients will receive it as JSON.

## Available Functions

Your Lua scripts have access to:

- **Standard Lua**: `table`, `string`, `math`, `utf8`, `bit32`, `pairs`,
  `ipairs`, `next`, `type`, `tostring`, `tonumber`, `pcall`, `error`,
  `assert`, `setmetatable`/`getmetatable`, `rawget`/`rawset`/`rawequal`/`rawlen`
- **Time helpers**: `os.clock`, `os.date`, `os.difftime`, `os.time`
- **`math.random(n)`**: integer in `[1, n]`. **`math.random(a, b)`**:
  integer in `[a, b]`; an empty interval (`a > b`) raises, as in
  standard Lua. Non-integer bounds are truncated toward zero (standard
  Lua raises instead). The RNG is auto-seeded per match, so
  **`math.randomseed` has no effect** — calling it is harmless, but
  scripts cannot rely on seeded determinism.
- **`math.sqrt(n)`**: square root. Negative input returns `0.0`.
- **`require("foo.bar")`**: loads `foo/bar.lua` relative to your game
  directory. Names are validated; `..`, `/`, and absolute paths are
  rejected. Modules are cached, and `asobi_lua_match` clears the cache
  on hot-reload so changes to required files pick up.
- **`game.log(level, message[, meta])`**: structured logging - see
  [Logging](#logging) below. `print` is removed; use this instead.

The following are removed from the Lua environment:

- **OS escape hatches**: `os.execute`, `os.exit`, `os.getenv`,
  `os.remove`, `os.rename`, `os.tmpname`
- **Code loaders**: `dofile`, `loadfile`, `load`, `loadstring`
- **I/O**: the entire `io` library (`io.open`, `io.read`, `io.write`, ...)
- **Package machinery**: `package` and the default `require`. Use the
  asobi_lua-controlled `require/1` described above instead.

Every Lua callback also runs under a wall-clock timeout. A `while true do end`
in any callback is killed when the budget elapses; the bridge logs a warning
and continues with the previous state. See [SECURITY.md](../SECURITY.md#sandbox-model)
for the full sandbox model and per-callback timeout limits.

## World Mode: Large Sessions with Zones

For persistent or large-area games (MMOs, open worlds), use world mode instead
of match mode. World scripts support zone lifecycle and terrain features.

### Zone Configuration

Set zone globals at the top of your world script:

```lua
match_size = 1
max_players = 100
lazy_zones = true              -- load zones on demand
zone_idle_timeout = 60000      -- reap idle zones after 60s
max_active_zones = 500         -- cap concurrent zones
spatial_grid_cell_size = 64    -- spatial grid cell size for fast queries
cold_tick_divisor = 5          -- tick slower in unoccupied zones
```

### Terrain Provider (optional)

Return a terrain provider module from `terrain_provider()`. The provider
supplies compressed chunk data for each zone coordinate.

```lua
function terrain_provider(config)
    return {
        module = "my_terrain_provider",
        args = { tileset = "overworld" }
    }
end
```

Return `nil` to disable terrain.

### Zone Lifecycle Callbacks (optional)

```lua
function on_zone_loaded(cx, cy, state)
    -- Called when a zone is lazily loaded
    local zone_state = { biome = "plains", spawned = false }
    return zone_state, state
end

function on_zone_unloaded(cx, cy, state)
    -- Called when a zone is reaped after idle timeout
    return state
end
```

### Terrain API

Inside your game scripts, query terrain via the `game.terrain` namespace:

```lua
-- Get compressed chunk data for a coordinate
local result = game.terrain.get_chunk(3, 7)

-- Preload chunks around the player
game.terrain.preload({
    { cx = 3, cy = 7 },
    { cx = 4, cy = 7 },
    { cx = 3, cy = 8 }
})
```

### Spatial Queries (Zone-Based)

Query entities in the current zone by position. These use the zone's spatial
grid when `spatial_grid_cell_size` is set, falling back to brute-force scan.

```lua
-- Find all entities within radius of a point
local nearby = game.spatial.query_radius(100, 200, 50)
for _, hit in ipairs(nearby) do
    game.log("debug", "nearby entity", { id = hit.id, x = hit.x, y = hit.y })
end

-- Find all entities inside a rectangle
local in_area = game.spatial.query_rect(0, 0, 400, 300)
```

Both return a list of `{id, x, y}` tables.

The entity-table variants (`game.spatial.query_radius(entities, x, y, radius)`)
still work for client-side filtering without a zone process.

## Logging

`game.log` writes a structured line through the server's logger, so it shows
up in the container's log stream and, on managed cloud, in the console log
viewer for your environment (filter on `game.log`):

```lua
function handle_input(player_id, input, state)
    game.log("info", "input received", { player = player_id, kind = input.kind })
    -- ...
    return state
end
```

- Levels: `"debug"`, `"info"`, `"warn"`/`"warning"`, `"error"`. Anything
  else returns `{ error = ... }`.
- `message` can be a string or any value (tables are rendered as JSON).
  Messages are capped at 500 characters.
- `meta` is an optional table of key/values, capped at 2 KB.
- Logging is rate-limited (30 lines per second per match or zone, with a
  node-wide cap of 300). Over budget, `game.log` returns `false` and the
  line is dropped - so a log call in a tight tick loop degrades gracefully
  instead of flooding the log stream. Self-hosting operators can tune both
  budgets via `{asobi_lua, rate_limits}` if log-pipeline cost matters -
  the defaults allow up to ~2.5 KB x 300 lines per second per node at
  the ceiling.

`print` does not exist in the sandbox; it was removed because it bypassed
the structured log stream. `game.log` is the supported way to see what your
server is doing.

## Debugging Script Errors

A runtime error in a callback never crashes the match: the server logs the
error, keeps the previous state, and carries on. From the client that looks
like the callback silently doing nothing. A common first-hour trap is
`state.counter = state.counter + 1` when `init` never set `counter`, which
fails every call with "bad arithmetic on nil".

During development, set `ASOBI_DEV_ERRORS=true` on the container to have
each failing `handle_input` also send a `game.error` event to the player
whose input triggered it:

```json
{"type": "game.error", "payload": {
    "callback": "handle_input",
    "script": "match.lua",
    "message": "bad arithmetic + on nil, 1"
}}
```

Events are rate-limited to one per second per match. Leave the flag off in
production (it is off by default): error messages can reveal script
internals, and players should never see them.

## Next Steps

- [Bots](lua-bots.md) -- add AI-controlled players to your game
- [Self-hosting](self-hosting.md) -- production deployment and live updates
- [Configuration](https://asobi.dev/docs/configuration) -- all Asobi configuration options
- [WebSocket Protocol](https://asobi.dev/docs/protocols/websocket) -- client-server message format
