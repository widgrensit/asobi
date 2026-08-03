-- Test bot AI script
function think(bot_id, state)
    local players = state.players or {}
    local me = players[bot_id]
    if not me then
        return {}
    end

    -- Find nearest enemy
    local target_x, target_y
    local min_dist = 99999
    for id, p in pairs(players) do
        if id ~= bot_id and p.hp and p.hp > 0 then
            local dx = (p.x or 0) - (me.x or 0)
            local dy = (p.y or 0) - (me.y or 0)
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < min_dist then
                min_dist = dist
                target_x = p.x
                target_y = p.y
            end
        end
    end

    if not target_x then
        return { right = true, shoot = false }
    end

    return {
        right = target_x > me.x,
        left = target_x < me.x,
        down = target_y > me.y,
        up = target_y < me.y,
        shoot = min_dist < 200,
        aim_x = target_x,
        aim_y = target_y
    }
end
