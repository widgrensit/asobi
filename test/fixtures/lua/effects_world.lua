game_type = "world"
match_size = 1
grid_size = 3
zone_size = 100
border_band = 0.1

function init(config) return {} end
function generate_world(seed, config) return { ["0,0"] = {} } end
function zone_tick(entities, zone_state) return entities, zone_state end

function handle_input(player_id, input, entities)
  return entities
end

function handle_effects(effects, entities)
  for _, e in ipairs(effects) do
    local target = entities[e.entity_id]
    target.hp = (target.hp or 0) + (e.event.hp_delta or 0)
  end
  return entities
end
