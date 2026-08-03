-- asobi_lua#110 regression fixture: a typo'd template_id must return false
-- synchronously from game.zone.spawn, not the true a caller would get just
-- because the (fire-and-forget) cast to the zone was sent.
match_size = 1
max_players = 8
game_type = "world"
grid_size = 1
zone_size = 1200
view_radius = 0

function spawn_templates(config)
    return {
        goblin = {
            type = "npc",
            base_state = { health = 100 },
        },
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
        zone_state.known_result = game.zone.spawn("goblin", 500, 500)
        zone_state.typo_result = game.zone.spawn("gobiln", 500, 500)
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
