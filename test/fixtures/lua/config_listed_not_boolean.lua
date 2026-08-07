-- `listed = 0` means "off" to a Lua author (0 is truthy in Lua, but reads as
-- off in most other languages) and is not a Lua boolean. It must not be taken
-- as "listed", because the world default is true and that would fail open:
-- the script asked to hide the world and it would stay in the browser.
match_size  = 1
max_players = 4
game_type   = "world"
listed      = 0

function init(config) return {} end
function spawn_position(player_id, state) return { x = 0, y = 0 } end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function zone_tick(entities, zone_state) return entities, zone_state end
function handle_input(player_id, input, entities) return entities end
function post_tick(tick, state) return state end
function generate_world(seed, config) return { ["0,0"] = {} } end
