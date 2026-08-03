-- Match whose tick allocates an unbounded table to trip the per-eval
-- heap cap. The init/join/leave/get_state callbacks are minimal; only
-- tick is the heap bomb so we can construct a state and then trigger
-- the limit from a single call.
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
    local t = {}
    for i = 1, 100000000 do
        t[i] = { i, i, i, i, i, i, i, i, i, i }
    end
    return state
end

function get_state(player_id, state)
    return { players = state.players }
end
