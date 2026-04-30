game_type      = "world"
match_size     = 1
max_players    = 8
tick_rate      = 50
grid_size      = 1
zone_size      = 1200
view_radius    = 0
empty_grace_ms = 10000

function init(config)
    return { tick = 0 }
end

function generate_world(seed, config)
    return { ["0,0"] = {} }
end

function spawn_position(player_id, state)
    math.randomseed(#player_id + (state.tick or 0))
    local angle = math.random() * math.pi * 2
    return {
        x = 600 + math.cos(angle) * 80,
        y = 600 + math.sin(angle) * 80,
    }
end

function join(player_id, state)    return state end
function leave(player_id, state)   return state end

function handle_input(player_id, input, entities)
    if not input or input.kind ~= "move" then return entities end
    entities[player_id] = {
        type  = "player",
        x     = tonumber(input.x) or 0,
        y     = tonumber(input.y) or 0,
        color = input.color,
    }
    return entities
end

function zone_tick(entities, zone_state)
    return entities, zone_state
end

function post_tick(tick_n, state)
    state.tick = tick_n
    return state
end
