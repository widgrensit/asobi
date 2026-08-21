-- Fixture for the #426 Luerl collector tests. zone_tick keeps a counter in
-- game_state so a test can prove the state survives a collection, and
-- big_state builds a persistent live table so a test can drive the adaptive
-- interval's backoff.

function init(config)
  return { n = 0 }
end

function zone_tick(entities, gs)
  gs = gs or { n = 0 }
  gs.n = gs.n + 1
  return entities, gs
end

function big_state(n)
  local t = {}
  for i = 1, n do
    t[i] = { id = i, x = i * 1.5, y = i * 2.5, name = 'entity_' .. i }
  end
  return { world = t, n = 0 }
end

-- #536: allocates a fixed amount of Lua garbage regardless of how large the
-- state behind it already is. Used to prove the eval's heap budget measures
-- what the callback allocated and not what it was handed.
function churn(n)
  local last
  for i = 1, n do
    last = { id = i, x = i * 1.5, name = 'churn_' .. i }
  end
  return last
end
