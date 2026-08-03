-- Match script that exposes get_state(state) for the shared-state bridge.

state_strategy = "shared"

function init(config)
    return {
        players = {},
        tick_count = 0,
        world = { ticks = 0 }
    }
end

function join(player_id, state)
    state.players[player_id] = { x = 0, y = 0 }
    return state
end

function leave(player_id, state)
    state.players[player_id] = nil
    return state
end

function handle_input(_player_id, _input, state)
    return state
end

function tick(state)
    state.tick_count = state.tick_count + 1
    state.world.ticks = state.tick_count
    return state
end

function get_state(state)
    return {
        tick = state.tick_count,
        world = state.world
    }
end
