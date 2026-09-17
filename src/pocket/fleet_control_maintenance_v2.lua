local CORE_PATH = "/fleet_control_core_legacy.lua"
local ERROR_LOG = "/data/fleet_control_patch_error.log"
local VERSION = "0.23.0-alpha.6.2.1"

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function writeLog(stage, err)
    pcall(function()
        ensureParent(ERROR_LOG)
        local f = fs.open(ERROR_LOG, "w")
        if not f then return end
        f.write(table.concat({
            "BASE Fleet Control maintenance compatibility",
            "version=" .. VERSION,
            "stage=" .. tostring(stage),
            "error=" .. tostring(err),
            "core=" .. CORE_PATH,
        }, "\n") .. "\n")
        f.close()
    end)
end

local function readText(path)
    local f = fs.open(path, "r")
    if not f then return nil, "open_failed" end
    local text = f.readAll()
    f.close()
    return text
end

local function replaceOnce(source, old, new, label)
    local first, last = source:find(old, 1, true)
    if not first then return nil, "patch_missing:" .. tostring(label) end
    if source:find(old, last + 1, true) then return nil, "patch_ambiguous:" .. tostring(label) end
    return source:sub(1, first - 1) .. new .. source:sub(last + 1)
end

local source, readErr = readText(CORE_PATH)
if not source then
    writeLog("read", readErr)
    error("Fleet Control legacy core unavailable: " .. tostring(readErr), 0)
end

local patches = {
    {
        label = "version",
        old = 'local VERSION = "0.23.0-alpha.4.2"',
        new = 'local VERSION = "0.23.0-alpha.6.2.1"',
    },
    {
        label = "stale_update_gate",
        old = '    if not u.online then message="Selected unit offline"; return end',
        new = table.concat({
            '    -- Status freshness is a movement/job safety signal, not authentication.',
            '    -- Maintenance update may probe a known unit ID even when its cache entry',
            '    -- is stale; delivery is determined by signed ACK/timeout instead.',
            '    if not u.online and name~="update" then message="Selected unit offline"; return end',
        }, "\n"),
    },
}

for _, patch in ipairs(patches) do
    local patched, patchErr = replaceOnce(source, patch.old, patch.new, patch.label)
    if not patched then
        writeLog("patch", patchErr)
        error("Fleet Control compatibility patch failed: " .. tostring(patchErr), 0)
    end
    source = patched
end

local loader, loadErr = load(source, "@" .. CORE_PATH, "t", _ENV)
if not loader then
    writeLog("load", loadErr)
    error("Fleet Control patched core cannot load: " .. tostring(loadErr), 0)
end

local ok, runErr = pcall(loader)
if not ok then
    writeLog("run", runErr)
    error(runErr, 0)
end
