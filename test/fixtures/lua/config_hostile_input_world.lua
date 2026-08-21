-- World-bridge fixture for the ways a script's handle_input return can be
-- hostile to the zone process every player in that zone is simulated by:
-- a self-referential table (luerl:decode/2 raises on it), a number wider than
-- the ack space, and a first return value that is not entities at all.
match_size = 1
max_players = 16
game_type = "world"

function init(config) return { tick = 0 } end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function spawn_position(player_id, state) return { x = 0, y = 0 } end
function zone_tick(entities, zone_state) return entities, zone_state end

function handle_input(player_id, input, entities)
    if input.kind == "cyclic" then
        local t = {}
        t.self = t
        return entities, t
    elseif input.kind == "huge" then
        return entities, 1e308
    elseif input.kind == "scalar" then
        return "not entities at all"
    end
    return entities
end

function post_tick(tick, state) return state end

function generate_world(seed, config)
    return { ["0,0"] = { tiles = {}, mobs = {} } }
end
