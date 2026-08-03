-- World-bridge fixture: handle_input applies move inputs so tests can
-- verify the Erlang proc-dict plumbing invokes Lua correctly.
match_size = 1
max_players = 16
game_type = "world"

function init(config) return { tick = 0 } end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function spawn_position(player_id, state) return { x = 0, y = 0 } end
function zone_tick(entities, zone_state) return entities, zone_state end

function handle_input(player_id, input, entities)
    if input and input.kind == "move" then
        entities[player_id] = {
            type = "player",
            x = input.x or 0,
            y = input.y or 0,
        }
    end
    return entities
end

function post_tick(tick, state) return state end

function generate_world(seed, config)
    return { ["0,0"] = { tiles = {}, mobs = {} } }
end
