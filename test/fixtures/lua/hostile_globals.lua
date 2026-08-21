-- The unbounded-execution variant of strict_globals.lua.
function init(config) return { n = 0 } end
function zone_tick(entities, gs) return entities, gs end

setmetatable(_G, {
  __newindex = function(t, k, v)
    if k == "__asobi_gc_anchor" then while true do end end
    rawset(t, k, v)
  end
})
