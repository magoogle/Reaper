-- ============================================================
--  Reaper - tasks/open_chest.lua
--
--  Phases:
--    MAIN             → walk to EGB/Belial chest, interact
--    WAIT_GONE        → wait for main chest to despawn (up to WAIT_GONE_SECS)
--                       if it never despawns = out of keys/husks → stop
--    EXTRAS           → loop opening any remaining EGB_Chest_* (multiple may spawn
--                       at the same time on lucky runs)
--    NEMESIS_LOOK     → scan briefly for a Warplans_Portal_NemesisPortal (random
--                       post-loot spawn); on timeout fall through to WAIT_COMPLETE
--    NEMESIS_APPROACH → walk to the portal and interact; hand off to nemesis_fight
--                       on the interact call itself (NOT on zone change) so its
--                       higher priority preempts navigate_to_boss during the
--                       brief loading window. nemesis_fight confirms the lair
--                       zone (Warplans_Boss_NemesisLair) before arming its timer.
--    WAIT_COMPLETE    → brief pause to loot, then consume_run + reset for next cycle
--
--  When the nemesis flow is entered, consume_run is performed by nemesis_fight
--  after the lair-clear timer expires — NOT by WAIT_COMPLETE.
--
--  Doom/seasonal "theme" chest was removed from D4 (2026-05-03 patch);
--  the entire THEME phase and S12_Prop_Theme_Chest_* logic is gone. The
--  EGB/boss chest IS the run-completion signal.
-- ============================================================

local utils     = require "core.utils"
local tracker   = require "core.tracker"
local rotation  = require "core.boss_rotation"
local settings  = require "core.settings"
local enums     = require "data.enums"

-- ---- Config ----
local CHEST_INTERACT_COOLDOWN = 0.5  -- min seconds between EGB chest interact attempts
local WAIT_GONE_SECS          = 10   -- if chest still here after this → out of mats
local OUT_OF_MATS_RETRIES     = 3    -- times chest can fail to despawn before stopping
local NEMESIS_LOOK_SECS       = 12   -- scan window for nemesis portal after extras
local NEMESIS_APPROACH_SECS   = 20   -- give up walking to portal after this
local NEMESIS_INTERACT_CD     = 1.0  -- min seconds between portal interact attempts

-- ---- State ----
local phase              = "IDLE"
local phase_start        = 0
local last_interact_time = 0
local last_chest_pos     = nil
local no_despawn_count   = 0    -- counts consecutive failures to despawn
-- Saved zone prefix of the boss we were running when the main chest popped.
-- Lets shouldExecute keep open_chest's state coherent if the player has
-- (e.g.) just stepped into the nemesis portal — rotation.current() is still
-- the same boss but utils.get_zone() no longer matches.
local home_zone_prefix   = nil
-- NEMESIS_APPROACH: position of the portal we're walking to.
local nemesis_portal_pos = nil
local nemesis_interact_t = 0
-- EXTRAS: positions of EGB chests we've already fired interact on. Dedup by
-- proximity so we don't re-click the same chest while it's still listed but
-- already despawning.
local extras_done_positions = {}
local EXTRAS_DEDUP_RADIUS   = 1.5
local EXTRAS_PHASE_TIMEOUT  = 25  -- hard cap on the EXTRAS sweep

local function set_phase(p)
    phase       = p
    phase_start = os.time()
    console.print("[Chest] Phase: " .. p)
end

local function phase_elapsed()
    return os.time() - phase_start
end

local function cooldown_ok()
    return (get_time_since_inject() - last_interact_time) >= CHEST_INTERACT_COOLDOWN
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
    local best, best_dist = nil, math.huge
    local lp = get_local_player()
    local pp = lp and lp:get_position()
    for _, a in pairs(actors) do
        if _interactable(a) then
            local n = a:get_skin_name()
            if type(n) == "string" then
                if n:find("^EGB_Chest") or n:find("^Boss_WT_Belial_") or n:find("^Chest_Boss") then
                    local d = pp and pp:dist_to(a:get_position()) or 0
                    if d < best_dist then best = a; best_dist = d end
                end
            end
        end
    end
    return best
end

-- EGB-only variant for the EXTRAS phase. Multi-chest spawns are an EGB
-- behaviour (Belial/boss-chest events are always single), so we restrict the
-- secondary sweep to EGB_Chest_* and ignore the other patterns.
local function _was_already_opened(pos)
    for _, p in ipairs(extras_done_positions) do
        if pos:dist_to(p) < EXTRAS_DEDUP_RADIUS then return true end
    end
    return false
