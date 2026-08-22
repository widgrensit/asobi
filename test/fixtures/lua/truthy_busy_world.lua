game_type = "world"
match_size = 1
grid_size = 3
zone_size = 100

function init(config) return {} end
function generate_world(seed, config) return { ["0,0"] = {} } end
function spawn_position(player_id, state) return { x = 10, y = 10 } end
function handle_input(player_id, input, entities) return entities end

-- Returns a number, which is truthy in Lua. A countdown written the obvious way
-- produces exactly this.
function zone_tick(entities, zone_state)
  return entities, zone_state or {}, 3
end
