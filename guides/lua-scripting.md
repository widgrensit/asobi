# Lua Scripting

Lua scripting support is provided by the [`asobi_lua`](https://hexdocs.pm/asobi_lua) package,
a standalone runtime that wraps the asobi library with [Luerl](https://github.com/rvirding/luerl)
for writing game logic in Lua.

## Quick Start

The fastest way to get started is with the Docker image:

```bash
docker run -v ./game:/game -p 8080:8080 ghcr.io/widgrensit/asobi_lua
```

Place your Lua scripts in the `game/` directory and the runtime picks them up automatically.

## Game Callbacks

Your Lua scripts implement callbacks that asobi invokes at the right time:

### Match Mode

```lua
function init(config)
    return { score = {} }
end

function join(player_id, state)
    state.score[player_id] = 0
    return state
end

function tick(state)
    -- To finish the match, set reserved keys on the state and return it:
    --   state._finished = true
    --   state._result   = { winner = "..." }
    return state
end

function handle_input(player_id, input, state)
    return state
end
```

### World Mode

```lua
function init(config)
    return {}
end

function join(player_id, state)
    return state
end

function spawn_position(player_id, state)
    return { x = 100.0, y = 100.0 }
end

function zone_tick(entities, zone_state)
    return entities, zone_state
end

function handle_input(player_id, input, entities)
    return entities
end

function post_tick(tick, state)
    return state
end
```

## Lua API

The `game.*` namespace provides access to engine features from Lua:

| Function | Description |
|----------|-------------|
| `game.id()` | Generate a unique ID |
| `game.broadcast(event, payload)` | Broadcast to all players |
| `game.send(player_id, message)` | Send to a specific player |
| `game.economy.grant(player, currency, amount, reason)` | Grant currency |
| `game.economy.debit(player, currency, amount, reason)` | Debit currency |
| `game.economy.balance(player_id)` | Return the player's full wallet list |
| `game.economy.purchase(player, listing_id)` | Purchase store item |
| `game.leaderboard.submit(board, player, score)` | Submit score |
| `game.leaderboard.top(board, limit)` | Get top scores |
| `game.storage.get(collection, key)` | Read storage value |
| `game.storage.set(collection, key, value)` | Write storage value |
| `game.chat.send(channel, player, content)` | Send chat message |

## Further Reading

See the full [`asobi_lua` documentation](https://hexdocs.pm/asobi_lua) for:

- Configuration options
- Bot scripting
- Advanced patterns
- Docker deployment
