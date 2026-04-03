# Lua Scripting

Write your game logic in Lua instead of Erlang. Asobi runs Lua scripts
inside the BEAM via [Luerl](https://github.com/rvirding/luerl), giving you
the fault tolerance and concurrency of OTP with a language game developers
already know.

## Quick Start

Create a `game/` directory with your match script:

```
my_game/
├── game/
│   └── match.lua
├── rebar.config
└── config/
    └── dev_sys.config.src
```

Write your match logic:

```lua
-- game/match.lua

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

Configure your game mode to use the Lua script:

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

Start the server and your Lua match logic runs inside the BEAM.

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
vote, or `nil` to skip.

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
