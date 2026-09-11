local IMPL_PATH = "/lib/pocket/pointer_host_core_nav.lua"
local ERROR_LOG = "/data/pointer_ui_error.log"

local function writeLog(stage, err)
    pcall(function()
        local dir = fs.getDir(ERROR_LOG)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local f = fs.open(ERROR_LOG, "w")
        if not f then return end
        f.write(table.concat({
            "BASE Pointer UI diagnostic",
            "version=0.23.0-alpha.5.4.4",
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
    -- No physical key uses this value. Pointer-generated Default/Back actions can
    -- still compare against it inside the navigation core without touching _G.keys.
    keyProxy.escape = 65530
end

local env = setmetatable({ keys = keyProxy }, { __index = _ENV })
env._G = env

local loader, loadErr = loadfile(IMPL_PATH, "t", env)
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
