-- Match script with player_ttl_ms set to a positive grace window.
match_size = 1
max_players = 4
player_ttl_ms = 5000

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
