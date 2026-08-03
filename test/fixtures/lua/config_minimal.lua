-- Minimal match script with only required globals
match_size = 2

function init(config) return { players = {} } end
function join(player_id, state) return state end
function leave(player_id, state) return state end
function handle_input(player_id, input, state) return state end
function tick(state) return state end
function get_state(player_id, state) return state end
