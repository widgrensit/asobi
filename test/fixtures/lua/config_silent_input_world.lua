-- World-bridge fixture: handle_input falls off its end and returns nothing at
-- all, which is what a script does when an author forgets the return. It must
-- cost that author their input, not the zone process every other player in the
-- zone is being simulated by.
match_size = 1
max_players = 16
game_type = "world"

function init(config) return { tick = 0 } end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function spawn_position(player_id, state) return { x = 0, y = 0 } end
function zone_tick(entities, zone_state) return entities, zone_state end

function handle_input(player_id, input, entities)
end

function post_tick(tick, state) return state end

function generate_world(seed, config)
    return { ["0,0"] = { tiles = {}, mobs = {} } }
end
