-- ============================================================
--  Reaper - tasks/navigate_to_boss.lua
--
--  Flow (material runs):
--    MAP_NAV      → teleport_to_boss_dungeon via map_nav.lua
--    PATHWALKING  → fire BatmobilePlugin.navigate_long_path to altar/seed
--    LONG_PATHING → Batmobile drives navigation to altar
--    EXPLORING    → Batmobile driven manually (traversal blocking long path)
--    WALKING      → walk to dungeon entrance portal
--    ENTERING     → interact with portal to enter
--
--  Flow (sigil runs):
--    USE_SIGIL    → activate sigil item, confirm dialog
--    MAP_NAV      → navigate to boss dungeon via map_nav.lua
--    (then same PATHWALKING / LONG_PATHING / EXPLORING)
-- ============================================================

local utils      = require "core.utils"
local enums      = require "data.enums"
local map_nav    = require "core.map_nav"
local rotation   = require "core.boss_rotation"
local tracker    = require "core.tracker"
local pathwalker = require "core.pathwalker"
local settings   = require "core.settings"

local plugin_label  = 'reaper'
local CERRIGAR_WP   = 0x76D58
local CERRIGAR_ZONE = "Scos_Cerrigar"

-- -------------------------------------------------------
-- Path-file variant loader (used when Batmobile is off)
-- -------------------------------------------------------
local cached_variants = {}

