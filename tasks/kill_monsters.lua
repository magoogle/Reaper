-- ============================================================
--  Reaper - tasks/kill_monsters.lua
--
--  Handles fighting — moves toward enemies and suppressor
--  orbs. When no enemy is in range, drifts back toward the
--  altar position so the orbwalker stays close to the boss.
-- ============================================================

local utils    = require "core.utils"
local tracker  = require "core.tracker"
local rotation = require "core.boss_rotation"
local settings = require "core.settings"
local enums    = require "data.enums"

local stuck_position = nil

local function in_target_boss_zone()
    local boss = rotation.current()
    if not boss then return false end
    local zone = utils.get_zone()
    return zone:match(boss.zone_prefix) ~= nil
end

-- Returns the altar position if we can find it, or the cached altar position
-- saved by interact_altar at interact time, falling back to the boss-room
-- seed from enums only if neither is available.
--
-- Why the cache layer: enums.positions.boss_room is incomplete (no entry for
-- Butcher / Urivar / Belial), and getBossRoomPosition returns vec3(0,0,0) for
-- missing bosses — which would tether the player to the far corner of the
-- arena. The cached actor position is always correct.
local function get_anchor_position()
    local altar = utils.get_altar()
    if altar then return altar:get_position() end

    if tracker.altar_position then return tracker.altar_position end

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

function task.reset()
    settings.orb_set_clear(false)
end

function task.shouldExecute()
    if not in_target_boss_zone() then return false end
    if not tracker.altar_activated then return false end
    -- Boss is dead and main chest has been opened — fight is over. Stop tethering
    -- the player to the altar so they can walk freely (e.g. to a Nemesis portal).
    if tracker.chest_opened_time ~= nil then return false end
    return true
end

function task.Execute()
    settings.orb_set_clear(true)
    settings.orb_set_block(true)

    -- Always chase suppressor orbs (need to burst them to unblock combat)
    local suppressor = utils.get_suppressor()
    if suppressor then
        pathfinder.force_move_raw(suppressor:get_position())
        return
    end

    -- Tether: if drifted too far from altar, walk back
    local anchor = get_anchor_position()
    if anchor and utils.distance_to(anchor) > ALTAR_TETHER then
        pathfinder.request_move(anchor)
        return
    end
    -- Otherwise stay put — orbwalker handles casting from current position
end

return task
