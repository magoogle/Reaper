-- ============================================================
--  Reaper - core/map_nav.lua
--
--  Flow:
--    1. If not in anchor zone → teleport_to_waypoint(anchor)
--    2. Wait to confirm arrival in correct zone
--    3. Walk to Waypoint_Temp stone and interact_object it
--    4. Wait 1.5s for map UI to open
--    5. Click boss icon
--    6. Wait 0.5s
--    7. Click Accept (888, 640)
--    8. Wait for boss zone to load
--    If zone never arrives → retry from step 1
-- ============================================================

local map_nav = {}

-- -------------------------------------------------------
-- Waypoint IDs (confirmed)
-- -------------------------------------------------------
local NEVESK_WP    = 0x6D945
local ZARBINZET_WP = 0xA46E5

-- Confirmed zone names on arrival
local NEVESK_ZONE    = "Frac_Taiga_S"
local ZARBINZET_ZONE = "Hawe_Zarbinzet"

local TWO_CLICK = { zir = true }

-- -------------------------------------------------------
-- Boss → anchor
-- -------------------------------------------------------
local BOSS_ANCHOR = {
    grigoire = "nevesk",
    beast    = "nevesk",
    zir      = "nevesk",
    varshan  = "nevesk",
    belial   = "nevesk",
    andariel = "nevesk",
    duriel   = "nevesk",
    butcher  = "nevesk",
    urivar   = "zarbinzet",
    harbinger= "zarbinzet",
}

local gui = require "gui"

-- -------------------------------------------------------
-- Click helpers — read live pixel values from GUI sliders
-- -------------------------------------------------------
local function click_boss(boss_id, step2)
    local x, y
    if step2 then
        x, y = gui.get_zir2_icon()
    else
        x, y = gui.get_boss_icon(boss_id)
    end
    if not x then
        console.print("[MapNav] No icon coords for: " .. tostring(boss_id))
        return
    end
    console.print(string.format("[MapNav] click boss %s  px=(%d,%d)", boss_id, x, y))
    utility.send_mouse_click(x, y)
end

local function click_accept()
    local x, y = gui.get_accept()
    console.print(string.format("[MapNav] click Accept  px=(%d,%d)", x, y))
    utility.send_mouse_click(x, y)
end

-- -------------------------------------------------------
-- Helpers
-- -------------------------------------------------------
local function get_anchor_wp(anchor)
    return anchor == "zarbinzet" and ZARBINZET_WP or NEVESK_WP
end

local function get_anchor_zone(anchor)
    return anchor == "zarbinzet" and ZARBINZET_ZONE or NEVESK_ZONE
end

local function current_zone()
    return get_current_world():get_current_zone_name()
end

local function in_anchor_zone(anchor)
    return current_zone() == get_anchor_zone(anchor)
end

local function find_waypoint_stone()
    local lp = get_local_player()
    if not lp then return nil end
    local pp = lp:get_position()
    local best, best_dist = nil, 20.0
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local n = actor:get_skin_name()
        if type(n) == "string" and n:find("^Waypoint") then
            local ok, inter = pcall(function() return actor:is_interactable() end)
            if ok and inter then
                local d = pp:dist_to(actor:get_position())
                if d < best_dist then best = actor; best_dist = d end
            end
        end
    end
    return best
end

-- -------------------------------------------------------
-- State machine
-- -------------------------------------------------------
local STATE = {
    IDLE        = "IDLE",
    WAIT_ANCHOR = "WAIT_ANCHOR",  -- waiting to land in nevesk/zarbinzet
    WALK_TO_WP  = "WALK_TO_WP",  -- walking to waypoint stone
    INTERACT_WP = "INTERACT_WP", -- interacting with stone (retried via API)
    WAIT_MAP    = "WAIT_MAP",    -- waiting for map UI to open
    CLICK_BOSS  = "CLICK_BOSS",  -- single click on boss icon
    CLICK_BOSS2 = "CLICK_BOSS2", -- Zir only: wait then single click on portal
    WAIT_ACCEPT = "WAIT_ACCEPT", -- wait for accept dialog, then single click
    WAIT_ZONE   = "WAIT_ZONE",   -- waiting to land in boss zone (no actions)
    DONE        = "DONE",
}

