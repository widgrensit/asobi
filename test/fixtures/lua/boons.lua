-- Test boons module (loaded via require)
local M = {}

M.all = {
    { id = "hp_boost", name = "Vitality", stat = "max_hp", delta = 15 },
    { id = "damage", name = "Power", stat = "score", delta = 10 },
    { id = "speed", name = "Swift", stat = "x", delta = 50 }
}

function M.apply(boon_id, player)
    for _, boon in ipairs(M.all) do
        if boon.id == boon_id then
            local current = player[boon.stat] or 0
            player[boon.stat] = current + boon.delta
            if not player.boons then player.boons = {} end
            table.insert(player.boons, boon_id)
            return player
        end
    end
    return player
end

return M
