-- ============================================================
--  Reaper - tasks/open_chest.lua
--
--  Phases:
--    MAIN          → walk to EGB/Belial chest, interact
--    WAIT_GONE     → wait for main chest to despawn (up to 8s)
--                    if it never despawns = out of materials → stop
--    THEME         → look for DOOM/seasonal theme chest (up to 20s)
--    WAIT_COMPLETE → 3s pause, then consume_run + reset for next cycle
-- ============================================================

local utils        = require "core.utils"
local tracker      = require "core.tracker"
local explorerlite = require "core.explorerlite"
local rotation     = require "core.boss_rotation"
local enums        = require "data.enums"

-- ---- Config ----
local CHEST_INTERACT_COOLDOWN = 10   -- min seconds between interact attempts
local WAIT_GONE_SECS          = 10   -- if chest still here after this → out of mats
local THEME_WAIT_SECS         = 20   -- seconds to look for theme chest
local WAIT_COMPLETE_SECS      = 3    -- pause after all chests before next run
local OUT_OF_MATS_RETRIES     = 3    -- times chest can fail to despawn before stopping

-- ---- State ----
local phase                  = "IDLE"
local phase_start            = 0
local last_interact_time     = 0
local last_chest_pos         = nil
local no_despawn_count       = 0    -- counts consecutive failures to despawn

local function set_phase(p)
    phase       = p
    phase_start = os.time()
    console.print("[Chest] Phase: " .. p)
end

local function phase_elapsed()
    return os.time() - phase_start
end

local function cooldown_ok()
    return (os.time() - last_interact_time) >= CHEST_INTERACT_COOLDOWN
end

-- ---- Actor finders ----
local function _interactable(a)
    if not a then return false end
    local ok, v = pcall(function() return a:is_interactable() end)
    return ok and v == true
end

local function find_egb_chest()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= "table" then return nil end
    for _, a in pairs(actors) do
        if _interactable(a) then
            local n = a:get_skin_name()
            if type(n) == "string" then
                if n:find("^EGB_Chest") or n:find("^Boss_WT_Belial_") or n:find("^Chest_Boss") then
                    return a
                end
            end
        end
    end
    return nil
end

local function find_theme_chest()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= "table" then return nil end
    local best, best_dist = nil, math.huge
    local lp = get_local_player()
    local pp = lp and lp:get_position()
    for _, a in pairs(actors) do
        local n = a:get_skin_name()
        if type(n) == "string" and n:find("^S12_Prop_Theme_Chest_") then
            -- case-insensitive dyn check
            if n:lower():find("_dyn") then
                if pp then
                    local d = pp:dist_to(a:get_position())
                    if d < best_dist then best = a; best_dist = d end
                else
                    return a
                end
            end
        end
    end
    return best
end

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

-- ---- Stuck helpers ----
local last_pos = nil
local last_move_t = 0
local unstuck_start = 0

local function check_stuck()
    local pos = get_player_position()
    local t   = os.time()
    if last_pos and utils.distance_to(last_pos) < 0.1 then
        if t - last_move_t > 20 then
            if t - last_move_t >= 30 then last_move_t = t; return true end
        end
    else
        last_move_t = t
    end
    last_pos = pos
    return false
end

local function try_movement_spell(target)
    local lp = get_local_player()
    if not lp then return end
    for _, sid in ipairs({288106,358761,355606,1663206,1871821,337031}) do
        if lp:is_spell_ready(sid) then
            if cast_spell.position(sid, target, 3.0) then return end
        end
    end
end

-- -------------------------------------------------------
local task = { name = "Open Chest" }

function task.shouldExecute()
    if not in_target_boss_zone() then
        if phase ~= "IDLE" then
            set_phase("IDLE")
            no_despawn_count = 0
        end
        return false
    end
    -- Active mid-sequence
    if phase == "WAIT_GONE" or phase == "THEME" or phase == "WAIT_COMPLETE" then
        return true
    end
    -- For sigil runs there is no EGB chest — jump straight to THEME phase
    -- when the altar has been activated. Stop once chest is done.
    local boss = rotation.current()
    if boss and boss.run_type == "sigil" then
        return tracker.altar_activated and phase == "IDLE" and not tracker.sigil_chest_done
    end
    -- Trigger on chest visibility
    return find_egb_chest() ~= nil
end

