-- ============================================================
--  Reaper - core/settings.lua
-- ============================================================

local gui      = require "gui"
local enums    = require "data.enums"

local settings = {
    enabled       = false,
    use_alfred    = true,
    use_batmobile = false,

    -- Resolved from gui.town selection in update_settings(). Defaults to
    -- gui.town_data[0] (Temis) so first-frame reads are valid before the GUI
    -- pulse runs. Tasks read these instead of hardcoding Cerrigar so the
    -- selected home town is honoured everywhere.
    town_zone     = gui.town_data[0].zone_name,
    town_waypoint = gui.town_data[0].waypoint_sno,

    -- Boss rotation:
    --   boss_rotation_mode  = "manual" | "roundrobin" | "random"
    --   boss_target         = boss_id used when rotation_mode == "manual"
    --   boss_enabled        = per-boss toggles used by roundrobin / random
    -- Defaults to roundrobin so a fresh install with multiple ticked bosses
    -- cycles through them. Boss list defaults to all-off so nothing farms
    -- until the user explicitly opts in.
    boss_rotation_mode = "roundrobin",
    boss_target        = "duriel",
    boss_enabled       = {},

    dungeon_reset_enabled  = false,
    dungeon_reset_interval = 10,

    belial_chest_enabled = false,
    belial_chest = {
        selection_mode = "manual",
        target_boss    = "duriel",
        pool           = {},
        party_delay    = 0,
    },

    _belial_current_target = nil,
}

-- Initialise boss_enabled with every defined boss so callers can iterate
-- safely on the first frame even before the GUI pulse runs.
for _, bd in ipairs(enums.boss_zones) do
    settings.boss_enabled[bd.id] = false
end

function settings:update_settings()
    settings.enabled       = gui.elements.main_toggle:get()
    settings.use_alfred    = gui.elements.use_alfred:get()
    settings.use_batmobile = gui.elements.use_batmobile:get()

    local town_idx        = gui.elements.town:get()
    local town_data       = gui.town_data[town_idx] or gui.town_data[0]
    settings.town_zone    = town_data.zone_name
    settings.town_waypoint = town_data.waypoint_sno

    local rotation_modes = { "manual", "roundrobin", "random" }
    settings.boss_rotation_mode =
        rotation_modes[gui.elements.boss_rotation_mode:get() + 1] or "roundrobin"

    local boss_ids = {}
    for _, bd in ipairs(enums.boss_zones) do
        boss_ids[#boss_ids + 1] = bd.id
    end
    settings.boss_target = boss_ids[gui.elements.boss_target:get() + 1] or "duriel"

    for _, bd in ipairs(enums.boss_zones) do
        local cb = gui.elements.boss_enabled[bd.id]
        settings.boss_enabled[bd.id] = cb and cb:get() or false
    end

    settings.dungeon_reset_enabled  = gui.elements.dungeon_reset_enabled:get()
    settings.dungeon_reset_interval = gui.elements.dungeon_reset_interval:get()

    settings.belial_chest_enabled = gui.elements.belial_chest_enabled:get()

    local modes = { "manual", "roundrobin", "random" }
    settings.belial_chest.selection_mode = modes[gui.elements.belial_sel_mode:get() + 1] or "manual"

    local chest_ids = {}
    for _, bd in ipairs(enums.belial_chest_bosses) do
        chest_ids[#chest_ids + 1] = bd.id
    end
    settings.belial_chest.target_boss = chest_ids[gui.elements.belial_target_boss:get() + 1] or "duriel"

    local pool = {}
    for _, bd in ipairs(enums.belial_chest_bosses) do
        if gui.elements.belial_pool[bd.id] and gui.elements.belial_pool[bd.id]:get() then
            pool[#pool + 1] = bd.id
        end
    end
    settings.belial_chest.pool        = pool
    settings.belial_chest.party_delay = gui.elements.belial_party_delay:get()
end

return settings
