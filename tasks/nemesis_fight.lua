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
local enums    = require "data.enums"

local NO_KILL_TIMEOUT       = 30.0  -- seconds with no enemy death → run complete
-- Bail-out cap if the lair zone never loads. Bumped from 35s -> 60s so the
-- portal-retry loop below has room for ~10 attempts at 5s cadence.
local LAIR_LOAD_TIMEOUT     = 60.0
-- The portal interact -> zone change can take ~5s server-side; retry only
-- once per cadence so we don't spam interact while the load is in flight.
local PORTAL_RETRY_INTERVAL = 5.0
local PORTAL_INTERACT_RANGE = 2.5
local ENEMY_SCAN_RANGE      = 50    -- target_selector radius for alive-enemy count
local LAIR_ZONE_PATTERN     = "^Warplans_Boss_NemesisLair"

local function find_nemesis_portal()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= "table" then return nil end
    local target_name = enums.misc.nemesis_portal
    local best, best_dist = nil, math.huge
    local lp = get_local_player()
    local pp = lp and lp:get_position()
    for _, a in pairs(actors) do
        local n = a:get_skin_name()
        if type(n) == "string" and n == target_name then
            local d = pp and pp:dist_to(a:get_position()) or 0
            if d < best_dist then best = a; best_dist = d end
        end
    end
    return best
end

local STATE = {
    IDLE        = "IDLE",
    WATCHING    = "WATCHING",
    TELEPORTING = "TELEPORTING",
    WAIT_TOWN   = "WAIT_TOWN",
}

local s = {
    state           = STATE.IDLE,
    t               = -999,
    last_count      = nil,
    last_log_t      = -999,
    idle_armed_t    = nil,  -- timestamp we first started waiting for the lair zone
    last_retry_t    = nil,  -- last portal re-interact attempt (IDLE retry loop)
    retry_count     = 0,    -- count of re-interacts fired; primary interact lives in open_chest
}

local function now()         return get_time_since_inject() end
local function set_state(st) s.state = st; s.t = now() end

local function in_lair()
    local zone = utils.get_zone()
    return type(zone) == "string" and zone:find(LAIR_ZONE_PATTERN) ~= nil
end

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
    s.state        = STATE.IDLE
    s.t            = -999
    s.last_count   = nil
    s.last_log_t   = -999
    s.idle_armed_t = nil
    s.last_retry_t = nil
    s.retry_count  = 0
end

function task.shouldExecute()
    if not tracker.nemesis_entered then return false end
    if tracker.nemesis_resolved    then return false end
    return true
end

function task.Execute()
    local t = now()

    -- ---- IDLE: wait for the Warplans_Boss_NemesisLair zone, then arm timer ----
    --
    -- open_chest sets tracker.nemesis_entered the moment it clicks the portal,
    -- so this task starts driving immediately — BEFORE the zone transition
    -- completes. The explicit zone check below ensures the 30s no-kill timer
    -- doesn't start counting while we're still on the loading screen, which
    -- would eat into the actual fight window.
    --
    -- The portal's first interact occasionally fails to take (server lag,
    -- animation interrupt, knockback). open_chest fires interact exactly once
    -- and hands off; if the zone never flips, we have to retry from here.
    -- Re-interact every PORTAL_RETRY_INTERVAL while we're still in the boss
    -- zone with the portal actor still visible. The server-side teleport
    -- can take ~5s, so don't spam interact in between attempts.
    if s.state == STATE.IDLE then
        if not s.idle_armed_t then
            s.idle_armed_t = t
            -- Treat the open_chest interact as "attempt 0" — start the retry
            -- cadence from now so the first re-interact fires ~5s after handoff.
            s.last_retry_t = t
            s.retry_count  = 0
        end

        if not in_lair() then
            if (t - s.idle_armed_t) >= LAIR_LOAD_TIMEOUT then
                console.print(string.format(
                    "[Nemesis] Lair zone never confirmed after %.0fs (%d retries) — bailing to %s.",
                    LAIR_LOAD_TIMEOUT, s.retry_count, settings.town_zone))
                teleport_to_waypoint(settings.town_waypoint)
                set_state(STATE.TELEPORTING)
                return
            end

            if (t - (s.last_retry_t or t)) >= PORTAL_RETRY_INTERVAL then
                local portal = find_nemesis_portal()
                if portal then
                    local ppos = portal:get_position()
                    if utils.distance_to(ppos) > PORTAL_INTERACT_RANGE then
                        pathfinder.request_move(ppos)
                    else
                        interact_object(portal)
                        s.retry_count = s.retry_count + 1
                        console.print(string.format(
                            "[Nemesis] Portal interact retry #%d (%.0fs elapsed, zone=%s).",
                            s.retry_count, t - s.idle_armed_t, tostring(utils.get_zone())))
                    end
                end
                s.last_retry_t = t
            end
            return
        end

        tracker.nemesis_last_kill_t = t
        s.last_count   = count_enemies()
        s.idle_armed_t = nil
        s.last_retry_t = nil
        if s.retry_count > 0 then
            console.print(string.format(
                "[Nemesis] Lair load took %d retry interact(s).", s.retry_count))
        end
        s.retry_count  = 0
        set_state(STATE.WATCHING)
        console.print(string.format(
            "[Nemesis] Entered lair (%s) — watching for kills (timeout=%ds, enemies=%d).",
            utils.get_zone(), NO_KILL_TIMEOUT, s.last_count))
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
            -- Don't yank the player out from under Looter while drops are
            -- still being picked up. Naturally clears next tick.
            if settings.looter_busy() then return end

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
