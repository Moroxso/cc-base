local IMPL_PATH = "/lib/pocket/pointer_host_core_nav.lua"
local ERROR_LOG = "/data/pointer_ui_error.log"
local COMPAT_VERSION = "0.23.0-alpha.6.2"

local function writeLog(stage, err)
    pcall(function()
        local dir = fs.getDir(ERROR_LOG)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local f = fs.open(ERROR_LOG, "w")
        if not f then return end
        f.write(table.concat({
            "BASE Pointer UI diagnostic",
            "version=" .. COMPAT_VERSION,
            "stage=" .. tostring(stage),
            "error=" .. tostring(err),
            "impl=" .. IMPL_PATH,
            "escape=" .. tostring(keys and keys.escape),
            "epoch=" .. tostring(os.epoch and os.epoch("utc") or 0),
        }, "\n") .. "\n")
        f.close()
    end)
end

if type(keys) ~= "table" then
    writeLog("keys_api", "keys table unavailable")
    error("Pointer UI keys API unavailable", 0)
end

-- Polymania may omit optional key constants. Never use a nil key in a table.
-- Keep the compatibility value local to the navigation implementation.
local keyProxy = setmetatable({}, { __index = keys })
if type(keys.escape) == "number" then
    keyProxy.escape = keys.escape
else
    keyProxy.escape = 65530
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

local source, sourceErr = readText(IMPL_PATH)
if not source then
    writeLog("nav_core_read", sourceErr)
    error("Cannot read navigation core: " .. tostring(sourceErr), 0)
end

-- Keep the field-tested alpha5.4.5 navigation implementation as the base and
-- patch only alpha6.2 Jobs affordances. Exact-match guards make upstream drift
-- fail closed instead of silently producing a partially patched UI.
local patches = {
    {
        label = "version",
        old = 'local HOST_VERSION = "0.23.0-alpha.5.4.5"',
        new = 'local HOST_VERSION = "0.23.0-alpha.6.2"',
    },
    {
        label = "jobs_actions",
        old = '        {"Tunnel",keys.t},{"Cancel",keys.c},{"Update",keys.u},{"Back",keys.q},',
        new = '        {"Tunnel",keys.t},{"Box",keys.x},{"Cancel",keys.c},{"Update",keys.u},{"Back",keys.q},',
    },
    {
        label = "box_fields",
        old = '    if p:find("distance",1,true) then return {kind="number",min=1,max=4096,step=1,coarse=10,decimals=0}',
        new = table.concat({
            '    if p:find("distance",1,true) then return {kind="number",min=1,max=4096,step=1,coarse=10,decimals=0}',
            '    elseif p:find("width",1,true) or p:find("length",1,true) or p:find("height",1,true) or p:find("depth",1,true) then',
            '        return {kind="number",min=1,max=64,step=1,coarse=4,decimals=0}',
            '    elseif p:find("unit id",1,true) then return {kind="number",min=1,max=999999,step=1,coarse=10,decimals=0}',
        }, "\n"),
    },
}

for _, patch in ipairs(patches) do
    local patched, patchErr = replaceOnce(source, patch.old, patch.new, patch.label)
    if not patched then
        writeLog("nav_core_patch", patchErr)
        error("Navigation compatibility patch failed: " .. tostring(patchErr), 0)
    end
    source = patched
end

local env = setmetatable({ keys = keyProxy }, { __index = _ENV })
env._G = env

local loader, loadErr = load(source, "@" .. IMPL_PATH, "t", env)
if not loader then
    writeLog("nav_core_load", loadErr)
    error("Cannot load navigation core: " .. tostring(loadErr), 0)
end

local ok, core = pcall(loader)
if not ok then
    writeLog("nav_core_init", core)
    error(core, 0)
end
if type(core) ~= "table" or type(core.run) ~= "function" then
    writeLog("nav_core_contract", "run() missing")
    error("Navigation core contract invalid", 0)
end

return core
