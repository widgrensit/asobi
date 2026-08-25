match_size = 1
grid_size = 1
zone_size = 1000

zones = { ["0,0"] = {} }

function generate_world(seed)
  return zones
end

-- The mode rides on an entity rather than on zone_state: asobi hands the
-- entity map to luerl:encode, whereas the second argument is passed through
-- as-is, so a test cannot put a plain Erlang term there.
--
-- Each branch used to be a way to take the zone down or to silently freeze it
-- (widgrensit/asobi#557 review).
function zone_tick(entities, zone_state)
  local mode = entities.probe and entities.probe.mode or "none"
  -- Bumped so a caller can tell "asobi decoded what I returned" (x == 2) from
  -- "asobi kept the map it handed me" (x == 1). Without a mutation the two
  -- paths are byte-identical and nothing here would discriminate.
  entities.a.x = entities.a.x + 1
  if mode == "function" then
    return entities, zone_state, false, function() return 1 end
  elseif mode == "recursive" then
    local d = {}
    d.changed = d
    return entities, zone_state, false, d
  elseif mode == "array" then
    return entities, zone_state, false, { changed = { "a", "b" } }
  elseif mode == "not_a_declaration" then
    return entities, zone_state, false, { "a", "b" }
  elseif mode == "number" then
    return entities, zone_state, false, 42
  elseif mode == "nil_fourth" then
    return entities, zone_state, false, nil
  end
  return entities, zone_state
end

function handle_input(player_id, input, entities)
  return entities
end
