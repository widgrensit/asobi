-- Clears asobi's reference anchor from _G when the input says to, and otherwise
-- behaves: it reports a consumed seq. That lets a test put a well-behaved,
-- REPORTING input ahead of the one that tampers, which is how the outcomes
-- already produced for the tick get checked.
--
-- On the clearing input it also mutates and returns entities, so honouring that
-- return would show up - seeing the ORIGINAL entities is what proves the batch
-- bailed out rather than trusting a reference that may alias a recycled slot.
--
-- Two parameters on purpose where it clears: the entity map is then not rooted
-- by this call's own frame either.

game_type   = "world"
match_size  = 1
max_players = 8
grid_size   = 1
zone_size   = 500
view_radius = 0

function init(config)
    return {}
end

function zone_tick(entities, zone_state)
    return entities, zone_state
end

function post_tick(tick_n, state)
    return state
end

function handle_input(player_id, input, entities)
    if input.clear then
        __asobi_ref_anchor = nil
        local victim = entities[player_id]
        if victim then
            victim.hp = 0
        end
        return entities
    end
    return entities, input.consumed
end
