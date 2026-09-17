local CORE_PATH = "/fleet_box_core_legacy.lua"
local ERROR_LOG = "/data/fleet_box_patch_error.log"
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
            "BASE Fleet Box discovery compatibility",
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
    error("Fleet Box legacy core unavailable: " .. tostring(readErr), 0)
end

local patches = {
    {
        label = "version",
        old = 'local VERSION="0.23.0-alpha.6.2"',
        new = 'local VERSION="0.23.0-alpha.6.2.1"',
    },
    {
        label = "initial_discovery_window",
        old = 'collectDiscovery(0.8)',
        new = 'collectDiscovery(2.5)',
    },
}

for _, patch in ipairs(patches) do
    local patched, patchErr = replaceOnce(source, patch.old, patch.new, patch.label)
    if not patched then
        writeLog("patch", patchErr)
        error("Fleet Box compatibility patch failed: " .. tostring(patchErr), 0)
    end
    source = patched
end

local loader, loadErr = load(source, "@" .. CORE_PATH, "t", _ENV)
if not loader then
    writeLog("load", loadErr)
    error("Fleet Box patched core cannot load: " .. tostring(loadErr), 0)
end

local ok, runErr = pcall(loader)
if not ok then
    writeLog("run", runErr)
    error(runErr, 0)
end