local s = {
    state          = STATE.IDLE,
    t              = -999,  -- far in the past so no stale timeouts on first check
    boss_id        = nil,
    anchor         = nil,
    zone_prefix    = nil,   -- boss zone pattern for arrival detection
    is_sigil       = false, -- sigil runs use different zone names
    attempts       = 0,
    arrived_logged = false,
    wp_tries       = 0,     -- interact attempts within INTERACT_WP
    wp_last_try    = -999,  -- time of last interact attempt
}
local MAX_ATTEMPTS = 3
local T_TELEPORT   = 20.0  -- max wait for zone after teleport
local T_MAP_OPEN   = 2.5   -- wait after waypoint interact before clicking boss icon
local T_PRE_ACCEPT = 1.5   -- wait after boss click before clicking accept
local T_ZONE       = 15.0  -- wait for boss zone to load after accept

local function now()      return get_time_since_inject() end

local function in_boss_zone()
    local zone = get_current_world():get_current_zone_name()
    if s.is_sigil then
        return zone:find("BloodyLair") ~= nil
            or zone:find("S12_Boss")   ~= nil
            or zone:find("Boss_WT")    ~= nil
            or zone:find("Boss_Kehj")  ~= nil
    end
    if not s.zone_prefix or s.zone_prefix == "" then return false end
    return zone:match(s.zone_prefix) ~= nil
end
local function set_state(st)
    s.state          = st
    s.t              = now()
    s.arrived_logged = false
    if st == STATE.INTERACT_WP then
        s.wp_tries    = 0
        s.wp_last_try = -999
    end
end
local function elapsed()  return now() - s.t end

-- -------------------------------------------------------
-- Public API
-- -------------------------------------------------------
function map_nav.start(boss_id, zone_prefix, is_sigil)
    s.boss_id     = boss_id
    s.anchor      = BOSS_ANCHOR[boss_id] or "nevesk"
    s.zone_prefix = zone_prefix or ""
    s.is_sigil    = is_sigil or false
    s.attempts    = 0
    console.print(string.format("[MapNav] Starting nav to %s via %s", boss_id, s.anchor))

    if in_anchor_zone(s.anchor) then
        console.print("[MapNav] Already in anchor zone.")
        set_state(STATE.WALK_TO_WP)
    else
        teleport_to_waypoint(get_anchor_wp(s.anchor))
        set_state(STATE.WAIT_ANCHOR)
    end
end

function map_nav.is_done()   return s.state == STATE.DONE end
function map_nav.is_active() return s.state ~= STATE.IDLE and s.state ~= STATE.DONE end
function map_nav.reset()     s.state = STATE.IDLE; s.boss_id = nil end
function map_nav.get_state() return s.state end

local function retry()
    s.attempts = s.attempts + 1
    console.print(string.format("[MapNav] Retry %d/%d", s.attempts, MAX_ATTEMPTS))
    if s.attempts >= MAX_ATTEMPTS then
        console.print("[MapNav] Giving up.")
        map_nav.reset()
        return
    end
    -- Go back to anchor teleport
    teleport_to_waypoint(get_anchor_wp(s.anchor))
    set_state(STATE.WAIT_ANCHOR)
end

