-- asobi_lua#110 + asobi#253 regression fixture (v2): the hot-reloaded edit
-- that adds a new `dragon` template. zone_tick spawns it immediately on the
-- reload tick, proving game.zone.spawn recognises it right away rather than
-- only on some later tick (or never, pre-fix).
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
        dragon = {
            type = "npc",
            base_state = { health = 500 },
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
    zone_state.dragon_result = game.zone.spawn("dragon", 700, 700)
    return entities, zone_state
end

function handle_input(player_id, input, entities)
    return entities
end

function post_tick(tick_n, state)
    state.tick = tick_n
    return state
end
