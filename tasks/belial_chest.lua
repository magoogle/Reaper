-- ============================================================
--  Reaper - tasks/belial_chest.lua
--
--  Fires AFTER open_chest.lua has interacted with the physical
--  Belial chest (tracker.belial_chest_interacted = true).
--  Waits 1.5s for the "Choose Reward" dialog to fully render,
--  then clicks the appropriate buttons.
--
--  Pixel coords measured at 1920×1080, scaled to any res.
--
--  Andariel:   wait → Open
--  Varshan:    wait → Modify → wait → Scroll → wait → Varshan → wait → Open
--  Others:     wait → Modify → wait → Boss   → wait → Open
-- ============================================================

local settings = require "core.settings"
local tracker  = require "core.tracker"

-- -------------------------------------------------------
-- Screen-relative click helper
-- -------------------------------------------------------
local function click(rx, ry)
    local x = math.floor(get_screen_width()  * rx)
    local y = math.floor(get_screen_height() * ry)
    console.print(string.format("[BelialChest] click(%d, %d)", x, y))
    utility.send_mouse_click(x, y)
end

-- Coords as ratios (measured px / reference res)
local C = {
    open     = function() click(349/1920, 956/1080) end,
    modify   = function() click(349/1920, 816/1080) end,
    scroll   = function() click(629/1920, 858/1080) end,
    duriel   = function() click(349/1920, 397/1080) end,
    grigoire = function() click(349/1920, 495/1080) end,
    harbinger= function() click(349/1920, 585/1080) end,
    zir      = function() click(349/1920, 683/1080) end,
    beast    = function() click(349/1920, 773/1080) end,
    urivar   = function() click(349/1920, 875/1080) end,
    varshan  = function() click(349/1920, 845/1080) end,
}

-- -------------------------------------------------------
-- Zone check
-- -------------------------------------------------------
local function in_belial_zone()
    return get_current_world():get_current_zone_name():match("Boss_Kehj_Belial") ~= nil
end

-- -------------------------------------------------------
-- Boss selection
-- -------------------------------------------------------
local rr_index = 0

local function pick_target()
    local cfg = settings.belial_chest
    if not cfg then return "duriel" end
    local mode = cfg.selection_mode or "manual"
    local pool = cfg.pool or {}
    if mode == "roundrobin" and #pool > 0 then
        rr_index = (rr_index % #pool) + 1
        return pool[rr_index]
    elseif mode == "random" and #pool > 0 then
        return pool[math.random(#pool)]
    else
        return cfg.target_boss or "duriel"
    end
end

-- -------------------------------------------------------
-- State machine
-- -------------------------------------------------------
local STATE = {
    IDLE    = "IDLE",
    WAIT    = "WAIT",     -- waiting for dialog to render after chest interact
    MODIFY  = "MODIFY",
    SCROLL  = "SCROLL",
    SELECT  = "SELECT",
    OPEN    = "OPEN",
    DONE    = "DONE",
}

local s = { state = STATE.IDLE, t = 0, target = nil }

local function set_state(st)
    s.state = st
    s.t     = get_time_since_inject()
end

local function elapsed()
    return get_time_since_inject() - s.t
end

-- -------------------------------------------------------
local task = { name = "Belial Chest Looter" }

function task.shouldExecute()
    if not settings.belial_chest_enabled then return false end
    if not in_belial_zone() then
        if s.state ~= STATE.IDLE then set_state(STATE.IDLE) end
        return false
    end
    -- Mid-sequence: keep running until DONE
    if s.state ~= STATE.IDLE and s.state ~= STATE.DONE then return true end
    -- Trigger: open_chest interacted with the physical chest this run
    return tracker.belial_chest_interacted == true
end

function task.Execute()
    local cfg = settings.belial_chest or {}

    if s.state == STATE.IDLE then
        s.target = pick_target()
        console.print("[BelialChest] Starting sequence. Target: " .. s.target)
        -- Clear the trigger so we don't re-fire on the same interaction
        tracker.belial_chest_interacted = false
        set_state(STATE.WAIT)
        return
    end

    -- Wait 1.5s after chest interact for dialog to fully render
    if s.state == STATE.WAIT then
        if elapsed() >= 1.5 then
            if s.target == "andariel" then
                set_state(STATE.OPEN)
            else
                set_state(STATE.MODIFY)
            end
        end
        return
    end

    -- Click Modify Reward, then wait
    if s.state == STATE.MODIFY then
        C.modify()
        if s.target == "varshan" then
            set_state(STATE.SCROLL)
        else
            set_state(STATE.SELECT)
        end
        return
    end

    -- Click Scroll (Varshan only), then wait
    if s.state == STATE.SCROLL then
        if elapsed() >= 0.3 then
            C.scroll()
            set_state(STATE.SELECT)
        end
        return
    end

    -- Click boss button, then wait
    if s.state == STATE.SELECT then
        if elapsed() >= 0.3 then
            local fn = C[s.target]
            if fn then
                fn()
            else
                console.print("[BelialChest] No button for " .. s.target)
            end
            set_state(STATE.OPEN)
        end
        return
    end

    -- Click Open
    if s.state == STATE.OPEN then
        local delay = (cfg.party_delay or 0) / 1000.0
        if elapsed() >= (0.3 + delay) then
            C.open()
            tracker.chest_opened_time = os.time()
            set_state(STATE.DONE)
        end
        return
    end

    if s.state == STATE.DONE then
        set_state(STATE.IDLE)
        return
    end
end

return task
