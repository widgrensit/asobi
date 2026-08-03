-- widgrensit/asobi#270 end-to-end regression fixture: a minimal Lua world
-- with two zones, used to prove a Lua-world player actually re-homes across
-- a zone boundary through a REAL asobi_zone process (not just that the
-- returned entity map has the right key shape).
match_size = 1
max_players = 8
game_type = "world"
grid_size = 4
zone_size = 100
view_radius = 1

function init(config) return {} end

function generate_world(seed, config)
    return { ["0,0"] = {}, ["1,0"] = {} }
end

function spawn_position(player_id, state) return { x = 50, y = 50 } end

function join(player_id, state) return state end
function leave(player_id, state) return state end
function zone_tick(entities, zone_state) return entities, zone_state end

function handle_input(player_id, input, entities)
    if input and input.kind == "move" then
        entities[player_id] = {
            type = "player",
            x = input.x or 50,
            y = input.y or 50,
        }
    end
    return entities
end

function post_tick(tick_n, state) return state end