end

local function find_extra_egb_chest()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= "table" then return nil end
    local best, best_dist = nil, math.huge
    local lp = get_local_player()
    local pp = lp and lp:get_position()
    for _, a in pairs(actors) do
        if _interactable(a) then
            local n = a:get_skin_name()
            if type(n) == "string" and n:find("^EGB_Chest") then
                local apos = a:get_position()
                if not _was_already_opened(apos) then
                    local d = pp and pp:dist_to(apos) or 0
                    if d < best_dist then best = a; best_dist = d end
                end
            end
        end
    end
    return best
end

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

local function in_target_boss_zone()
    local boss = rotation.current()
    if not boss then return false end
    local zone = utils.get_zone()
    return zone:match(boss.zone_prefix) ~= nil
end

-- ---- Stuck helpers ----
local last_pos = nil
local last_move_t = 0

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
    -- Hand off entirely to nemesis_fight while it's running; we'll resume
    -- (or stay IDLE) once the run is counted there.
    if tracker.nemesis_entered then
        return false
    end

    -- Once we click the portal, NEMESIS_APPROACH sets nemesis_entered=true
    -- and resets phase to IDLE in the same tick, so the zone gate below never
    -- has to reason about a "mid-transition" state — by the time the player's
    -- zone actually changes, we've already handed off.
    if not in_target_boss_zone() then
        if phase ~= "IDLE" then
            set_phase("IDLE")
            no_despawn_count   = 0
            home_zone_prefix   = nil
            nemesis_portal_pos = nil
        end
        return false
    end
    -- Active mid-sequence (any non-IDLE phase keeps us in control)
    if phase == "WAIT_GONE" or phase == "EXTRAS"
            or phase == "NEMESIS_LOOK" or phase == "NEMESIS_APPROACH"
            or phase == "WAIT_COMPLETE" then
        return true
    end
    -- Trigger on EGB/boss chest visibility
    return find_egb_chest() ~= nil
end

