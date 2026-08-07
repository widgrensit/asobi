-- A match mode opting into the live-match browser. Matches are unlisted by
-- default, so `listed = true` here is the opt-in that makes match.list and
-- GET /api/v1/matches/live return this mode's live matches.
match_size  = 1
max_players = 8
listed      = true

function init(config) return {} end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function handle_input(player_id, input, state) return state end
function tick(state) return state end
function get_state(player_id, state) return state end
