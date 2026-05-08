-- ============================================================
--  Reaper - core/materials.lua
--
--  Inventory scanner for the Lair Key boss-summoning system.
--
--    Lair Key (Initiate / standard / Greater)
--                      → summons any non-Belial boss (1 per run, pooled)
--    Betrayer's Husk   → Belial only (HUSK_COST_BELIAL per run)
--
--  All three Lair Key tiers feed a single shared pool. To disable a tier
--  (e.g. save Greaters for manual runs) set its SNO constant to 0.
--
--  SNO IDs cross-referenced against LooteerV3/data/items.lua:
--    [2556388] Lair Key
--    [2558178] Initiate Lair Key
--    [2558255] Greater Lair Key
--    [2194099] Betrayer's Husk
-- ============================================================

local materials = {}

-- -------------------------------------------------------
-- SNO IDs (set any tier to 0 to exclude it from the pool)
-- -------------------------------------------------------
local INITIATE_LAIR_KEY_SNO = 2558178   -- Initiate Lair Key
local LAIR_KEY_SNO          = 2556388   -- Lair Key
local GREATER_LAIR_KEY_SNO  = 2558255   -- Greater Lair Key
local HUSK_SNO              = 2194099   -- Betrayer's Husk (Belial)

local HUSK_COST_BELIAL      = 2         -- husks consumed per Belial run

-- Expose for other modules that need to know the cost
materials.HUSK_COST_BELIAL      = HUSK_COST_BELIAL
materials.INITIATE_LAIR_KEY_SNO = INITIATE_LAIR_KEY_SNO
materials.LAIR_KEY_SNO          = LAIR_KEY_SNO
materials.GREATER_LAIR_KEY_SNO  = GREATER_LAIR_KEY_SNO
materials.HUSK_SNO              = HUSK_SNO

-- -------------------------------------------------------
-- Helpers
-- -------------------------------------------------------
local function safe_count(item)
    local ok, n = pcall(function() return item:get_stack_count() end)
    if not ok or not n or n <= 0 then return 1 end
    return n
end

local function get_dungeon_keys()
    local lp = get_local_player()
    if not lp then return {} end
    local ok, keys = pcall(function() return lp:get_dungeon_key_items() end)
    if not ok or type(keys) ~= "table" then return {} end
    return keys
end

local function get_consumables()
    local lp = get_local_player()
    if not lp then return {} end
    local ok, items = pcall(function() return lp:get_consumable_items() end)
    if not ok or type(items) ~= "table" then return {} end
    return items
end

-- -------------------------------------------------------
-- Public: scan all relevant inventory
-- Returns { initiate_lair_keys, lair_keys, greater_lair_keys, husks }
-- Lair Keys can live in either dungeon_keys or consumables depending on
-- the patch, so both inventories are searched.
-- -------------------------------------------------------
function materials.scan_keys()
    local result = {
        initiate_lair_keys = 0,
        lair_keys          = 0,
        greater_lair_keys  = 0,
        husks              = 0,
    }

    local function tally(items)
        for _, item in ipairs(items) do
            local ok, sno = pcall(function() return item:get_sno_id() end)
            if ok and sno then
                if sno == INITIATE_LAIR_KEY_SNO and INITIATE_LAIR_KEY_SNO ~= 0 then
                    result.initiate_lair_keys = result.initiate_lair_keys + safe_count(item)
                elseif sno == LAIR_KEY_SNO and LAIR_KEY_SNO ~= 0 then
                    result.lair_keys = result.lair_keys + safe_count(item)
                elseif sno == GREATER_LAIR_KEY_SNO and GREATER_LAIR_KEY_SNO ~= 0 then
                    result.greater_lair_keys = result.greater_lair_keys + safe_count(item)
                elseif sno == HUSK_SNO then
                    result.husks = result.husks + safe_count(item)
                end
            end
        end
    end

    tally(get_dungeon_keys())
    tally(get_consumables())
    return result
end

-- Total non-Belial runs available from the shared key pool.
function materials.lair_runs_available()
    local k = materials.scan_keys()
    return k.initiate_lair_keys + k.lair_keys + k.greater_lair_keys
end

-- Number of Belial runs available from husks.
function materials.belial_runs_available()
    local k = materials.scan_keys()
    return math.floor(k.husks / HUSK_COST_BELIAL)
end

-- True if any selected boss can run with the current inventory.
-- Looks up each selected boss's required key tier in data/enums.lua and
-- checks the matching pool — does NOT pool different tiers together.
function materials.has_inventory_stock(settings)
    if not settings or not settings.boss_enabled then return false end
    local enums = require "data.enums"
    local k = materials.scan_keys()
    for _, bd in ipairs(enums.boss_zones) do
        if settings.boss_enabled[bd.id] then
            local tier = bd.key_tier or "lair"
            if tier == "husk" and k.husks >= HUSK_COST_BELIAL then return true end
            if tier == "initiate" and k.initiate_lair_keys > 0 then return true end
            if tier == "lair"     and k.lair_keys          > 0 then return true end
            if tier == "greater"  and k.greater_lair_keys  > 0 then return true end
        end
    end
    return false
end

-- -------------------------------------------------------
-- Debug dumps
-- -------------------------------------------------------
local function dump(label, items)
    console.print(string.format("[Reaper] %s (%d items):", label, #items))
    for _, item in ipairs(items) do
        local ok_sno, sno   = pcall(function() return item:get_sno_id() end)
        local ok_name, name = pcall(function() return item:get_name() end)
        local ok_disp, disp = pcall(function() return item:get_display_name() end)
        local ok_cnt, cnt   = pcall(function() return item:get_stack_count() end)
        local sno_str  = ok_sno  and string.format("sno=%d (0x%X)", sno, sno) or "sno=?"
        local name_str = ok_name and name or (ok_disp and disp or "unknown")
        local cnt_str  = ok_cnt  and tostring(cnt > 0 and cnt or 1)            or "?"
        console.print(string.format("  [%s]  x%-4s  %s", sno_str, cnt_str, name_str))
    end
end

function materials.print_all_keys()
    dump("dungeon_key_items", get_dungeon_keys())
    dump("consumable_items",  get_consumables())
end

function materials.print_summary()
    local k = materials.scan_keys()
    console.print(string.format(
        "[Reaper] Inventory: initiate=%d  lair=%d  greater=%d  husks=%d  (Belial runs=%d, pooled boss runs=%d)",
        k.initiate_lair_keys, k.lair_keys, k.greater_lair_keys, k.husks,
        materials.belial_runs_available(), materials.lair_runs_available()))
end

return materials