function task.Execute()
    -- Stuck recovery
    if check_stuck() then
        local pos = get_player_position()
        if pos then
            try_movement_spell(pos)
            pathfinder.force_move_raw(pos)
        end
        return
    end

    -- ---- IDLE / MAIN: find and open the EGB chest ----
    if phase == "IDLE" or phase == "MAIN" then
        local chest = find_egb_chest()
        if not chest then return end

        local dist = utils.distance_to(chest:get_position())
        if dist > 2.5 then
            pathfinder.request_move(chest:get_position())
            return
        end

        if not cooldown_ok() then return end

        interact_object(chest)
        last_interact_time = get_time_since_inject()
        tracker.chest_opened_time = os.time()
        last_chest_pos = chest:get_position()

        -- Remember which boss-zone we were in so the nemesis-phase guards stay
        -- coherent once we leave it via the portal.
        local boss = rotation.current()
        home_zone_prefix = boss and boss.zone_prefix or nil

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
            -- Main chest gone – sweep for any extra EGB chests that spawned alongside it.
            no_despawn_count = 0
            set_phase("EXTRAS")
            return
        end

        if phase_elapsed() < WAIT_GONE_SECS then return end

        -- Chest still here after timeout
        no_despawn_count = no_despawn_count + 1
        console.print(string.format("[Chest] Chest didn't despawn (%d/%d) – out of keys/husks?",
            no_despawn_count, OUT_OF_MATS_RETRIES))

        if no_despawn_count >= OUT_OF_MATS_RETRIES then
            no_despawn_count = 0
            local boss = rotation.current()

            -- Re-verify actual inventory before declaring out of keys/husks.
            -- Chest may have failed to despawn due to lag or a missed interact.
            -- BUT: external (orchestrator-injected) rotations are explicit
            -- one-shots — never extend the run from inventory, even if the
            -- chest is misbehaving. Otherwise the altar can re-fire.
            if boss and not rotation.external then
                rotation.resync_pools()
                local tier = boss.key_tier or boss.run_type or "lair"
                local has_stock = rotation.runs_for_tier(tier) > 0
                if has_stock then
                    console.print(string.format(
                        "[Chest] Chest still present but inventory has %s stock for %s — retrying open.",
                        tier, boss.label))
                    set_phase("MAIN")
                    return
                end
            end

            console.print("[Chest] Chest didn't despawn after retries — out of required key/husks for this boss, skipping.")
            rotation.advance()
            tracker.reset_run()
            set_phase("IDLE")
        else
            -- Try interacting again
            if cooldown_ok() then
                interact_object(chest)
                last_interact_time = get_time_since_inject()
            end
            set_phase("WAIT_GONE")
        end
        return
    end

    -- ---- EXTRAS: sweep for additional EGB chests that spawned alongside main ----
    if phase == "EXTRAS" then
        if phase_elapsed() >= EXTRAS_PHASE_TIMEOUT then
            console.print(string.format("[Chest] EXTRAS timeout (%ds) — moving on (%d extras opened).",
                EXTRAS_PHASE_TIMEOUT, #extras_done_positions))
            extras_done_positions = {}
            set_phase("NEMESIS_LOOK")
            return
        end

        local chest = find_extra_egb_chest()
        if not chest then
            if #extras_done_positions > 0 then
                console.print(string.format("[Chest] EXTRAS done — opened %d extra chest(s).",
                    #extras_done_positions))
            end
            extras_done_positions = {}
            set_phase("NEMESIS_LOOK")
            return
        end

        local pos = chest:get_position()
        if utils.distance_to(pos) > 2.5 then
            pathfinder.request_move(pos)
            return
        end
        if not cooldown_ok() then return end

        interact_object(chest)
        last_interact_time = get_time_since_inject()
        table.insert(extras_done_positions, pos)
        console.print(string.format("[Chest] Opened extra EGB chest #%d.",
            #extras_done_positions))
        return
    end

    -- ---- NEMESIS_LOOK: brief scan for the random Warplans_Portal_NemesisPortal ----
    if phase == "NEMESIS_LOOK" then
        local portal = find_nemesis_portal()
        if portal then
            nemesis_portal_pos = portal:get_position()
            nemesis_interact_t = 0
            console.print(string.format(
                "[Chest] Nemesis portal detected — approaching (dist=%.1f).",
                utils.distance_to(nemesis_portal_pos)))
            set_phase("NEMESIS_APPROACH")
            return
        end
        if phase_elapsed() >= NEMESIS_LOOK_SECS then
            set_phase("WAIT_COMPLETE")
        end
        return
    end

    -- ---- NEMESIS_APPROACH: walk to portal, interact, hand off immediately ----
    --
    -- Handoff is fired on the interact_object call rather than on zone change,
    -- because the loading window between interact and "zone == Warplans_Boss_NemesisLair"
    -- lasts long enough for navigate_to_boss to slip in and teleport us to the
    -- next boss. By setting tracker.nemesis_entered as soon as we click the
    -- portal, nemesis_fight (priority #3) owns the slot throughout the load.
    -- nemesis_fight itself confirms the lair zone before starting the kill timer.
    if phase == "NEMESIS_APPROACH" then
        if phase_elapsed() >= NEMESIS_APPROACH_SECS then
            console.print(string.format(
                "[Chest] Nemesis approach timeout (%ds) — skipping bonus.",
                NEMESIS_APPROACH_SECS))
            nemesis_portal_pos = nil
            set_phase("WAIT_COMPLETE")
            return
        end

        local portal = find_nemesis_portal()
        local target_pos = portal and portal:get_position() or nemesis_portal_pos
        if not target_pos then
            console.print("[Chest] Nemesis portal lost — skipping bonus.")
            set_phase("WAIT_COMPLETE")
            return
        end

        if utils.distance_to(target_pos) > 2.5 then
            pathfinder.request_move(target_pos)
            return
        end

        local t = get_time_since_inject()
        if portal and (t - nemesis_interact_t) >= NEMESIS_INTERACT_CD then
            interact_object(portal)
            nemesis_interact_t = t
            console.print("[Chest] Interacting with Nemesis portal — handing off to nemesis_fight.")

            tracker.nemesis_entered     = true
            tracker.nemesis_resolved    = false
            tracker.nemesis_last_kill_t = 0
            nemesis_portal_pos = nil
            home_zone_prefix   = nil
            last_chest_pos     = nil
            set_phase("IDLE")
        end
        return
    end

    -- ---- WAIT_COMPLETE: brief pause to loot, then start next run ----
    if phase == "WAIT_COMPLETE" then
        if not settings.loot_pause_done(phase_start) then return end
        local boss = rotation.current()
        console.print(string.format("[Chest] Run complete — boss=%s  run_type=%s",
            tostring(boss and boss.id), tostring(boss and boss.run_type)))
        rotation.consume_run()
        tracker.reset_run()
        set_phase("IDLE")
        last_chest_pos = nil
        return
    end
end

return task
