-- widgrensit/asobi#574: a lazily-loaded zone gets its zone_state from the
-- world's on_zone_loaded, and the zone script sees it as its zone_state on
-- the very first tick.
match_size = 8
max_players = 8
game_type = "world"

function init(_)
    return {}
end

function spawn_position(_, _)
    return { x = 100, y = 100 }
end

function generate_world(_, _)
    return {}
end

function join(_, state)
    return state
end

function leave(_, state)
    return state
end

function on_zone_loaded(cx, cy, state)
    return { biome = "plains", cx = cx, cy = cy }, state
end

function zone_tick(entities, zone_state)
    if zone_state ~= nil and zone_state.biome ~= nil then
        entities["marker"] = {
            x = 0,
            y = 0,
            type = "marker",
            biome = zone_state.biome,
            cx = zone_state.cx,
            cy = zone_state.cy,
        }
    end
    return entities, zone_state
end

function handle_input(_, _, entities)
    return entities
end

function post_tick(_, state)
    return state
end
