-- Exercises the world dimension globals: tick_rate, grid_size,
-- zone_size, view_radius, persistent. These flow through to the world
-- server via asobi_game_modes:world_config/1.
match_size  = 1
max_players = 4
game_type   = "world"
tick_rate   = 100
grid_size   = 1
zone_size   = 1500
view_radius = 0
persistent  = true

function init(config) return {} end
function spawn_position(player_id, state) return { x = 0, y = 0 } end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function zone_tick(entities, zone_state) return entities, zone_state end
function handle_input(player_id, input, entities) return entities end
function post_tick(tick, state) return state end
function generate_world(seed, config) return { ["0,0"] = {} } end
