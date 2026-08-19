-- asobi#481: a match that spawns with the matchmaker's group and then waits
-- for backfill to reach min_players before the loop starts. min_players was
-- honoured by asobi_match_server all along but reachable from no config
-- surface, so declaring it here used to be silently ignored.
match_size  = 2
max_players = 8
min_players = 4
listed      = true

function init(config) return {} end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function handle_input(player_id, input, state) return state end
function tick(state) return state end
function get_state(player_id, state) return state end
