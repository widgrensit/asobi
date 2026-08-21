-- A script that tries to collect from inside handle_input and never names the
-- entity map. Two parameters, not three, so luerl's call frame does not root the
-- map the bridge carries across an input batch.
--
-- Both halves of the defence meet here. `collectgarbage` is stripped from the
-- sandbox, so the call raises rather than collecting, and the bridge turns a Lua
-- exception into "this input did nothing" - the zone's entities survive. Were it
-- ever reachable again, the map is also anchored (asobi_lua_loader:anchor_ref/2,
-- covered directly in asobi_lua_loader_tests), so the collection would not free
-- it either.

game_type   = "world"
match_size  = 1
max_players = 8
grid_size   = 1
zone_size   = 500
view_radius = 0

function init(config)
    return {}
end

function zone_tick(entities, zone_state)
    return entities, zone_state
end

function post_tick(tick_n, state)
    return state
end

function handle_input(p, i)
    collectgarbage()
    return nil
end
