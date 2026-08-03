-- Fault-injecting world fixture for prop_lua_error_containment.
--
-- The injection is encoded in input.crash_mode so the property can drive
-- different crash classes through handle_input/3. zone_tick reads its
-- own crash signal from zone_state.crash_next which the Erlang side or
-- a previous handle_input may have set.

match_size  = 1
max_players = 16
game_type   = "world"

local function explode(mode)
    if mode == "error" then
        error("injected_error")
    elseif mode == "type_error" then
        local x = nil
        return x.field  -- nil indexing
    elseif mode == "arith_error" then
        return 1 + "string"
    elseif mode == "stack_overflow" then
        local function rec() return rec() end
        return rec()
    elseif mode == "infinite_loop" then
        while true do end
    end
end

function init(_config)
    return { tick_count = 0, crash_count = 0 }
end

function join(_player_id, state)   return state end
function leave(_player_id, state)  return state end
function spawn_position(_player_id, _state) return { x = 0, y = 0 } end
function generate_world(_seed, _config) return { ["0,0"] = { tick_count = 0 } } end

function zone_tick(entities, zone_state)
    local mode = zone_state.crash_next
    zone_state.crash_next = nil
    zone_state.tick_count = (zone_state.tick_count or 0) + 1
    if mode then explode(mode) end
    return entities, zone_state
end

function handle_input(player_id, input, entities)
    local mode = input.crash_mode
    if mode then
        explode(mode)
    end
    if input.kind == "move" then
        entities[player_id] = {
            type = "player",
            x = input.x or 0,
            y = input.y or 0,
        }
    end
    return entities
end

function post_tick(_tick, state)
    state.tick_count = (state.tick_count or 0) + 1
    return state
end

function get_state(_player_id, state) return state end
