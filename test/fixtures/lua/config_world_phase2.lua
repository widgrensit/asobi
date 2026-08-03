-- World mode with Phase 2 config (spatial grid + cold tick divisor)
match_size = 1
max_players = 50
lazy_zones = true
zone_idle_timeout = 30000
max_active_zones = 200
spatial_grid_cell_size = 64
cold_tick_divisor = 5

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
