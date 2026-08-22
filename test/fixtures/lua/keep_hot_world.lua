game_type = "world"
match_size = 1
grid_size = 3
zone_size = 100

function init(config) return {} end
function generate_world(seed, config) return { ["0,0"] = {} } end
function spawn_position(player_id, state) return { x = 10, y = 10 } end
function handle_input(player_id, input, entities) return entities end

-- A wave spawner: no entities between waves, and a countdown asobi cannot see.
function zone_tick(entities, zone_state)
  zone_state = zone_state or {}
  zone_state.next_wave = (zone_state.next_wave or 3) - 1
  zone_state._keep_hot = zone_state.next_wave > 0
  return entities, zone_state
end
