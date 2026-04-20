# Bots

Asobi supports AI-controlled bot players that participate in matches and worlds
alongside real players. Bots are configured per game mode and scripted in Lua
via the [`asobi_lua`](https://hexdocs.pm/asobi_lua) package.

## Configuration

Enable bots in your game mode configuration:

```erlang
{game_modes, #{
    ~"deathmatch" => #{
        game_module => my_game,
        bots => #{
            enabled => true,
            count => 4,
            script => ~"bots/patrol.lua",
            fill => true
        }
    }
}}
```

| Option | Default | Description |
|--------|---------|-------------|
| `enabled` | `false` | Enable bot spawning |
| `count` | `0` | Number of bots to spawn |
| `script` | `undefined` | Path to bot Lua script |
| `fill` | `false` | Auto-fill empty slots with bots |

## Lua Bot Scripts

Bot scripts implement a top-level `think` callback that runs each bot tick.
It receives the bot's own ID and the latest match state for that bot and
returns an input table (or an empty table to skip the tick):

```lua
function think(bot_id, state)
    local players = state.players or {}
    local me = players[bot_id]
    if not me then return {} end

    -- Find nearest other player
    local target = nil
    local min_dist = math.huge
    for id, p in pairs(players) do
        if id ~= bot_id then
            local dx = p.x - me.x
            local dy = p.y - me.y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < min_dist then
                min_dist = dist
                target = p
            end
        end
    end

    if target then
        return {
            right = target.x > me.x,
            left  = target.x < me.x,
            up    = target.y < me.y,
            down  = target.y > me.y,
        }
    end
    return {}
end
```

## Further Reading

See the full [`asobi_lua` documentation](https://hexdocs.pm/asobi_lua) for advanced
bot patterns including state machines, group coordination, and difficulty scaling.
