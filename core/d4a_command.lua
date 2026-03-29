-- ============================================================
--  Reaper - core/d4a_command.lua
--
--  Writes command.txt into the script's own directory so
--  D4 Assistant picks it up, executes the command, and
--  deletes the file.
--
--  D4 Assistant commands used by Reaper:
--    TELEPORT_Duriel / Andariel / Varshan / Grigoire /
--    TELEPORT_LordZir / BeastInTheIce / Belial
--    START_NMD_SKIP_SIGIL  — clicks dungeon on map after sigil activation
-- ============================================================

local d4a = {}

local function get_script_root()
    local root = string.gmatch(package.path, '.*?\\?')()
    return root:gsub('?', '')
end

local COMMAND_FILE = get_script_root() .. 'command.txt'

local BOSS_COMMANDS = {
    duriel   = "TELEPORT_Duriel",
    andariel = "TELEPORT_Andariel",
    varshan  = "TELEPORT_Varshan",
    grigoire = "TELEPORT_Grigoire",
    zir      = "TELEPORT_LordZir",
    beast    = "TELEPORT_BeastInTheIce",
    belial   = "TELEPORT_Belial",
}

local function write_command(cmd)
    local ok, err = pcall(function()
        local f = assert(io.open(COMMAND_FILE, 'w'))
        f:write(cmd)
        f:close()
    end)
    if not ok then
        console.print("[Reaper] D4A: Failed to write command.txt: " .. tostring(err))
        console.print("[Reaper] D4A: Path was: " .. COMMAND_FILE)
        return false
    end
    console.print("[Reaper] D4A: Wrote '" .. cmd .. "' → " .. COMMAND_FILE)
    return true
end

-- Write teleport command for a boss run
function d4a.send_teleport(boss_id)
    local cmd = BOSS_COMMANDS[boss_id]
    if not cmd then
        console.print("[Reaper] D4A: No command mapped for boss id: " .. tostring(boss_id))
        return false
    end
    return write_command(cmd)
end

-- Tell D4A to click the dungeon on the map after sigil activation
function d4a.send_start_nmd_skip_sigil()
    return write_command("START_NMD_SKIP_SIGIL")
end

-- Returns true when D4 Assistant has consumed (deleted) the file
function d4a.command_consumed()
    local f = io.open(COMMAND_FILE, 'r')
    if f then f:close(); return false end
    return true
end

return d4a
