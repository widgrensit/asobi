-- A `join` that falls off its end and returns nothing. An author bug, and
-- before refusal existed it killed the match server and everyone in it.

function init(config)
	return {players = {}}
end

function join(player_id, state, ctx)
	state.players[player_id] = true
end

function leave(player_id, state)
	state.players[player_id] = nil
	return state
end

function handle_input(player_id, input, state)
	return state
end

function tick(state)
	return state
end

function get_state(player_id, state)
	return {}
end
