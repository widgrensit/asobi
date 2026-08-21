-- Mutates an entity the CLIENT names and then returns nothing, which is the
-- "apply optimistically, reject on validation" shape.
--
-- Under handle_input/3 the mutation is discarded: Erlang keeps its own copy of
-- the map and an empty return means "leave the entities alone". The batch hands
-- the script the Luerl table itself, so it has to get the same answer by
-- reverting the Luerl state - otherwise a handler that looks its target up from
-- a client-controlled field and rejects with a bare `return` is a write
-- primitive on any entity in the zone.

game_type   = "world"
match_size  = 1
max_players = 8
grid_size   = 1
zone_size   = 500
view_radius = 0

function init(config)
    return {}
end

function zone_tick(entities, zone_state)
    return entities, zone_state
end

function post_tick(tick_n, state)
    return state
end

function handle_input(player_id, input, entities)
    local victim = entities[input.target or player_id]
    if victim then
        victim.hp = 0
    end
    return
end
