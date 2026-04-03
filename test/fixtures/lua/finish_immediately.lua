-- Match that finishes on first tick (for testing finished signal)
function init(config)
    return { players = {} }
end

function join(player_id, state)
    state.players[player_id] = { hp = 100 }
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
    state._finished = true
    state._result = { status = "completed", winner = "nobody" }
    return state
end

function get_state(player_id, state)
    return { phase = "finished", players = state.players }
end
