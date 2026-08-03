-- Exercises the three-argument join: the client join context arrives as the
-- third parameter. A script that declares only (player_id, state) must keep
-- working, which is covered by the other fixtures.

function init(config)
	return {players = {}, last_code = "none", rejected = 0}
end

function join(player_id, state, ctx)
	local code = ctx and ctx.code or nil
	if code ~= "OPEN" then
		state.rejected = state.rejected + 1
		return state
	end
	state.players[player_id] = true
	state.last_code = code
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
	return {last_code = state.last_code, rejected = state.rejected}
end
