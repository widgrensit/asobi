-- Default match.lua for single-mode config tests
local boons = require("boons")

match_size = 4
max_players = 10
strategy = "fill"
bots = { script = "bots/chaser.lua" }

function init(config)
    return {
        players = {},
        tick_count = 0
    }
end

function join(player_id, state)
    state.players[player_id] = { x = 100, y = 100, hp = 100 }
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
    state.tick_count = (state.tick_count or 0) + 1
    return state
end

function get_state(player_id, state)
    return state
end
