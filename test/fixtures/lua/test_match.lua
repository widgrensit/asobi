-- Simple match script for testing asobi_lua_match
local boons = require("boons")

function init(config)
    return {
        players = {},
        tick_count = 0,
        max_ticks = config and config.max_ticks or 0
    }
end

function join(player_id, state)
    state.players[player_id] = {
        x = 100,
        y = 100,
        hp = 100,
        max_hp = 100,
        score = 0,
        boons = {}
    }
    return state
end

function leave(player_id, state)
    state.players[player_id] = nil
    return state
end

function handle_input(player_id, input, state)
    local p = state.players[player_id]
    if not p then return state end

    if input.type == "boon_pick" then
        p = boons.apply(input.boon_id, p)
        state.players[player_id] = p
        return state
    end

    if input.right then p.x = p.x + 5 end
    if input.left then p.x = p.x - 5 end
    if input.down then p.y = p.y + 5 end
    if input.up then p.y = p.y - 5 end

    if input.shoot and input.aim_x and input.aim_y then
        p.score = p.score + 1
    end

    state.players[player_id] = p
    return state
end

function tick(state)
    state.tick_count = state.tick_count + 1

    if state.max_ticks > 0 and state.tick_count >= state.max_ticks then
        state._finished = true
        state._result = {
            status = "completed",
            tick_count = state.tick_count
        }
    end

    return state
end

function get_state(player_id, state)
    return {
        phase = "playing",
        players = state.players,
        tick_count = state.tick_count
    }
end

function vote_requested(state)
    if state.tick_count > 0 and state.tick_count % 50 == 0 then
        return {
            template = "test_vote",
            options = {
                { id = "opt_a", label = "Option A" },
                { id = "opt_b", label = "Option B" }
            },
            method = "plurality",
            window_ms = 5000
        }
    end
    return nil
end

function vote_resolved(template, result, state)
    state.last_vote_winner = result.winner
    return state
end
