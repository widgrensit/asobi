game_type = "world"
match_size = 1
grid_size = 3
zone_size = 100

function init(config) return {} end
function generate_world(seed, config) return { ["0,0"] = {} } end
function spawn_position(player_id, state) return { x = 10, y = 10 } end
function handle_input(player_id, input, entities) return entities end

-- Ordinary OOP Lua. Under the field design this __index ran inline on the zone
-- process for every absent-key read, with no timeout and no heap cap.
local Zone = {}
Zone.__index = function(_t, _k)
  local n = 0
  for i = 1, 2000000 do n = n + i end
  return n
end

function zone_tick(entities, zone_state)
  zone_state = zone_state or setmetatable({}, Zone)
  return entities, zone_state
end
