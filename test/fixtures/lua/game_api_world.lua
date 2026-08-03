-- Regression fixture: probes `game.*` visibility from every callback the
-- world bridge exposes. Tests assert each callback wrote a truthy flag
-- back into observable state, so a regression where `game.*` is missing
-- in any callback shows up as a failing assertion rather than a silent
-- no-op.
match_size = 1
max_players = 16
game_type = "world"
grid_size = 1
view_radius = 0

local function game_visible()
    return type(_G.game) == "table" and type(_G.game.id) == "function"
end

function init(_config)
    return { init_saw_game = game_visible() }
end

function join(_player_id, state)
    state.join_saw_game = game_visible()
    return state
end

function leave(_player_id, state)
    state.leave_saw_game = game_visible()
    return state
end

function spawn_position(_player_id, _state)
    return { x = 0, y = 0 }
end

function zone_tick(entities, zone_state)
    zone_state = zone_state or {}
    zone_state.zone_tick_saw_game = game_visible()
    return entities, zone_state
end

function handle_input(player_id, input, entities)
    if input and input.kind == "probe" then
        entities[player_id] = {
            type = "player",
            handle_input_saw_game = game_visible(),
            -- Also exercise an actual game.* call to catch cases where the
            -- table exists but its functions are stubbed.
            game_id_callable = type(game.id()) == "string",
        }
    end
    return entities
end

function post_tick(_tick, state)
    state.post_tick_saw_game = game_visible()
    return state
end

function generate_world(_seed, _config)
    return { ["0,0"] = { tiles = {}, mobs = {} } }
end
