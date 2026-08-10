-- Refusing a join. `nil` alone refuses without a reason, `nil, "..."` refuses
-- with one, and the state is only ever returned for a player who is let in.

function init(config)
	return {players = {}, locked = false, attempts = 0}
end

function join(player_id, state, ctx)
	state.attempts = state.attempts + 1
	if player_id == "silent" then
		return nil
	end
	if player_id == "shouty" then
		return nil, string.rep("x", 200)
	end
	if player_id == "binary" then
		return nil, "\1\2\3"
	end
	if player_id == "numeric" then
		return nil, 42
	end
	if ctx and ctx.code ~= "OPEN" then
		return nil, "wrong_code"
	end
	state.players[player_id] = true
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
	return state
end

function get_state(player_id, state)
	return {attempts = state.attempts}
end
