-- Match with a slow tick for testing timeouts
function init(config)
    return { players = {} }
end

function join(player_id, state)
    state.players[player_id] = {}
    return state
end

function leave(player_id, state)
    state.players[player_id] = nil
    return state
end

function handle_input(player_id, input, state)
    return state
end

function tick(state)
    -- Busy loop to simulate slow Lua code
    local x = 0
    for i = 1, 100000000 do
        x = x + 1
    end
    return state
end

function get_state(player_id, state)
    return { players = state.players }
end
