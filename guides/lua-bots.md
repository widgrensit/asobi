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

Bot scripts implement a `bot_tick` callback that runs each tick:

```lua
function bot_tick(bot_id, state, entities)
    -- Find nearest player
    local target = nil
    local min_dist = math.huge

    for id, entity in pairs(entities) do
        if entity.type == "player" and id ~= bot_id then
            local dx = entity.x - state.x
            local dy = entity.y - state.y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < min_dist then
                min_dist = dist
                target = entity
            end
        end
    end

    -- Move towards target
    if target then
        local dx = target.x - state.x
        local dy = target.y - state.y
        local len = math.sqrt(dx * dx + dy * dy)
        return {
            action = "move",
            x = state.x + (dx / len) * 2.0,
            y = state.y + (dy / len) * 2.0
        }
    end

    return nil
end
```

## Further Reading

See the full [`asobi_lua` documentation](https://hexdocs.pm/asobi_lua) for advanced
bot patterns including state machines, group coordination, and difficulty scaling.