function task.Execute()
    local t = get_time_since_inject()

    -- Stuck recovery
    if check_stuck() then
        local ut = explorerlite.find_unstuck_target()
        if ut then
            try_movement_spell(ut)
            pathfinder.force_move_raw(ut)
        end
        return
    end

    -- ---- IDLE / MAIN: find and open the EGB chest ----
    if phase == "IDLE" or phase == "MAIN" then
        -- Sigil runs have no EGB chest — go straight to Doom chest
        local boss = rotation.current()
        if boss and boss.run_type == "sigil" then
            console.print("[Chest] Sigil run — skipping to Doom chest.")
            set_phase("THEME")
            return
        end

        local chest = find_egb_chest()
        if not chest then return end

        local dist = utils.distance_to(chest:get_position())
        if dist > 2.5 then
            explorerlite:set_custom_target(chest:get_position())
            explorerlite:move_to_target()
            return
        end

        if not cooldown_ok() then return end

        interact_object(chest)
        last_interact_time = os.time()
        tracker.chest_opened_time = last_interact_time
        last_chest_pos = chest:get_position()

        -- Signal Belial chest UI task
        local n = chest:get_skin_name()
        if type(n) == "string" and n:find("^Boss_WT_Belial_") then
            tracker.belial_chest_interacted = true
            console.print("[Chest] Belial chest interacted – signalling UI task.")
        end

        set_phase("WAIT_GONE")
        return
    end

    -- ---- WAIT_GONE: wait for chest to despawn ----
    if phase == "WAIT_GONE" then
        local chest = find_egb_chest()

        if chest == nil then
            -- Chest gone – proceed to theme chest
            no_despawn_count = 0
            set_phase("THEME")
            return
        end

        if phase_elapsed() < WAIT_GONE_SECS then return end

        -- Chest still here after timeout
        no_despawn_count = no_despawn_count + 1
        console.print(string.format("[Chest] Chest didn't despawn (%d/%d) – out of materials?",
            no_despawn_count, OUT_OF_MATS_RETRIES))

        if no_despawn_count >= OUT_OF_MATS_RETRIES then
            console.print("[Chest] Out of summoning materials – skipping to next boss.")
            no_despawn_count = 0

            local boss = rotation.current()
            if boss then
                console.print("[Chest] " .. boss.label .. " – no materials, skipping.")
                boss.runs_remaining = 0
            end
            -- Force advance to next boss
            rotation.advance()
            tracker.reset_run()
            set_phase("IDLE")
        else
            -- Try interacting again
            if cooldown_ok() then
                interact_object(chest)
                last_interact_time = os.time()
            end
            set_phase("WAIT_GONE")
        end
        return
    end

    -- ---- THEME: find and open the DOOM/seasonal chest ----
    if phase == "THEME" then
        if phase_elapsed() > THEME_WAIT_SECS then
            console.print("[Chest] No theme chest found – continuing.")
            set_phase("WAIT_COMPLETE")
            return
        end

        local chest = find_theme_chest()
        if not chest then
            -- Hang near where the EGB chest was
            if last_chest_pos and utils.distance_to(last_chest_pos) > 2.5 then
                explorerlite:set_custom_target(last_chest_pos)
                explorerlite:move_to_target()
            end
            return
        end

        local dist = utils.distance_to(chest:get_position())
        if dist > 2.5 then
            explorerlite:set_custom_target(chest:get_position())
            explorerlite:move_to_target()
            return
        end

        -- Close enough — wait until it becomes interactable, then open
        if not _interactable(chest) then return end
        if not cooldown_ok() then return end

        interact_object(chest)
        last_interact_time = os.time()
        tracker.chest_opened_time = last_interact_time
        console.print("[Chest] Theme chest opened.")
        set_phase("WAIT_COMPLETE")
        return
    end

    -- ---- WAIT_COMPLETE: brief pause then start next run ----
    if phase == "WAIT_COMPLETE" then
        if phase_elapsed() >= WAIT_COMPLETE_SECS then
            local boss = rotation.current()
            if boss and boss.run_type == "sigil" then
                console.print("[Chest] Doom chest done — returning to altar for loot.")
                tracker.sigil_chest_done = true
                -- Walk back to altar so ground loot gets picked up
                local altar = utils.get_altar()
                local anchor = altar and altar:get_position()
                    or enums.positions.getBossRoomPosition(boss.zone_prefix)
                if anchor then
                    explorerlite:set_custom_target(anchor)
                    explorerlite:move_to_target()
                end
            else
                console.print("[Chest] Run complete.")
                rotation.consume_run()
                tracker.reset_run()
            end
            set_phase("IDLE")
            last_chest_pos = nil
        end
        return
    end
end

return task
