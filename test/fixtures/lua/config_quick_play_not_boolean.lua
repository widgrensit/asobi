-- `quick_play = "false"` is a string, not a Lua boolean. quick_play defaults
-- to true on every kind, so taking it as a value would leave the mode in
-- find_or_create rotation after the script asked to be out of it.
match_size  = 1
max_players = 4
game_type   = "world"
quick_play  = "false"

function init(config) return {} end
function spawn_position(player_id, state) return { x = 0, y = 0 } end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function zone_tick(entities, zone_state) return entities, zone_state end
function handle_input(player_id, input, entities) return entities end
function post_tick(tick, state) return state end
function generate_world(seed, config) return { ["0,0"] = {} } end
