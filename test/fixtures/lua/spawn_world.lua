-- World fixture exercising spawn_templates + game.zone.spawn end-to-end.
-- zone_tick seeds the zone once on the first tick; the spawn cast is handled
-- by the live asobi_zone process, so the entity appears in the zone's entity
-- map a tick later.
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
            base_state = { health = 100, ai = "patrol" },
            respawn = { delay = 5000, jitter = 1000 },
        },
        chest = {
            type = "object",
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
        game.zone.spawn("chest", 620, 600, { loot = "rare" })
        -- asobi#246: an empty overrides table must be accepted like the
        -- 3-arg form, not rejected (it decodes to [] via deep_decode, not #{}).
        game.zone.spawn("chest", 640, 600, {})
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
