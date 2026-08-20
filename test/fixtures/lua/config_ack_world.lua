-- World-bridge fixture: handle_input reports the client seq it consumed as a
-- second return value, which is what a script batching several simulation
-- steps into one frame does so the world.ack names what RAN, not what arrived.
match_size = 1
max_players = 16
game_type = "world"

function init(config) return { tick = 0 } end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function spawn_position(player_id, state) return { x = 0, y = 0 } end
function zone_tick(entities, zone_state) return entities, zone_state end

-- Reports whatever the test hands it, INCLUDING nothing, so the absent and
-- invalid cases are exercisable from one fixture. A real script must report on
-- every input or on none: `input.consumed` going nil on some inputs is the
-- mixed mode the asobi_world callback docs warn about.
function handle_input(player_id, input, entities)
    entities[player_id] = { type = "player", x = input.x or 0, y = input.y or 0 }
    return entities, input.consumed
end

function post_tick(tick, state) return state end

function generate_world(seed, config)
    return { ["0,0"] = { tiles = {}, mobs = {} } }
end
