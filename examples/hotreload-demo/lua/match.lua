-- examples/hotreload-demo/lua/match.lua
--
-- The demo. Edit the values below and save — the running game updates
-- live. No restart, no reconnect.

-- ==========================================================================
-- EDIT ME: change the colour, save, watch the cube in your browser change.
-- ==========================================================================
cube_color = "#ff4757"     -- try "#4facfe" or "#2ed573"
cube_size  = 60            -- try 20, 100, 140
move_speed = 4             -- try 1, 8, 16
bg_color   = "#1e272e"     -- try "#ffeaa7" or "#6c5ce7"
message    = "Hello from Lua!"   -- change this text

-- ==========================================================================
-- Match config. You shouldn't need to touch these.
-- ==========================================================================
match_size  = 1
max_players = 8
strategy    = "fill"

-- ==========================================================================
-- Game logic.
-- ==========================================================================

function init(_config)
    return {
        players = {},
        arena_w = 800,
        arena_h = 600
    }
end

function join(player_id, state)
    state.players[player_id] = {
        x = math.random(100, 700),
        y = math.random(100, 500)
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

    -- move_speed is a global — re-read every input so hot-reload applies.
    if input.right then p.x = math.min(state.arena_w, p.x + move_speed) end
    if input.left  then p.x = math.max(0,             p.x - move_speed) end
    if input.down  then p.y = math.min(state.arena_h, p.y + move_speed) end
    if input.up    then p.y = math.max(0,             p.y - move_speed) end

    return state
end

function tick(state)
    -- nothing to simulate — this demo is input-driven only.
    return state
end

function get_state(_player_id, state)
    -- Re-read the globals every tick so edits to match.lua take effect live.
    return {
        players    = state.players,
        cube_color = cube_color,
        cube_size  = cube_size,
        bg_color   = bg_color,
        message    = message,
        arena_w    = state.arena_w,
        arena_h    = state.arena_h
    }
end
