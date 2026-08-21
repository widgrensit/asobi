-- Strict globals, the ordinary idiom: declare everything, then lock _G.
-- guides/security-trust-model.md explicitly permits setmetatable(_G, ...).
function init(config) return { n = 0 } end

function zone_tick(entities, gs)
  gs = gs or { n = 0 }
  gs.n = gs.n + 1
  return entities, gs
end

setmetatable(_G, {
  __newindex = function(t, k, v)
    error("attempt to create global '" .. tostring(k) .. "'")
  end
})
