game_type      = "world"
match_size     = 1
max_players    = 8
tick_rate      = 50
grid_size      = 1
zone_size      = 1200
view_radius    = 0
empty_grace_ms = 10000

function spawn_templates(config)
    return {
        goblin = {
            type       = "npc",
            base_state = { health = 100, ai = "patrol" },
            respawn    = { delay = 5000, jitter = 1000 },
        },
        ore = {
            type       = "resource",
            base_state = { quantity = 5 },
            respawn    = { delay = 3000, max_respawns = 2 },
        },
        chest = {
            type       = "object",
            base_state = { loot = "common" },
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
        game.zone.spawn("goblin", 500, 500)
        game.zone.spawn("ore", 700, 650)
        game.zone.spawn("chest", 620, 600, { loot = "rare" })
        zone_state.seeded = true
    end
    return entities, zone_state
end

function handle_input(player_id, input, entities)
    if input and input.kind == "drop_chest" then
        game.zone.spawn("chest", tonumber(input.x) or 0, tonumber(input.y) or 0)
    end
    entities[player_id] = { type = "player", x = input.x, y = input.y }
    return entities
end

function post_tick(tick_n, state)
    state.tick = tick_n
    return state
end
