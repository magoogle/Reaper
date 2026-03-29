-- ============================================================
--  Reaper - tasks/interact_altar.lua
--
--  Finds the summoning altar inside the boss zone and
--  interacts with it to spawn the boss.
-- ============================================================

local utils        = require "core.utils"
local enums        = require "data.enums"
local explorerlite = require "core.explorerlite"
local tracker      = require "core.tracker"
local rotation     = require "core.boss_rotation"

-- ---- Unstuck helpers ----
local last_pos          = nil
local last_move_time    = 0
local stuck_threshold   = 3
local last_unstuck_time = 0
local unstuck_cooldown  = 3
local unstuck_start     = 0
local unstuck_timeout   = 5

local boss_summon_time = 0

local function check_if_stuck()
    local pos = get_player_position()
    local t   = os.time()
    if last_pos and utils.distance_to(last_pos) < 0.1 then
        if t - last_move_time > stuck_threshold then
            if t - last_unstuck_time >= unstuck_cooldown then
                last_unstuck_time = t
                return true
            end
        end
    else
        last_move_time = t
    end
    last_pos = pos
    return false
end

-- -------------------------------------------------------
-- shouldExecute: we are inside a boss zone AND the altar
-- exists AND the boss has not been summoned yet this run.
-- -------------------------------------------------------
local task = { name = "Interact Altar" }

function task.shouldExecute()
    if tracker.altar_activated then return false end

    local boss = rotation.current()
    if not boss then return false end

    -- Zone check: sigil runs use lair zones that don't match boss.zone_prefix
    local zone = utils.get_zone()
    local in_zone
    if boss.run_type == "sigil" then
        in_zone = zone:find("BloodyLair") ~= nil
            or zone:find("S12_Boss")      ~= nil
            or zone:find("Boss_WT")       ~= nil
            or zone:find("Boss_Kehj")     ~= nil
    else
        in_zone = zone:match(boss.zone_prefix) ~= nil
    end
    if not in_zone then return false end

    -- If a loot chest is already visible, the boss is already dead — skip altar
    local actors = actors_manager.get_all_actors()
    if type(actors) == "table" then
        for _, actor in pairs(actors) do
            local ok, inter = pcall(function() return actor:is_interactable() end)
            if ok and inter then
                local name = actor:get_skin_name()
                if type(name) == "string" then
                    if name:find("^EGB_Chest") or name:find("^Boss_WT_Belial_") or name:find("^Chest_Boss") then
                        return false
                    end
                end
            end
        end
    end

    -- Wait a moment after the last chest open before re-activating
    if tracker.chest_opened_time then
        if os.time() < tracker.chest_opened_time + 6 then return false end
    end

    return utils.get_altar() ~= nil
end

function task.Execute()
    local t = get_time_since_inject()

    -- Don't re-interact too fast after summoning
    if boss_summon_time > 0 and t - boss_summon_time < 1.5 then return end

    -- Unstuck logic
    if check_if_stuck() then
        if unstuck_start == 0 then
            unstuck_start = t
        elseif t - unstuck_start > unstuck_timeout then
            unstuck_start = 0
            return
        end
        local ut = explorerlite.find_unstuck_target()
        if ut then
            explorerlite:set_custom_target(ut)
            utils.try_movement_spell(ut)
            pathfinder.force_move_raw(ut)
        end
        return
    else
        unstuck_start = 0
    end

    local altar = utils.get_altar()
    if not altar then return end

    local dist = utils.distance_to(altar)
    if dist > 2.5 then
        explorerlite:set_custom_target(altar:get_position())
        explorerlite:move_to_target()
        return
    end

    -- Close enough – interact
    console.print("[Reaper] Activating altar to summon boss.")
    interact_object(altar)
    tracker.altar_activated = true
    boss_summon_time = t
end

return task
