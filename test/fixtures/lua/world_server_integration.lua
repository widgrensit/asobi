-- asobi#246 regression fixture: exercises spawn_templates, terrain_provider,
-- and phases exactly as asobi_world_server calls them in production - through
-- a real asobi_world_instance boot, not a hand-built #{lua_state := _} map.
match_size = 1
max_players = 8
game_type = "world"
grid_size = 1
zone_size = 1200
view_radius = 0

function spawn_templates(config)
    return {
        probe = {
            type = "object",
            base_state = { solid = true },
        },
    }
end

function phases(config)
    return {
        { name = "lobby", duration = 5000 },
    }
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
    zone_state = zone_state or {}
    if not zone_state.seeded then
        game.zone.spawn("probe", 500, 500)
        zone_state.seeded = true
    end
    return entities, zone_state
end

function handle_input(player_id, input, entities)
    return entities
end

function post_tick(tick_n, state)
    state.tick = tick_n
    return state
end
