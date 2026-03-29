-- ============================================================
--  Reaper - core/utils.lua
-- ============================================================

local enums = require "data.enums"
local utils = {}

function utils.distance_to(target)
    local player_pos = get_player_position()
    local target_pos
    if target.get_position then
        target_pos = target:get_position()
    elseif target.x then
        target_pos = target
    end
    return player_pos:dist_to(target_pos)
end

function utils.player_in_zone(zname)
    return get_current_world():get_current_zone_name() == zname
end

function utils.match_player_zone(pattern)
    return get_current_world():get_current_zone_name():match(pattern)
end

function utils.get_zone()
    return get_current_world():get_current_zone_name()
end

function utils.get_altar()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        for _, aname in ipairs(enums.altar_names) do
            if name == aname then return actor end
        end
    end
    return nil
end

function utils.get_dungeon_entrance()
    local actors = actors_manager:get_all_actors()
    local world_name = get_current_world():get_name()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == enums.misc.dungeon_entrance and utils.distance_to(actor) < 60 then
            if world_name == "Sanctuary_Eastern_Continent" or world_name == "Frac_Underworld" then
                return actor
            end
        end
    end
    return nil
end

function utils.get_suppressor()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == enums.misc.suppressor then return actor end
    end
end

function utils.get_town_portal()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == enums.misc.portal then return actor end
    end
end

function utils.get_closest_enemy()
    local player_pos = get_player_position()
    local enemies    = target_selector.get_near_target_list(player_pos, 20)
    local best, best_dist = nil, math.huge
    for _, enemy in pairs(enemies) do
        local dist = player_pos:dist_to(enemy:get_position())
        if dist < best_dist then
            best = enemy
            best_dist = dist
        end
    end
    return best
end

local MOVEMENT_SPELL_IDS = { 288106, 358761, 355606, 1663206, 1871821, 337031 }

function utils.try_movement_spell(target_pos)
    local player = get_local_player()
    if not player then return false end
    for _, sid in ipairs(MOVEMENT_SPELL_IDS) do
        if player:is_spell_ready(sid) then
            if cast_spell.position(sid, target_pos, 3.0) then return true end
        end
    end
    return false
end

return utils
