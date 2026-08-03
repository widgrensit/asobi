-- World mode script that selects the world bridge via game_type.
match_size = 1
max_players = 16
game_type = "world"

function init(config) return { tick_count = 0, players = {} } end
function join(player_id, state) state.players[player_id] = {}; return state end
function leave(player_id, state) state.players[player_id] = nil; return state end
function spawn_position(player_id, state) return { x = 0, y = 0 } end
function zone_tick(entities, zone_state) return entities, zone_state end
function handle_input(player_id, input, entities) return entities end
function post_tick(tick, state)
    state.tick_count = (state.tick_count or 0) + 1
    return state
end
function generate_world(seed, config) return { ["0,0"] = { tiles = {}, mobs = {} } } end
