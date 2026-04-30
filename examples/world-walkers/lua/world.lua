-- Two players walking around in one shared room.
--
-- The minimum world.lua: one zone, no terrain, no phases, no votes.
-- Everything else in asobi (matchmaking, chat, persistence) is *off* by
-- default — this file only shows the world callbacks.

-- IMPORTANT: the global must be `game_type` (not `type`). The Lua
-- config loader reads `game_type`; setting `type = "world"` is silently
-- ignored and the script registers as a *match* mode instead.
game_type      = "world"

-- match_size is required by the Lua config loader for *every* mode,
-- including worlds. Worlds don't gate on a minimum player count, so
-- `1` is the correct value here — it just satisfies the loader check.
match_size     = 1
max_players    = 8
tick_rate      = 50          -- ms (20 Hz)

-- Single zone covering the entire room. With grid_size=1, view_radius=0
-- is the only sensible value: every player is always in zone (0,0) and
-- always sees every other player. No interest-set debugging.
grid_size      = 1
zone_size      = 1200
view_radius    = 0

-- Keep the room alive for 10s after the last player leaves so a brief
-- network blip doesn't tear down the world between two test clients.
empty_grace_ms = 10000

local function log(msg)
    if game and game.log then game.log("info", "[walkers] " .. tostring(msg), {}) end
end

function init(config)
    log("init")
    return { tick = 0 }
end

function generate_world(seed, config)
    -- One zone at (0,0). No tiles, no mobs.
    return { ["0,0"] = {} }
end

function spawn_position(player_id, state)
    -- Spread spawns around the centre so two players don't stack.
    math.randomseed(#player_id + (state.tick or 0))
    local angle = math.random() * math.pi * 2
    return {
        x = 600 + math.cos(angle) * 80,
        y = 600 + math.sin(angle) * 80,
    }
end

function join(player_id, state)
    log("join " .. player_id)
    return state
end

function leave(player_id, state)
    log("leave " .. player_id)
    return state
end

-- Inputs from `world.input` arrive here. Update the entity for this
-- player and return the new entities table for the zone.
function handle_input(player_id, input, entities)
    if not input or input.kind ~= "move" then return entities end
    entities[player_id] = {
        type  = "player",
        x     = tonumber(input.x) or 0,
        y     = tonumber(input.y) or 0,
        color = input.color, -- optional vanity field
    }
    return entities
end

function zone_tick(entities, zone_state)
    return entities, zone_state
end

function post_tick(tick_n, state)
    state.tick = tick_n
    return state
end
