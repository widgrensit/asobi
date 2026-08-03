-- Regression fixture: probes `game.*` visibility from every match callback.
local function game_visible()
    return type(_G.game) == "table" and type(_G.game.id) == "function"
end

function init(_config)
    return {
        players = {},
        init_saw_game = game_visible(),
        tick_count = 0,
    }
end

function join(player_id, state)
    state.players[player_id] = { join_saw_game = game_visible() }
    return state
end

function leave(player_id, state)
    state.players[player_id] = { leave_saw_game = game_visible() }
    return state
end

function handle_input(player_id, _input, state)
    local p = state.players[player_id] or {}
    p.handle_input_saw_game = game_visible()
    p.game_id_callable = type(game.id()) == "string"
    state.players[player_id] = p
    return state
end

function tick(state)
    state.tick_count = state.tick_count + 1
    state.tick_saw_game = game_visible()
    return state
end

function get_state(_player_id, state)
    return state
end
