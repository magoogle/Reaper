-- ============================================================
--  Reaper - tasks/nemesis_fight.lua
--
--  Drives the bonus Nemesis-portal encounter that randomly spawns
--  after looting the main boss chest. Inside the portal multiple
--  bosses spawn randomly; we treat the run as "done" once 30s pass
--  without any enemy dying.
--
--  Flow (mirrors sigil_complete.lua):
--    IDLE        → on entry from open_chest (tracker.nemesis_entered true),
--                  arm the timer and start tracking enemy count.
--    WATCHING    → chase nearest enemy, reset timer whenever the alive-enemy
--                  count drops (kill detected). After 30s no kill → teleport.
--    TELEPORTING → brief settle.
--    WAIT_TOWN   → wait to land in home town, then consume_run + reset_run
--                  + mark nemesis_resolved so open_chest stays out of WAIT_COMPLETE.
--
--  Priority: this task runs ABOVE navigate_to_boss in task_manager so the
--  rotation's next-boss teleport does not fire while we're still in the
--  Nemesis lair.
-- ============================================================

local utils    = require "core.utils"
local tracker  = require "core.tracker"
local rotation = require "core.boss_rotation"
local settings = require "core.settings"

local NO_KILL_TIMEOUT  = 30.0  -- seconds with no enemy death → run complete
local ENEMY_SCAN_RANGE = 50    -- target_selector radius for alive-enemy count

local STATE = {
    IDLE        = "IDLE",
    WATCHING    = "WATCHING",
    TELEPORTING = "TELEPORTING",
    WAIT_TOWN   = "WAIT_TOWN",
}

local s = {
    state          = STATE.IDLE,
    t              = -999,
    last_count     = nil,
    last_log_t     = -999,
}

local function now()         return get_time_since_inject() end
local function set_state(st) s.state = st; s.t = now() end

local function count_enemies()
    local lp = get_local_player()
    if not lp then return 0 end
    local pp = lp:get_position()
    local list = target_selector.get_near_target_list(pp, ENEMY_SCAN_RANGE)
    return (type(list) == "table") and #list or 0
end

local task = { name = "Nemesis Fight" }

function task.reset()
    settings.orb_set_clear(false)
    s.state      = STATE.IDLE
    s.t          = -999
    s.last_count = nil
    s.last_log_t = -999
end

function task.shouldExecute()
    if not tracker.nemesis_entered then return false end
    if tracker.nemesis_resolved    then return false end
    return true
end

function task.Execute()
    local t = now()

    -- ---- IDLE: arm timer, start watching ----
    if s.state == STATE.IDLE then
        tracker.nemesis_last_kill_t = t
        s.last_count = count_enemies()
        set_state(STATE.WATCHING)
        console.print(string.format(
            "[Nemesis] Entered lair — watching for kills (timeout=%ds, enemies=%d).",
            NO_KILL_TIMEOUT, s.last_count))
        return
    end

    -- ---- WATCHING: chase + detect kill via enemy count drop ----
    if s.state == STATE.WATCHING then
        settings.orb_set_clear(true)
        settings.orb_set_block(true)

        local current = count_enemies()
        if s.last_count and current < s.last_count then
            tracker.nemesis_last_kill_t = t
            console.print(string.format(
                "[Nemesis] Kill detected (%d → %d). Timer reset.",
                s.last_count, current))
        end
        s.last_count = current

        -- Chase nearest enemy so orbwalker can keep firing
        local target = utils.get_closest_enemy()
        if target then
            pathfinder.force_move_raw(target:get_position())
        end

        local idle = t - (tracker.nemesis_last_kill_t or t)
        if (t - s.last_log_t) >= 5.0 then
            console.print(string.format(
                "[Nemesis] %.0fs / %ds idle (enemies=%d)",
                idle, NO_KILL_TIMEOUT, current))
            s.last_log_t = t
        end

        if idle >= NO_KILL_TIMEOUT then
            console.print(string.format(
                "[Nemesis] %ds idle — Nemesis run complete, teleporting to %s.",
                NO_KILL_TIMEOUT, settings.town_zone))
            settings.orb_set_clear(false)
            teleport_to_waypoint(settings.town_waypoint)
            set_state(STATE.TELEPORTING)
        end
        return
    end

    -- ---- TELEPORTING: brief wait for teleport animation ----
    if s.state == STATE.TELEPORTING then
        if (t - s.t) >= 1.5 then
            set_state(STATE.WAIT_TOWN)
        end
        return
    end

    -- ---- WAIT_TOWN: wait to arrive, then count the run ----
    if s.state == STATE.WAIT_TOWN then
        if utils.player_in_zone(settings.town_zone) then
            if (t - s.t) >= 2.0 then
                console.print("[Nemesis] Back in " .. settings.town_zone .. " — counting run.")
                rotation.consume_run()
                tracker.reset_run()
                set_state(STATE.IDLE)
            end
            return
        end
        -- Timeout — retry teleport
        if (t - s.t) >= 20.0 then
            console.print("[Nemesis] Town wait timeout — retrying teleport.")
            teleport_to_waypoint(settings.town_waypoint)
            set_state(STATE.TELEPORTING)
        end
        return
    end
end

return task
