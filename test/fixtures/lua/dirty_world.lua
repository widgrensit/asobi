match_size = 1
grid_size = 1
zone_size = 1000

zones = { ["0,0"] = {} }

function generate_world(seed)
  return zones
end

-- Moves "a", deletes "c", and mutates "b" WITHOUT declaring it. The
-- undeclared mutation must not land: the declaration is the truth
-- (widgrensit/asobi#557).
function zone_tick(entities, zone_state)
  local changed = {}
  if entities["a"] then
    entities["a"].x = entities["a"].x + 10
    changed["a"] = entities["a"]
  end
  if entities["b"] then
    entities["b"].x = 999
  end
  return entities, zone_state, false, { changed = changed, removed = { "c" } }
end

function handle_input(player_id, input, entities)
  return entities
end
