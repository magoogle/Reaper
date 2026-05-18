-- ============================================================
--  Reaper - core/tracker.lua
-- ============================================================

local tracker = {
    -- timing
    start_time          = 0,
    finished_time       = 0,
    chest_opened_time   = nil,
    altar_activate_time = 0,   -- get_time_since_inject() when altar was activated

    -- per-run flags
    altar_activated         = false,
    boss_killed             = false,
    chest_opened            = false,
    belial_chest_interacted = false,  -- set when the physical Belial chest is interacted with
    just_revived            = false,  -- set by revive task, cleared by navigate_to_boss
    sigil_entry_t           = 0,      -- get_time_since_inject() when player entered sigil zone

    -- Nemesis portal side-encounter (post-main-chest random spawn).
    -- nemesis_entered  → set by open_chest after interacting with the portal and
    --                    detecting a zone change. Hands control to nemesis_fight.
    -- nemesis_resolved → set by nemesis_fight after the 30s-no-kill timer expires
    --                    and teleport home + consume_run have completed.
    nemesis_entered      = false,
    nemesis_resolved     = false,
    nemesis_last_kill_t  = 0,

    -- session stats
    total_kills        = 0,
    current_boss_kills = 0,
}

function tracker.reset_run()
    tracker.altar_activated         = false
    tracker.altar_activate_time     = 0
    tracker.boss_killed             = false
    tracker.chest_opened            = false
    tracker.belial_chest_interacted = false
    tracker.just_revived            = false
    tracker.sigil_entry_t           = 0
    tracker.start_time              = 0
    tracker.finished_time           = 0
    tracker.chest_opened_time       = nil
    tracker.nemesis_entered         = false
    tracker.nemesis_resolved        = false
    tracker.nemesis_last_kill_t     = 0
end

function tracker.check_time(key, delay)
    local t = get_time_since_inject()
    if not tracker[key] then tracker[key] = t end
    return (t - tracker[key]) >= delay
end

function tracker.clear_key(key)
    tracker[key] = nil
end

return tracker