local function load_variants(boss_id)
    if cached_variants[boss_id] then return cached_variants[boss_id] end
    local variants = {}
    for _, letter in ipairs({"a","b","c","d","e"}) do
        local mod = "paths/" .. boss_id .. "_" .. letter
        local ok, pts = pcall(require, mod)
        if ok and type(pts) == "table" and #pts > 0 then
            variants[#variants + 1] = pts
        end
    end
    cached_variants[boss_id] = variants
    return variants
end

local function pick_best_path(variants)
    if not variants or #variants == 0 then return nil end
    if #variants == 1 then return variants[1] end
    local pp = get_player_position()
    if not pp then return variants[1] end
    local best, best_dist = variants[1], math.huge
    for _, pts in ipairs(variants) do
        if pts[1] then
            local d = pp:dist_to(pts[1])
            if d < best_dist then best = pts; best_dist = d end
        end
    end
    return best
end

-- -------------------------------------------------------
-- Zone helpers
-- -------------------------------------------------------
local function in_target_zone(boss)
    local zone = utils.get_zone()
    if boss.run_type == "sigil" then
        return zone:find("BloodyLair") ~= nil
            or zone:find("S12_Boss")   ~= nil
            or zone:find("Boss_WT")    ~= nil
            or zone:find("Boss_Kehj")  ~= nil
    end
    return zone:match(boss.zone_prefix) ~= nil
end

local function chest_visible()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= "table" then return false end
    for _, a in pairs(actors) do
        local ok, inter = pcall(function() return a:is_interactable() end)
        if ok and inter then
            local name = a:get_skin_name()
            if type(name) == "string" then
                if name:find("^EGB_Chest") or name:find("^Boss_WT_Belial_") or name:find("^Chest_Boss")
                    or name:find("^S12_Prop_Theme_Chest_") then
                    return true
                end
            end
        end
    end
    return false
end

-- -------------------------------------------------------
-- Sigil helpers
-- -------------------------------------------------------
local SIGIL_SNO = 2565553

local function find_sigil_for_boss(boss_id)
    local lp = get_local_player()
    if not lp then return nil end
    local ok, keys = pcall(function() return lp:get_dungeon_key_items() end)
    if not ok or type(keys) ~= "table" then return nil end

    local mats = require "core.materials"
    local first_sigil = nil

    for _, item in ipairs(keys) do
        local ok_sno, sno = pcall(function() return item:get_sno_id() end)
        if ok_sno and sno == SIGIL_SNO then
            if not first_sigil then first_sigil = item end

            local ok_d, display = pcall(function() return item:get_display_name() end)
            if ok_d and display then
                local mapped = mats.boss_from_display(display)
                if mapped == boss_id then
                    return item
                end
            end
        end
    end

    return first_sigil
end

-- -------------------------------------------------------
-- State machine
-- -------------------------------------------------------
local STATE = {
    IDLE         = "IDLE",
    USE_SIGIL    = "USE_SIGIL",    -- activate sigil item, confirm dialog
    MAP_NAV      = "MAP_NAV",      -- teleport via map_nav.lua
    PATHWALKING  = "PATHWALKING",  -- fires navigate_long_path, then transitions
    LONG_PATHING = "LONG_PATHING", -- Batmobile long path driving navigation
    EXPLORING    = "EXPLORING",    -- traversal blocking; drive Batmobile manually
    WALKING      = "WALKING",      -- walk to dungeon entrance portal
    ENTERING     = "ENTERING",     -- interact with portal to enter
    WAIT_EXIT    = "WAIT_EXIT",    -- waiting to leave completed sigil dungeon
}

local T_CONFIRM      = 0.8    -- wait after use_item before confirming
local T_SIGIL_SETTLE = 10.0   -- wait after arriving in Cerrigar before activating sigil
local T_SETTLE       = 2.5
local T_ENTER        = 15.0

local nav = {
    state             = STATE.IDLE,
    target_boss       = nil,
    phase_start       = -999,
    attempts          = 0,
    max_attempts      = 5,
    last_enter_try    = 0,
    path_exhausted    = false,
    exploring_retries = 0,
}

-- Tracks when we first arrived in Cerrigar for the sigil settle timer
local _sigil_settle_t = -999

local function now() return get_time_since_inject() end
local function set_state(s) nav.state = s; nav.phase_start = now() end

local function reset_nav()
    nav.state             = STATE.IDLE
    nav.target_boss       = nil
    nav.phase_start       = now()
    nav.attempts          = 0
    nav.path_exhausted    = false
    nav.exploring_retries = 0
    map_nav.reset()
    pathwalker.stop_walking()
    if BatmobilePlugin then
        BatmobilePlugin.stop_long_path(plugin_label)
        BatmobilePlugin.clear_target(plugin_label)
    end
end

-- -------------------------------------------------------
-- shouldExecute
-- -------------------------------------------------------
local task = { name = "Navigate to Boss" }

function task.reset()
    reset_nav()
end

function task.shouldExecute()
    local boss = rotation.current()
    if not boss then return false end
    if rotation.is_done() then return false end

    if tracker.just_revived then
        nav.path_exhausted   = false
        tracker.just_revived = false
        console.print("[Reaper] Post-revive: re-enabling path walk.")
    end

    -- If we left the dungeon while mid-navigation, reset to IDLE so we
    -- start fresh from town (sigil complete / death / teleport out).
    local active_nav = nav.state == STATE.PATHWALKING
                    or nav.state == STATE.LONG_PATHING
                    or nav.state == STATE.EXPLORING
    if active_nav and not in_target_zone(boss) then
        console.print("[Reaper] Left target zone mid-nav — resetting.")
        reset_nav()
    end

    -- Always run while map_nav is active
    if nav.state == STATE.MAP_NAV then return true end

    if tracker.altar_activated then return false end
    if in_target_zone(boss) and chest_visible() then return false end
    local _altar = in_target_zone(boss) and utils.get_altar()
    if _altar and utils.distance_to(_altar) <= 5.0 then return false end

    if in_target_zone(boss) then
        if not nav.path_exhausted then
            if nav.state == STATE.IDLE or nav.state == STATE.PATHWALKING
                    or nav.state == STATE.LONG_PATHING or nav.state == STATE.EXPLORING then
                -- After 60s in a sigil dungeon with no enemies, yield to sigil_complete
                if boss.run_type == "sigil" and tracker.sigil_entry_t > 0
                        and (now() - tracker.sigil_entry_t) >= 60.0 then
                    local has_enemy = utils.get_closest_enemy() ~= nil
                                   or utils.get_suppressor() ~= nil
                    if not has_enemy then
                        return false  -- let sigil_complete handle the exit
                    end
                end
                return true
            end
        end
        if nav.state ~= STATE.IDLE then
            -- Arrived via MAP_NAV/WALKING/ENTERING — reset and record entry time
            local fresh = nav.state == STATE.MAP_NAV
                       or nav.state == STATE.WALKING
                       or nav.state == STATE.ENTERING
            reset_nav()
            if fresh and boss.run_type == "sigil" then
                tracker.sigil_entry_t = now()
            end
        end
        return false
    end

    if nav.state ~= STATE.IDLE then return true end
    return true
end

-- -------------------------------------------------------
-- Execute
-- -------------------------------------------------------
function task.Execute()
    local boss = rotation.current()
    if not boss then return end
    local t = now()

    -- ---- IDLE ----
    if nav.state == STATE.IDLE then
        nav.target_boss    = boss
        nav.attempts       = 0
        nav.path_exhausted = false

        if in_target_zone(boss) then
            if utils.get_altar() ~= nil then reset_nav(); return end
            -- Stale sigil dungeon: sigil_entry_t expired with no altar found
            if boss.run_type == "sigil" and tracker.sigil_entry_t > 0
                    and (now() - tracker.sigil_entry_t) > 60.0 then
                console.print("[Reaper] Sigil zone with no altar and entry expired — stale dungeon, teleporting out.")
                teleport_to_waypoint(CERRIGAR_WP)
                set_state(STATE.WAIT_EXIT)
                return
            end
            -- Use Batmobile to navigate to the altar area
            console.print("[Reaper] In zone — using Batmobile to navigate to altar area.")
            if BatmobilePlugin then
                BatmobilePlugin.reset(plugin_label)
                BatmobilePlugin.resume(plugin_label)
            end
            set_state(STATE.PATHWALKING)
            return
        end

        -- Sigil run: wait to confirm we're in Cerrigar, then activate the sigil
        if boss.run_type == "sigil" then
            local zone = utils.get_zone()
            if zone ~= CERRIGAR_ZONE then
                _sigil_settle_t = -999  -- reset if not in Cerrigar
                return
            end
            if _sigil_settle_t < 0 then
                _sigil_settle_t = t  -- start settle timer on first Cerrigar tick
                console.print(string.format("[Reaper] In Cerrigar — waiting %.0fs before sigil activation.", T_SIGIL_SETTLE))
            end
            if (t - _sigil_settle_t) < T_SIGIL_SETTLE then return end
            _sigil_settle_t = -999  -- reset for next time

            local sigil = find_sigil_for_boss(boss.id)
            if not sigil then
                console.print("[Reaper] No sigil found for " .. boss.label .. " — skipping.")
                rotation.advance()
                reset_nav()
                return
            end
            console.print("[Reaper] Using sigil for " .. boss.label)
            tracker.sigil_entry_t = now()  -- start the 60s fresh-entry window
            local ok, err = pcall(use_item, sigil)
            if not ok then
                console.print("[Reaper] use_item failed: " .. tostring(err))
                tracker.sigil_entry_t = -999
                reset_nav()
                return
            end
            set_state(STATE.USE_SIGIL)
            return
        end

        -- Material run: teleport via map_nav
        map_nav.start(boss.id, boss.zone_prefix, false)
        set_state(STATE.MAP_NAV)
        return
    end

    -- ---- USE_SIGIL: confirm dialog then navigate to boss dungeon ----
    if nav.state == STATE.USE_SIGIL then
        if (t - nav.phase_start) >= T_CONFIRM then
            console.print("[Reaper] Confirming sigil notification...")
            utility.confirm_sigil_notification()
            map_nav.start(boss.id, boss.zone_prefix, true)
            set_state(STATE.MAP_NAV)
        end
        return
    end

    -- ---- MAP_NAV: drive teleport state machine ----
    if nav.state == STATE.MAP_NAV then
        map_nav.update()

        if map_nav.is_done() or in_target_zone(boss) then
            console.print("[Reaper] Arrived: " .. utils.get_zone())
            nav.attempts = 0
            if boss.run_type == "sigil" then
                tracker.sigil_entry_t = now()
            end
            map_nav.reset()
            if BatmobilePlugin then
                BatmobilePlugin.resume(plugin_label)
            end
            set_state(STATE.PATHWALKING)
            return
        end

        if not map_nav.is_active() then
            nav.attempts = nav.attempts + 1
            console.print(string.format("[Reaper] Map nav attempt %d/%d failed — retrying.",
                nav.attempts, nav.max_attempts))
            if nav.attempts >= nav.max_attempts then
                console.print("[Reaper] Giving up after " .. nav.max_attempts .. " attempts.")
                reset_nav(); return
            end
            map_nav.start(boss.id, boss.zone_prefix, boss.run_type == "sigil")
        end
        return
    end

    -- ---- PATHWALKING ----
    if nav.state == STATE.PATHWALKING then
        local altar = utils.get_altar()
        if altar and utils.distance_to(altar) <= 5.0 then
            console.print("[Reaper] Altar in range — navigation done.")
            reset_nav()
            return
        end

        if settings.use_batmobile then
            -- ---- Batmobile branch ----
            if altar then
                console.print("[Reaper] Altar visible — starting long path to altar.")
                local ok = BatmobilePlugin and BatmobilePlugin.navigate_long_path(plugin_label, altar:get_position())
                if ok then
                    set_state(STATE.LONG_PATHING)
                else
                    console.print("[Reaper] Long path blocked — switching to EXPLORING.")
                    nav.exploring_retries = 0
                    set_state(STATE.EXPLORING)
                end
            else
                console.print("[Reaper] No altar visible — switching to EXPLORING.")
                nav.exploring_retries = 0
                set_state(STATE.EXPLORING)
            end
        else
            -- ---- Path-file branch ----
            if not pathwalker.is_walking then
                local variants = load_variants(boss.id)
                local path = pick_best_path(variants)
                if path then
                    pathwalker.start_walking_path_with_points(path, boss.id)
                else
                    console.print("[Reaper] No path variants found for " .. boss.id .. " — skipping.")
                    nav.path_exhausted = true
                    reset_nav()
                    return
                end
            end
            if pathwalker.is_path_completed() then
                console.print("[Reaper] Path complete.")
                pathwalker.stop_walking()
                reset_nav()
                return
            end
            pathwalker.update_path_walking()
        end
        return
    end

    -- ---- LONG_PATHING: Batmobile drives navigation; we just wait ----
    if nav.state == STATE.LONG_PATHING then
        local altar = utils.get_altar()
        if altar and utils.distance_to(altar) <= 5.0 then
            console.print("[Reaper] Altar in range — long path navigation done.")
            reset_nav()
            return
        end
        if not BatmobilePlugin or not BatmobilePlugin.is_long_path_navigating() then
            -- Long path ended (success or failure)
            if altar then
                local dist = utils.distance_to(altar)
                if dist <= 5.0 then
                    reset_nav()
                else
                    -- Got closer but not there yet — re-fire to altar
                    console.print(string.format("[Reaper] Long path ended, dist=%.1f — re-firing to altar.", dist))
                    local ok = BatmobilePlugin and BatmobilePlugin.navigate_long_path(plugin_label, altar:get_position())
                    if not ok then
                        nav.exploring_retries = 0
                        set_state(STATE.EXPLORING)
                    end
                    nav.phase_start = now()
                end
            else
                console.print("[Reaper] Long path ended, no altar — switching to EXPLORING.")
                nav.exploring_retries = 0
                set_state(STATE.EXPLORING)
            end
            return
        end
        -- Timeout guard
        if (now() - nav.phase_start) > 60.0 then
            console.print("[Reaper] Long path timeout — switching to EXPLORING.")
            if BatmobilePlugin then BatmobilePlugin.stop_long_path(plugin_label) end
            nav.exploring_retries = 0
            set_state(STATE.EXPLORING)
        end
        return
    end

    -- ---- EXPLORING: drive Batmobile normally; retry long path once altar visible ----
    if nav.state == STATE.EXPLORING then
        local altar = utils.get_altar()
        if altar and utils.distance_to(altar) <= 5.0 then
            console.print("[Reaper] Altar in range — done.")
            reset_nav()
            return
        end
        if (now() - nav.phase_start) >= 10.0 then
            if altar then
                -- Altar now visible — attempt long path
                nav.exploring_retries = nav.exploring_retries + 1
                console.print(string.format("[Reaper] EXPLORING: altar visible, long path retry %d...", nav.exploring_retries))
                local ok = BatmobilePlugin and BatmobilePlugin.navigate_long_path(plugin_label, altar:get_position())
                if ok then
                    console.print("[Reaper] Long path found — switching to LONG_PATHING.")
                    set_state(STATE.LONG_PATHING)
                    return
                end
            else
                nav.exploring_retries = nav.exploring_retries + 1
                console.print(string.format("[Reaper] EXPLORING: no altar yet (retry %d)...", nav.exploring_retries))
            end
            nav.phase_start = now()
            if nav.exploring_retries >= 15 then
                if boss.run_type == "sigil" then
                    console.print("[Reaper] EXPLORING: sigil dungeon exhausted — teleporting out.")
                    teleport_to_waypoint(CERRIGAR_WP)
                    set_state(STATE.WAIT_EXIT)
                else
                    console.print("[Reaper] EXPLORING: max retries exceeded — resetting.")
                    nav.path_exhausted = true
                    reset_nav()
                end
                return
            end
        end
        -- Drive Batmobile toward boss room each tick
        if BatmobilePlugin then
            local seed = enums.positions.getBossRoomPosition(boss.zone_prefix)
            -- Prefer altar position when visible; fall back to seed for direction only
            local drive_target = altar and altar:get_position() or seed
            if not BatmobilePlugin.set_target(plugin_label, drive_target) then
                BatmobilePlugin.clear_target(plugin_label)
            end
            BatmobilePlugin.resume(plugin_label)
            BatmobilePlugin.update(plugin_label)
            BatmobilePlugin.move(plugin_label)
        end
        return
    end

    -- ---- WALKING: walk to dungeon entrance ----
    if nav.state == STATE.WALKING then
        if in_target_zone(boss) and not utils.get_dungeon_entrance() then
            reset_nav(); return
        end
        if (t - nav.phase_start) < T_SETTLE then return end

        local entrance = utils.get_dungeon_entrance()
        if entrance then
            if utils.distance_to(entrance) <= 3.5 then
                if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
                nav.last_enter_try = 0
                set_state(STATE.ENTERING)
            else
                if BatmobilePlugin then
                    BatmobilePlugin.set_target(plugin_label, entrance)
                    BatmobilePlugin.update(plugin_label)
                    BatmobilePlugin.move(plugin_label)
                else
                    pathfinder.request_move(entrance:get_position())
                end
            end
        else
            local seed = enums.positions.getBossRoomPosition(boss.zone_prefix)
            if utils.distance_to(seed) > 5.0 then
                pathfinder.request_move(seed)
            end
        end
        return
    end

    -- ---- ENTERING ----
    if nav.state == STATE.ENTERING then
        if in_target_zone(boss) and not utils.get_dungeon_entrance() then
            console.print("[Reaper] Entered " .. utils.get_zone())
            reset_nav(); return
        end
        if (t - nav.phase_start) > T_ENTER then reset_nav(); return end
        if (t - nav.last_enter_try) >= 1.5 then
            nav.last_enter_try = t
            local entrance = utils.get_dungeon_entrance()
            if entrance then
                loot_manager.interact_with_object(entrance)
            else
                set_state(STATE.WALKING)
            end
        end
        return
    end

    -- ---- WAIT_EXIT: waiting to leave a completed sigil dungeon ----
    if nav.state == STATE.WAIT_EXIT then
        if not in_target_zone(boss) then
            console.print("[Reaper] Left completed dungeon — restarting run.")
            reset_nav()
            return
        end
        if (now() - nav.phase_start) > 20.0 then
            console.print("[Reaper] WAIT_EXIT timeout — retrying teleport.")
            teleport_to_waypoint(CERRIGAR_WP)
            nav.phase_start = now()
        end
        return
    end
end

return task
