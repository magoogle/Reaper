-- ============================================================
--  Reaper - tasks/kill_monsters.lua
--
--  Handles fighting — moves toward enemies and suppressor
--  orbs. When no enemy is in range, drifts back toward the
--  altar position so the orbwalker stays close to the boss.
-- ============================================================

local utils        = require "core.utils"
local explorerlite = require "core.explorerlite"
local tracker      = require "core.tracker"
local rotation     = require "core.boss_rotation"
local enums        = require "data.enums"

local stuck_position = nil

local function in_target_boss_zone()
    local boss = rotation.current()
    if not boss then return false end
    local zone = utils.get_zone()
    if boss.run_type == "sigil" then
        return zone:find("BloodyLair") ~= nil
            or zone:find("S12_Boss")   ~= nil
            or zone:find("Boss_WT")    ~= nil
            or zone:find("Boss_Kehj")  ~= nil
    end
    return zone:match(boss.zone_prefix) ~= nil
end

-- Returns the altar position if we can find it, or the boss room
-- seed position from enums as a fallback
local function get_anchor_position()
    local altar = utils.get_altar()
    if altar then return altar:get_position() end

    local boss = rotation.current()
    if boss then
        return enums.positions.getBossRoomPosition(boss.zone_prefix)
    end
    return nil
end

-- Maximum distance from altar/anchor before pulling back toward it.
-- Keeps the player inside the boss arena instead of chasing enemies outward.
local ALTAR_TETHER = 15.0

local task = { name = "Kill Monsters" }

function task.shouldExecute()
    if not in_target_boss_zone() then return false end
    if not tracker.altar_activated then return false end
    if utils.get_suppressor() then return true end
    return utils.get_closest_enemy() ~= nil
end

function task.Execute()
    local player_pos = get_player_position()

    -- Stuck guard
    if explorerlite.check_if_stuck() then
        stuck_position = player_pos
        return
    end
    if stuck_position and utils.distance_to(stuck_position) < 10 then
        return
    else
        stuck_position = nil
    end

    -- Always chase suppressor orbs (need to burst them to unblock combat)
    local suppressor = utils.get_suppressor()
    if suppressor then
        pathfinder.force_move_raw(suppressor:get_position())
        return
    end

    -- Tether: if too far from altar, walk back before engaging any enemy
    local anchor = get_anchor_position()
    if anchor and utils.distance_to(anchor) > ALTAR_TETHER then
        pathfinder.request_move(anchor)
        return
    end

    local enemy = utils.get_closest_enemy()
    if not enemy then return end

    local dist = utils.distance_to(enemy)
    if dist >= 6.5 then
        explorerlite:set_custom_target(enemy:get_position())
        explorerlite:move_to_target()
    end
    -- Within 6.5: orbwalker handles casting, no movement needed
end

return task
