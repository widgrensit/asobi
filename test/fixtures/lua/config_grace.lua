-- World mode match script with empty_grace_ms set.
match_size = 1
max_players = 4
empty_grace_ms = 30000

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
