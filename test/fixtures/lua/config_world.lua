-- World mode match script with zone config
match_size = 1
max_players = 100
lazy_zones = true
zone_idle_timeout = 60000
max_active_zones = 500

function init(config)
    return { players = {} }
end

function join(player_id, state)
    state.players[player_id] = { x = 0, y = 0 }
    return state
end

function leave(player_id, state)
    state.players[player_id] = nil
    return state
end

function handle_input(player_id, input, state)
    return state
end

function tick(state)
    return state
end

function get_state(player_id, state)
    return state
end

function terrain_provider(config)
    return nil
end

function on_zone_loaded(cx, cy, state)
    local zone_state = { biome = "plains" }
    return zone_state, state
end

function on_zone_unloaded(cx, cy, state)
    return state
end
