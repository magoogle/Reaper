-- ============================================================
--  Reaper - gui.lua
-- ============================================================

local gui          = {}
local plugin_label = "Reaper"
local enums        = require "data.enums"

local function cb(default, key)
    return checkbox:new(default, get_hash(plugin_label .. "_" .. key))
end
local function si(min, max, default, key)
    return slider_int:new(min, max, default, get_hash(plugin_label .. "_" .. key))
end
local function sf(min, max, default, key)
    return slider_float:new(min, max, default, get_hash(plugin_label .. "_" .. key))
end
local function cbo(default_idx, key)
    return combo_box:new(default_idx, get_hash(plugin_label .. "_" .. key))
end

local TREE_MAIN   = 0
local TREE_RESET  = 1
local TREE_BELIAL = 2
local TREE_ALIGN  = 3
local TREE_MISC   = 4

local chest_boss_labels = {}
for _, bd in ipairs(enums.belial_chest_bosses) do
    chest_boss_labels[#chest_boss_labels + 1] = bd.label
end

-- Default boss icon positions (px at 1920x1080 → ratio)
-- Nevesk anchor bosses
local NEVESK_DEFAULTS = {
    grigoire  = { x=486,  y=316  },
    beast     = { x=1025, y=483  },
    varshan   = { x=1261, y=658  },
    belial    = { x=418,  y=713  },
    andariel  = { x=676,  y=748  },
    duriel    = { x=281,  y=1000 },
    butcher   = { x=174,  y=922  },
    zir       = { x=1246, y=470  },  -- step 1 (gateway)
    zir2      = { x=1472, y=251  },  -- step 2 (boss portal)
}
-- Zarbinzet anchor bosses
local ZARB_DEFAULTS = {
    urivar    = { x=781, y=653 },
    harbinger = { x=243, y=700 },
}
-- Accept button
local ACCEPT_DEFAULT = { x=888, y=640 }

gui.elements = {
    main_tree   = tree_node:new(TREE_MAIN),
    main_toggle = cb(false, "main_toggle"),

    reset_tree  = tree_node:new(TREE_RESET),
    belial_tree = tree_node:new(TREE_BELIAL),
    align_tree  = tree_node:new(TREE_ALIGN),
    misc_tree   = tree_node:new(TREE_MISC),

    dungeon_reset_enabled  = cb(false,      "dr_en"),
    dungeon_reset_interval = si(1, 200, 10, "dr_int"),

    use_d4a          = cb(true,  "use_d4a"),
    use_alfred       = cb(true,  "alfred"),
    show_alignment   = cb(false, "show_align"),

    -- Run type toggles
    run_materials    = cb(true,  "run_mats"),
    run_sigils       = cb(true,  "run_sigils"),

    belial_chest_enabled = cb(false, "bel_en"),
    belial_sel_mode      = cbo(0,    "bel_mode"),
    belial_target_boss   = cbo(0,    "bel_target"),
    belial_party_delay   = si(0, 5000, 0, "bel_delay"),
    belial_pool          = {},

    -- Boss icon alignment sliders (actual screen pixel coords)
    -- X max = 5120 to cover 4K ultrawide (5120x2160)
    -- accept button
    accept_x = si(0, 5120, ACCEPT_DEFAULT.x, "acc_x"),
    accept_y = si(0, 2160, ACCEPT_DEFAULT.y, "acc_y"),
    -- per-boss x/y
    boss_icon_x = {},
    boss_icon_y = {},
    -- Zir has a second click
    zir2_x = si(0, 5120, NEVESK_DEFAULTS.zir2.x, "zir2_x"),
    zir2_y = si(0, 2160, NEVESK_DEFAULTS.zir2.y, "zir2_y"),
}

-- Create sliders for every boss that has map icon coords
local ALL_ICON_DEFAULTS = {}
for id, d in pairs(NEVESK_DEFAULTS) do
    if id ~= "zir2" then ALL_ICON_DEFAULTS[id] = d end
end
for id, d in pairs(ZARB_DEFAULTS) do
    ALL_ICON_DEFAULTS[id] = d
end

for id, d in pairs(ALL_ICON_DEFAULTS) do
    gui.elements.boss_icon_x[id] = si(0, 5120, d.x, "icon_x_" .. id)
    gui.elements.boss_icon_y[id] = si(0, 2160, d.y, "icon_y_" .. id)
end

for _, bd in ipairs(enums.belial_chest_bosses) do
    gui.elements.belial_pool[bd.id] = cb(false, "bpool_" .. bd.id)
end

local SEL_MODES = { "Manual", "Round Robin", "Random" }

-- Boss subtrees for alignment section (one per boss + accept)
local align_boss_trees = {}
local align_tree_idx = 10
for id, _ in pairs(ALL_ICON_DEFAULTS) do
    align_boss_trees[id] = tree_node:new(align_tree_idx)
    align_tree_idx = align_tree_idx + 1
end
local zir2_tree   = tree_node:new(align_tree_idx);     align_tree_idx = align_tree_idx + 1
local accept_tree = tree_node:new(align_tree_idx)

-- Public accessor for map_nav to read live values (returns raw screen pixel coords)
function gui.get_boss_icon(boss_id)
    local ex = gui.elements.boss_icon_x[boss_id]
    local ey = gui.elements.boss_icon_y[boss_id]
    if ex and ey then
        return ex:get(), ey:get()
    end
    return nil, nil
end

function gui.get_zir2_icon()
    return gui.elements.zir2_x:get(),
           gui.elements.zir2_y:get()
end

function gui.get_accept()
    return gui.elements.accept_x:get(),
           gui.elements.accept_y:get()
end

-- -------------------------------------------------------
function gui.render()
    if not gui.elements.main_tree:push(plugin_label .. "  v1.0  by Magoogle") then return end

    gui.elements.main_toggle:render("Enable", "Start / stop the boss farmer")

    -- ---- Dungeon Reset ----
    if gui.elements.reset_tree:push("Dungeon Reset") then
        gui.elements.dungeon_reset_enabled:render("Enable", "Reset all dungeons every N runs")
        if gui.elements.dungeon_reset_enabled:get() then
            gui.elements.dungeon_reset_interval:render("Every N runs", "")
        end
        gui.elements.reset_tree:pop()
    end

    -- ---- Belial Chest ----
    if gui.elements.belial_tree:push("Belial Chest Automation") then
        gui.elements.belial_chest_enabled:render("Enable", "Auto-click Ritual of Lies chest after killing Belial")
        if gui.elements.belial_chest_enabled:get() then
            gui.elements.belial_sel_mode:render("Mode", SEL_MODES, "Manual / Round Robin / Random")
            local mode = gui.elements.belial_sel_mode:get()
            if mode == 0 then
                gui.elements.belial_target_boss:render("Target Boss", chest_boss_labels, "")
            else
                for _, bd in ipairs(enums.belial_chest_bosses) do
                    gui.elements.belial_pool[bd.id]:render(bd.label, "Include in pool")
                end
            end
            gui.elements.belial_party_delay:render("Party Delay (ms)", "Extra ms before clicking Open")
        end
        gui.elements.belial_tree:pop()
    end

    -- ---- Boss Icon Alignment ----
    if gui.elements.align_tree:push("Boss Icon Alignment") then
        gui.elements.show_alignment:render("Show crosshairs on screen",
            "Draws colored crosshairs at each boss icon position.\nOpen the map to see if clicks land correctly.")
        -- Accept button
        if accept_tree:push("Accept Button") then
            gui.elements.accept_x:render("X (px)", "Screen pixel X")
            gui.elements.accept_y:render("Y (px)", "Screen pixel Y")
            local ax = gui.elements.accept_x:get()
            local ay = gui.elements.accept_y:get()
            graphics.text_2d(string.format("Accept: (%d, %d)", ax, ay), vec2:new(0,0), 11, color_yellow(255))
            accept_tree:pop()
        end

        -- Per-boss sliders
        -- Group by anchor for clarity
        local nevesk_order  = {"grigoire","beast","varshan","belial","andariel","duriel","butcher","zir"}
        local zarb_order    = {"urivar","harbinger"}

        for _, id in ipairs(nevesk_order) do
            local tree = align_boss_trees[id]
            if tree and gui.elements.boss_icon_x[id] then
                local label = id:sub(1,1):upper() .. id:sub(2)
                if tree:push(label .. " (Nevesk)") then
                    gui.elements.boss_icon_x[id]:render("X (px)", "")
                    gui.elements.boss_icon_y[id]:render("Y (px)", "")
                    local bx = gui.elements.boss_icon_x[id]:get()
                    local by = gui.elements.boss_icon_y[id]:get()
                    graphics.text_2d(string.format("(%d, %d)", bx, by), vec2:new(0,0), 11, color_yellow(255))
                    tree:pop()
                end
            end
        end

        -- Zir step 2
        if zir2_tree:push("Zir – Step 2 (Boss Portal)") then
            gui.elements.zir2_x:render("X (px)", "")
            gui.elements.zir2_y:render("Y (px)", "")
            local bx = gui.elements.zir2_x:get()
            local by = gui.elements.zir2_y:get()
            graphics.text_2d(string.format("(%d, %d)", bx, by), vec2:new(0,0), 11, color_yellow(255))
            zir2_tree:pop()
        end

        for _, id in ipairs(zarb_order) do
            local tree = align_boss_trees[id]
            if tree and gui.elements.boss_icon_x[id] then
                local label = id:sub(1,1):upper() .. id:sub(2)
                if tree:push(label .. " (Zarbinzet)") then
                    gui.elements.boss_icon_x[id]:render("X (px)", "")
                    gui.elements.boss_icon_y[id]:render("Y (px)", "")
                    local bx = gui.elements.boss_icon_x[id]:get()
                    local by = gui.elements.boss_icon_y[id]:get()
                    graphics.text_2d(string.format("(%d, %d)", bx, by), vec2:new(0,0), 11, color_yellow(255))
                    tree:pop()
                end
            end
        end

        gui.elements.align_tree:pop()
    end

    -- ---- Settings ----
    if gui.elements.misc_tree:push("Settings") then
        gui.elements.use_d4a:render("Use D4Assistant for teleport",
            "Write command.txt to let D4Assistant handle boss teleports.\nDisable to use the built-in map-click navigation instead.")
        gui.elements.use_alfred:render("Use Alfred",
            "Hand off inventory/repair/restock tasks to Alfred.")

        gui.elements.run_materials:render("Run Material Runs",
            "Farm bosses using consumable summoning materials (Shards of Agony, Living Steel, etc.)")
        gui.elements.run_sigils:render("Run Lair Boss Sigils",
            "Farm bosses using Bloodied and Bloodsoaked Lair Boss Sigils from your dungeon key inventory.")

        gui.elements.misc_tree:pop()
    end

    gui.elements.main_tree:pop()
end

-- -------------------------------------------------------
-- Per-boss colors for overlay crosshairs
-- -------------------------------------------------------
local function draw_crosshair(x, y, col, label)
    local h = 14
    graphics.line(vec2:new(x-h, y), vec2:new(x+h, y), col, 2)
    graphics.line(vec2:new(x, y-h), vec2:new(x, y+h), col, 2)
    graphics.circle_2d(vec2:new(x, y), 5, col, 2)
    if label then
        graphics.text_2d(label, vec2:new(x+10, y-8), 11, col)
    end
end

function gui.render_overlay()
    if not gui.elements.show_alignment:get() then return end

    local BOSS_COLORS = {
        grigoire  = color_red(255),
        beast     = color_blue(255),
        varshan   = color_purple(255),
        belial    = color_orange(255),
        andariel  = color_green(255),
        duriel    = color_yellow(255),
        butcher   = color_white(255),
        zir       = color_cyan(255),
        urivar    = color_pink(255),
        harbinger = color_red(200),
    }

    local sw = get_screen_width()
    local sh = get_screen_height()

    -- Accept button — white
    local ax = gui.elements.accept_x:get()
    local ay = gui.elements.accept_y:get()
    draw_crosshair(ax, ay, color_white(255), "Accept")

    -- Per-boss crosshairs
    local all_ids = {
        "grigoire","beast","varshan","belial","andariel","duriel","butcher","zir",
        "urivar","harbinger"
    }
    for _, id in ipairs(all_ids) do
        local ex = gui.elements.boss_icon_x[id]
        local ey = gui.elements.boss_icon_y[id]
        if ex and ey then
            local col = BOSS_COLORS[id] or color_white(200)
            local label = id:sub(1,1):upper() .. id:sub(2)
            draw_crosshair(ex:get(), ey:get(), col, label)
        end
    end

    -- Zir step 2 — cyan dashed circle to distinguish
    local zx = gui.elements.zir2_x:get()
    local zy = gui.elements.zir2_y:get()
    draw_crosshair(zx, zy, color_cyan(180), "Zir2")
end

return gui
