# Bots

Asobi includes built-in bot support. Bots run as server-side processes that
join matches as regular players -- no fake clients, no network overhead. The
AI logic runs in the same tick loop as the game.

## How It Works

1. A player queues for matchmaking
2. If no match is found within the configured wait time, Asobi adds bots
3. Bots join the match like regular players
4. Each tick, the bot calls a `think()` function to decide its input
5. Bot input goes through the same `handle_input` path as real players

## Configuration

### Lua (Docker)

Enable bots by adding `bots` to your match script globals and a `names`
list to your bot script:

```lua
-- match.lua
match_size = 4
max_players = 8
strategy = "fill"
bots = { script = "bots/chaser.lua" }
```

```lua
-- bots/chaser.lua
names = {"Spark", "Blitz", "Volt", "Neon", "Pulse"}

function think(bot_id, state)
    -- AI logic here
end
```

The platform reads `names` from your bot script at runtime. Bot names are
prefixed with `bot_` (e.g., `bot_Spark`).

Platform-level bot tuning is controlled via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `ASOBI_BOT_FILL_AFTER` | `8000` | Milliseconds before bots fill queue |
| `ASOBI_BOT_MIN_PLAYERS` | `match_size` | Fill up to this many players |

### Erlang (sys.config)

For Erlang OTP projects, configure bots in `sys.config`:

```erlang
{game_modes, #{
    ~"arena" => #{
        module => {lua, "game/match.lua"},
        match_size => 4,
        bots => #{
            enabled => true,
            fill_after_ms => 8000,
            min_players => 4,
            script => <<"game/bots/chaser.lua">>
        }
    }
}}
```

Bot names are read from the bot script's `names` global. If not defined,
defaults to `["Spark", "Blitz", "Volt", "Neon", "Pulse"]`.

## Writing a Bot AI Script

A bot script defines a single function: `think(bot_id, state)`. It receives
the current game state and returns an input table -- the same format a real
player would send.

```lua
-- game/bots/chaser.lua

function think(bot_id, state)
    local players = state.players or {}
    local me = players[bot_id]
    if not me then return {} end

    -- Find nearest enemy
    local target = find_nearest(bot_id, me, players)
    if not target then
        return wander()
    end

    -- Chase and shoot
    local dist = distance(me, target)
    return {
        right = target.x > me.x,
        left = target.x < me.x,
        down = target.y > me.y,
        up = target.y < me.y,
        shoot = dist < 200,
        aim_x = target.x,
        aim_y = target.y
    }
end

function find_nearest(bot_id, me, players)
    local nearest, min_dist = nil, 99999
    for id, p in pairs(players) do
        if id ~= bot_id and p.hp and p.hp > 0 then
            local d = distance(me, p)
            if d < min_dist then
                nearest, min_dist = p, d
            end
        end
    end
    return nearest
end

function distance(a, b)
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    return math.sqrt(dx * dx + dy * dy)
end

function wander()
    return {
        right = math.random(2) == 1,
        left = math.random(2) == 1,
        down = math.random(2) == 1,
        up = math.random(2) == 1,
        shoot = false
    }
end
```

## Multiple Bot Types

Create different AI scripts for different playstyles:

```
game/bots/
├── chaser.lua    -- rushes nearest player
├── sniper.lua    -- stays back, long range
├── healer.lua    -- supports teammates
└── camper.lua    -- holds position, ambushes
```

Currently, all bots in a game mode use the same script. To vary behavior,
add randomization inside your `think()` function:

```lua
local STRATEGIES = { "aggressive", "defensive", "random" }

function think(bot_id, state)
    -- Use bot_id hash to pick consistent strategy per bot
    local strategy = STRATEGIES[(#bot_id % #STRATEGIES) + 1]

    if strategy == "aggressive" then
        return chase(bot_id, state)
    elseif strategy == "defensive" then
        return defend(bot_id, state)
    else
        return wander()
    end
end
```

## Default AI

If no bot script is configured, bots use a built-in default AI that:

- Finds the nearest living enemy
- Moves toward them
- Shoots when within range (200 units)
- Adds slight aim randomization
- Wanders randomly if no targets are alive

This works for most arena-style games out of the box.

## Auto Boon Pick and Voting

Bots automatically handle game phases:

- **Boon pick**: Bots pick the first available option immediately
- **Voting**: Bots cast a random vote after a 1-3 second delay

This behavior is built-in and doesn't require any bot script code.

## Bot IDs

Bot player IDs are prefixed with `bot_` followed by their display name
(e.g., `bot_Spark`, `bot_Blitz`). Your game logic can check for bots:

```lua
function is_bot(player_id)
    return string.sub(player_id, 1, 4) == "bot_"
end
```

Clients receive bot players in the normal game state. Whether to show them
differently (e.g., "AI" tag) is up to the client.
