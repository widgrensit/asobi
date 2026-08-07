-- Exercises the discovery-visibility globals on a world: listed and
-- quick_play, both of which default to true for a world, so this fixture
-- sets them false to prove the script value reaches the mode config.
match_size  = 1
max_players = 4
game_type   = "world"
listed      = false
quick_play  = false

function init(config) return {} end
function spawn_position(player_id, state) return { x = 0, y = 0 } end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function zone_tick(entities, zone_state) return entities, zone_state end
function handle_input(player_id, input, entities) return entities end
function post_tick(tick, state) return state end
function generate_world(seed, config) return { ["0,0"] = {} } end
