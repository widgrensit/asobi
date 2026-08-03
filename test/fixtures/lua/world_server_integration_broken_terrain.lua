-- Same as world_server_integration.lua but DEFINES terrain_provider and
-- makes it raise, to prove a callback that exists and breaks is still
-- logged/telemetered (the positive case for the is_defined/2 guard).
match_size = 1
max_players = 8
game_type = "world"
grid_size = 1
zone_size = 1200
view_radius = 0

function spawn_templates(config)
    return {}
end

function terrain_provider(config)
    error("boom")
end

function init(config)
    return { tick = 0 }
end

function generate_world(seed, config)
    return { ["0,0"] = {} }
end

function spawn_position(player_id, state)
    return { x = 600, y = 600 }
end

function join(player_id, state)  return state end
function leave(player_id, state) return state end

function zone_tick(entities, zone_state)
    return entities, zone_state or {}
end

function handle_input(player_id, input, entities)
    return entities
end

function post_tick(tick_n, state)
    state.tick = tick_n
    return state
end