function map_nav.update()
    if s.state == STATE.IDLE or s.state == STATE.DONE then return end

    -- ---- WAIT_ANCHOR ----
    if s.state == STATE.WAIT_ANCHOR then
        if in_anchor_zone(s.anchor) then
            if not s.arrived_logged then
                console.print("[MapNav] Arrived at " .. s.anchor .. " (" .. current_zone() .. ")")
                s.arrived_logged = true
            end
            -- Wait 2s for actors to load, then walk to stone
            if elapsed() >= 2.0 then
                set_state(STATE.WALK_TO_WP)
            end
            return
        end
        if elapsed() >= T_TELEPORT then
            s.attempts = s.attempts + 1
            if s.attempts >= MAX_ATTEMPTS then map_nav.reset(); return end
            teleport_to_waypoint(get_anchor_wp(s.anchor))
            set_state(STATE.WAIT_ANCHOR)
        end
        return
    end

    -- ---- WALK_TO_WP ----
    if s.state == STATE.WALK_TO_WP then
        local stone = find_waypoint_stone()
        if not stone then
            if elapsed() >= 10.0 then
                console.print("[MapNav] Cannot find waypoint stone.")
                retry(); return
            end
            return
        end
        local lp = get_local_player()
        local dist = lp and lp:get_position():dist_to(stone:get_position()) or 999
        if dist <= 3.0 then
            set_state(STATE.INTERACT_WP)
        else
            pathfinder.request_move(stone:get_position())
        end
        return
    end

    -- ---- INTERACT_WP ----
    -- Fire up to 3 interact attempts (0.8s apart) then hand off to WAIT_MAP.
    -- Only the first attempt is logged to keep console clean.
    -- We have no feedback on whether the map opened — WAIT_MAP's timer is
    -- the only signal we have.
    if s.state == STATE.INTERACT_WP then
        local stone = find_waypoint_stone()
        if not stone then
            set_state(STATE.WALK_TO_WP)
            return
        end
        local lp   = get_local_player()
        local dist = lp and lp:get_position():dist_to(stone:get_position()) or 999
        if dist > 3.0 then
            pathfinder.request_move(stone:get_position())
            return
        end
        local n = now()
        if s.wp_tries < 3 and (n - s.wp_last_try) >= 0.8 then
            s.wp_tries    = s.wp_tries + 1
            s.wp_last_try = n
            loot_manager.interact_with_object(stone)
            if s.wp_tries == 1 then
                console.print("[MapNav] Interacting with waypoint stone.")
            end
        end
        if s.wp_tries >= 3 and (now() - s.wp_last_try) >= 0.8 then
            set_state(STATE.WAIT_MAP)
        end
        return
    end

    -- ---- WAIT_MAP ----
    if s.state == STATE.WAIT_MAP then
        if elapsed() >= T_MAP_OPEN then
            console.print("[MapNav] Map should be open - clicking boss.")
            set_state(STATE.CLICK_BOSS)
        end
        return
    end

    -- ---- CLICK_BOSS ----
    if s.state == STATE.CLICK_BOSS then
        click_boss(s.boss_id, false)
        if TWO_CLICK[s.boss_id] then
            set_state(STATE.CLICK_BOSS2)
        else
            set_state(STATE.WAIT_ACCEPT)
        end
        return
    end

    -- ---- CLICK_BOSS2 (Zir only) ----
    if s.state == STATE.CLICK_BOSS2 then
        if elapsed() >= T_PRE_ACCEPT then
            click_boss(s.boss_id, true)
            set_state(STATE.WAIT_ACCEPT)
        end
        return
    end

    -- ---- WAIT_ACCEPT ----
    if s.state == STATE.WAIT_ACCEPT then
        if elapsed() >= T_PRE_ACCEPT then
            click_accept()
            console.print(string.format(
                "[MapNav] Waiting up to %.0fs for boss zone — no further actions.", T_ZONE))
            set_state(STATE.WAIT_ZONE)
        end
        return
    end

    -- ---- WAIT_ZONE ----
    -- Zone is checked every tick here so arrival is detected even if
    -- navigate_to_boss.shouldExecute() returns false (e.g. altar already
    -- visible the moment we land).  On success → DONE so navigate_to_boss
    -- can pick it up.  On timeout → full restart from anchor zone.
    if s.state == STATE.WAIT_ZONE then
        if in_boss_zone() then
            console.print("[MapNav] Boss zone confirmed: " .. get_current_world():get_current_zone_name())
            set_state(STATE.DONE)
            return
        end
        if elapsed() >= T_ZONE then
            console.print("[MapNav] Boss zone timeout – returning to anchor for full retry.")
            retry()
        end
        return
    end
end

return map_nav
