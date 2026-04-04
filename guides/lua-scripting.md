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
    image: ghcr.io/widgrensit/asobi:latest
    depends_on:
      postgres: { condition: service_healthy }
    ports:
      - "8080:8080"
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
```

| Global | Required | Default | Description |
|--------|----------|---------|-------------|
| `match_size` | yes | -- | Minimum players needed to start a match |
| `max_players` | no | `match_size` | Maximum players per match |
| `strategy` | no | `"fill"` | Matchmaking strategy |
| `bots` | no | none | Bot configuration (see [Bots](lua-bots.md)) |

## Using with Erlang Projects

If you're building an Erlang OTP application that depends on asobi,
configure Lua game modes in your `sys.config` instead:

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

- **Standard Lua**: `table`, `string`, `math`, `pairs`, `ipairs`, `type`, `tostring`, `tonumber`, etc.
- **`math.random(n)`**: Random integer 1..n (uses Erlang's `rand` module)
- **`math.sqrt(n)`**: Square root
- **`require(module)`**: Load other Lua files from your game directory

For safety, filesystem and OS functions (`io`, `os.execute`, `loadfile`) are
**not** available. Your scripts run sandboxed inside the BEAM.

## Next Steps

- [Bots](lua-bots.md) -- add AI-controlled players to your game
- [Configuration](configuration.md) -- all Asobi configuration options
- [WebSocket Protocol](websocket-protocol.md) -- client-server message format
