-- ============================================================
--  Reaper - tasks/navigate_to_boss.lua
--
--  Flow (D4Assistant mode, default):
--    D4A_TELEPORT → write command.txt, wait for D4Assistant to teleport
--    PATHWALKING  → walk recorded path to altar
--    WALKING      → walk to dungeon entrance portal
--    ENTERING     → interact with portal to enter
--
--  Flow (map-click fallback, use_d4a disabled):
--    MAP_NAV      → delegate to core/map_nav.lua (waypoint → map click → boss)
--    (then same PATHWALKING / WALKING / ENTERING)
-- ============================================================

local utils        = require "core.utils"
local enums        = require "data.enums"
local explorerlite = require "core.explorerlite"
local pathwalker   = require "core.pathwalker"
local map_nav      = require "core.map_nav"
local d4a          = require "core.d4a_command"
local settings     = require "core.settings"
local rotation     = require "core.boss_rotation"
local tracker      = require "core.tracker"

-- -------------------------------------------------------
-- Altar paths
-- -------------------------------------------------------
local cached_variants = {}
local VARIANT_SUFFIXES = { "_a", "_b", "_c", "_d" }

local function load_variants(boss_id)
    if cached_variants[boss_id] ~= nil then return end
    local found = {}
    for _, suffix in ipairs(VARIANT_SUFFIXES) do
        local mod = "paths." .. boss_id .. suffix
        local ok, result = pcall(require, mod)
        if ok and type(result) == "table" and #result > 0 then
            table.insert(found, { name = mod, points = result })
            console.print(string.format("[Reaper] Path loaded: %s (%d pts)", mod, #result))
        end
    end
    cached_variants[boss_id] = (#found > 0) and found or false
end

local function pick_best_path(boss_id)
    load_variants(boss_id)
    local variants = cached_variants[boss_id]
    if not variants then return nil end
    if #variants == 1 then return variants[1].points end
    local player_pos = get_player_position()
    if not player_pos then return variants[1].points end
    local best, best_dist = variants[1], math.huge
    for _, v in ipairs(variants) do
        local dist = player_pos:dist_to_ignore_z(v.points[1].pos or v.points[1])
        if dist < best_dist then best = v; best_dist = dist end
    end
    console.print(string.format("[Reaper] Variant: %s (%.1fm)", best.name, best_dist))
    return best.points
end

local function needs_path_walk(boss_id)
    load_variants(boss_id)
    local v = cached_variants[boss_id]
    return v and #v > 0
end

-- -------------------------------------------------------
-- Zone helpers
-- -------------------------------------------------------
local function in_target_zone(boss)
    local zone = utils.get_zone()
    -- For sigil runs the lair dungeon zone won't match the boss zone_prefix,
    -- so accept any lair boss zone as valid
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
                if name:find("^EGB_Chest") or name:find("^Boss_WT_Belial_") or name:find("^Chest_Boss") then
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
            -- Track the first sigil as fallback
            if not first_sigil then first_sigil = item end

            local ok_d, display = pcall(function() return item:get_display_name() end)
            if ok_d and display then
                local mapped = mats.boss_from_display(display)
                if mapped == boss_id then
                    return item  -- exact match
                end
            end
        end
    end

    -- No exact match — return first available sigil (unmapped location)
    return first_sigil
end

-- -------------------------------------------------------
-- State machine
-- -------------------------------------------------------
local STATE = {
    IDLE          = "IDLE",
    USE_SIGIL     = "USE_SIGIL",      -- activate sigil item
    CONFIRM_SIGIL = "CONFIRM_SIGIL",  -- confirm consume dialog, send D4A command
    WAIT_PORTAL   = "WAIT_PORTAL",    -- wait for zone to change to boss dungeon
    D4A_TELEPORT  = "D4A_TELEPORT",   -- waiting for D4Assistant to teleport us
    MAP_NAV       = "MAP_NAV",        -- map_nav handles waypoint + click (fallback)
    PATHWALKING   = "PATHWALKING",
    WALKING      = "WALKING",
    ENTERING     = "ENTERING",
}

local T_CONFIRM    = 0.8    -- wait after use_item before confirming
local T_PORTAL_MAX = 60.0   -- max wait for D4A to teleport us into the dungeon

local nav = {
    state          = STATE.IDLE,
    target_boss    = nil,
    phase_start    = -999,  -- initialised far in the past so no stale timeouts
    attempts       = 0,
    max_attempts   = 5,
    last_enter_try = 0,
    path_exhausted = false,
    d4a_sent       = false,
}

local T_ZONE      = 45.0
local T_D4A_RETRY = 8.0
local T_SETTLE    = 2.5
local T_ENTER     = 15.0

local function now() return get_time_since_inject() end
local function set_state(s) nav.state = s; nav.phase_start = now() end

local function reset_nav()
    nav.state          = STATE.IDLE
    nav.target_boss    = nil
    nav.phase_start    = now()  -- always current so timeout checks start fresh
    nav.attempts       = 0
    nav.path_exhausted = false
    nav.d4a_sent       = false
    map_nav.reset()
    pathwalker.stop_walking()
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

    -- Clear path_exhausted after death
    if tracker.just_revived then
        nav.path_exhausted   = false
        tracker.just_revived = false
        console.print("[Reaper] Post-revive: re-enabling path walk.")
    end

    -- While map_nav is actively running, always execute so map_nav.update()
    -- is called every tick and zone detection works regardless of altar state.
    if nav.state == STATE.MAP_NAV then return true end

    if tracker.altar_activated then return false end
    if in_target_zone(boss) and chest_visible() then return false end
    if in_target_zone(boss) and utils.get_altar() ~= nil then return false end

    if in_target_zone(boss) then
        -- For sigil runs with no recorded path, stay active so IDLE can
        -- use explorerlite to find the altar
        if boss.run_type == "sigil" then
            if nav.state == STATE.IDLE or nav.state == STATE.PATHWALKING then
                return true
            end
        end
        if needs_path_walk(boss.id) and not nav.path_exhausted then
            if nav.state == STATE.IDLE or nav.state == STATE.PATHWALKING then
                return true
            end
        end
        if nav.state ~= STATE.IDLE then reset_nav() end
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

    -- ---- IDLE: decide first step ----
    if nav.state == STATE.IDLE then
        nav.target_boss    = boss
        nav.attempts       = 0
        nav.path_exhausted = false
        nav.d4a_sent       = false

        if in_target_zone(boss) then
            if utils.get_altar() ~= nil then reset_nav(); return end
            -- For sigil runs already in the lair, explore toward the altar
            if boss.run_type == "sigil" then
                console.print("[Reaper] In sigil lair — exploring for altar.")
                explorerlite:set_custom_target(enums.positions.getBossRoomPosition(boss.zone_prefix))
                explorerlite:move_to_target()
                return
            end
            if needs_path_walk(boss.id) then
                pathwalker.start_walking_path_with_points(
                    pick_best_path(boss.id), boss.id .. "_path", false)
                set_state(STATE.PATHWALKING)
                console.print("[Reaper] In zone – walking to altar.")
            else
                reset_nav()
            end
            return
        end

        -- Sigil run: activate the sigil, don't use D4A teleport
        if boss.run_type == "sigil" then
            local sigil = find_sigil_for_boss(boss.id)
            if not sigil then
                console.print("[Reaper] No sigil found for " .. boss.label .. " — skipping.")
                rotation.advance()
                reset_nav()
                return
            end
            console.print("[Reaper] Using sigil for " .. boss.label)
            local ok, err = pcall(use_item, sigil)
            if not ok then
                console.print("[Reaper] use_item failed: " .. tostring(err))
                reset_nav()
                return
            end
            set_state(STATE.USE_SIGIL)
            return
        end

        if settings.use_d4a then
            local sent = d4a.send_teleport(boss.id)
            if sent then
                console.print(string.format("[Reaper] D4A teleport sent for %s.", boss.id))
                nav.d4a_sent = true
            else
                console.print("[Reaper] D4A command failed – will retry.")
            end
            set_state(STATE.D4A_TELEPORT)
        else
            map_nav.start(boss.id, boss.zone_prefix, boss.run_type == "sigil")
            set_state(STATE.MAP_NAV)
        end
        return
    end

    -- ---- USE_SIGIL: wait then confirm the consume dialog ----
    if nav.state == STATE.USE_SIGIL then
        if (t - nav.phase_start) >= T_CONFIRM then
            console.print("[Reaper] Confirming sigil notification...")
            utility.confirm_sigil_notification()
            set_state(STATE.CONFIRM_SIGIL)
        end
        return
    end

    -- ---- CONFIRM_SIGIL: wait a moment then send D4A to click map ----
    if nav.state == STATE.CONFIRM_SIGIL then
        if (t - nav.phase_start) >= 1.0 then
            console.print("[Reaper] Sending D4A START_NMD_SKIP_SIGIL...")
            d4a.send_start_nmd_skip_sigil()
            set_state(STATE.WAIT_PORTAL)
        end
        return
    end

    -- ---- WAIT_PORTAL: wait for zone to change to boss dungeon ----
    if nav.state == STATE.WAIT_PORTAL then
        -- Check if we've loaded into a boss zone
        if in_target_zone(boss) then
            console.print("[Reaper] Entered sigil dungeon: " .. utils.get_zone())
            reset_nav()
            return
        end

        -- Also check for generic lair boss zone pattern
        local zone = utils.get_zone()
        if zone:find("Boss_WT") or zone:find("Boss_Kehj") or zone:find("S12_Boss") then
            console.print("[Reaper] Entered boss zone: " .. zone)
            reset_nav()
            return
        end

        if (t - nav.phase_start) >= T_PORTAL_MAX then
            nav.attempts = nav.attempts + 1
            console.print(string.format("[Reaper] Sigil zone timeout — attempt %d/%d",
                nav.attempts, nav.max_attempts))
            if nav.attempts >= nav.max_attempts then
                console.print("[Reaper] Giving up on sigil run — skipping.")
                rotation.advance()
                reset_nav()
            else
                -- Retry D4A command
                d4a.send_start_nmd_skip_sigil()
                nav.phase_start = t
            end
        end
        return
    end

    -- ---- D4A_TELEPORT: wait for D4Assistant to teleport us ----
    if nav.state == STATE.D4A_TELEPORT then
        -- Success: we arrived in the target zone
        if in_target_zone(boss) then
            console.print("[Reaper] D4A teleport arrived: " .. utils.get_zone())
            nav.attempts   = 0
            nav.d4a_sent   = false
            if needs_path_walk(boss.id) then
                pathwalker.start_walking_path_with_points(
                    pick_best_path(boss.id), boss.id .. "_path", false)
                set_state(STATE.PATHWALKING)
            else
                set_state(STATE.WALKING)
            end
            return
        end

        local elapsed = t - nav.phase_start

        -- Retry: resend command if D4A consumed it but zone never arrived
        if elapsed >= T_D4A_RETRY then
            nav.attempts = nav.attempts + 1
            console.print(string.format("[Reaper] D4A teleport attempt %d/%d timed out – retrying.",
                nav.attempts, nav.max_attempts))
            if nav.attempts >= nav.max_attempts then
                console.print("[Reaper] D4A teleport giving up after " .. nav.max_attempts .. " attempts.")
                reset_nav()
                return
            end
            local sent = d4a.send_teleport(boss.id)
            if sent then
                console.print(string.format("[Reaper] D4A retry %d sent for %s.", nav.attempts, boss.id))
                nav.d4a_sent = true
            end
            nav.phase_start = t  -- reset timer for next wait period
        end
        return
    end

    -- ---- MAP_NAV: drive map_nav state machine (fallback mode) ----
    if nav.state == STATE.MAP_NAV then
        map_nav.update()

        -- map_nav signals DONE when it detects the boss zone internally (every
        -- tick in WAIT_ZONE), or we catch it here as a belt-and-suspenders check.
        -- Reset to IDLE and let the normal IDLE-in-zone logic decide what to do
        -- next (pathwalk if a path exists, or yield to interact_altar directly).
        -- Do NOT start pathwalking here — that would fight with interact_altar.
        if map_nav.is_done() or in_target_zone(boss) then
            console.print("[Reaper] Arrived: " .. utils.get_zone())
            reset_nav()
            return
        end

        if not map_nav.is_active() then
            nav.attempts = nav.attempts + 1
            console.print(string.format("[Reaper] Map nav attempt %d/%d failed – retrying.",
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
            console.print("[Reaper] Altar in range – path done.")
            pathwalker.stop_walking()
            reset_nav()
            return
        end
        if pathwalker.is_path_completed() or pathwalker.is_at_final_waypoint() then
            console.print("[Reaper] Path finished.")
            pathwalker.stop_walking()
            nav.path_exhausted = true
            nav.state          = STATE.IDLE
            return
        end
        pathwalker.update_path_walking()
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
                nav.last_enter_try = 0
                set_state(STATE.ENTERING)
            else
                explorerlite:set_custom_target(entrance:get_position())
                explorerlite:move_to_target()
            end
        else
            local seed = enums.positions.getBossRoomPosition(boss.zone_prefix)
            if utils.distance_to(seed) > 5.0 then
                pathfinder.request_move(seed)
            else
                explorerlite:move_to_target()
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
end

return task
