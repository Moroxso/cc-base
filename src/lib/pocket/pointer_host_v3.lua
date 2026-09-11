local Host = {}

local HOST_VERSION = "0.23.0-alpha.5.4.2"
local CORE_PATH = "/lib/pocket/pointer_host_core.lua"
local ERROR_LOG = "/data/pointer_ui_error.log"

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function writeLog(stage, err, extra)
    pcall(function()
        ensureParent(ERROR_LOG)
        local f = fs.open(ERROR_LOG, "w")
        if not f then return end
        local lines = {
            "BASE Pointer UI diagnostic",
            "version=" .. HOST_VERSION,
            "stage=" .. tostring(stage),
            "error=" .. tostring(err),
            "epoch=" .. tostring(os.epoch and os.epoch("utc") or 0),
        }
        if extra then lines[#lines + 1] = tostring(extra) end
        f.write(table.concat(lines, "\n") .. "\n")
        f.close()
    end)
end

local coreLoader, coreLoadErr = loadfile(CORE_PATH, "t", _ENV)
if not coreLoader then
    writeLog("host_core_load", coreLoadErr)
    error("Cannot load pointer host core: " .. tostring(coreLoadErr), 0)
end
local okCore, Core = pcall(coreLoader)
if not okCore or type(Core) ~= "table" or type(Core.run) ~= "function" then
    writeLog("host_core_init", Core)
    error("Pointer host core invalid: " .. tostring(Core), 0)
end

local function makeCompatOpen(originalOpen)
    return function(path, mode)
        local h = originalOpen(path, mode)
        if not h or type(h.writeLine) == "function" or type(h.write) ~= "function" then return h end
        return setmetatable({
            writeLine = function(text) return h.write(tostring(text or "") .. "\n") end,
        }, {
            __index = function(_, key) return h[key] end,
        })
    end
end

local function buildProgramRunner(originalRun)
    return function(env, path, ...)
        if type(env) ~= "table" then error("os.run env must be a table", 0) end
        if type(path) ~= "string" then error("os.run path must be a string", 0) end

        env._G = env
        if rawget(env, "shell") == nil and shell ~= nil then env.shell = shell end
        if rawget(env, "multishell") == nil and multishell ~= nil then env.multishell = multishell end

        local okRequire, requireLib = pcall(require, "cc.require")
        if not okRequire or type(requireLib) ~= "table" or type(requireLib.make) ~= "function" then
            error("cc.require.make unavailable: " .. tostring(requireLib), 0)
        end

        local dir = fs.getDir(path)
        if not dir or dir == "" then dir = "/" end
        env.require, env.package = requireLib.make(env, dir)

        local loader, loadErr = loadfile(path, "t", env)
        if not loader then error("Core load failed: " .. tostring(loadErr), 0) end

        local args = {...}
        local unpackFn = table.unpack or unpack
        local okRun, runErr = pcall(loader, unpackFn(args))
        if not okRun then error(runErr, 0) end
        return true
    end
end

function Host.run(corePath, profileName)
    local originalRun = os.run
    local originalOpen = fs.open
    os.run = buildProgramRunner(originalRun)
    fs.open = makeCompatOpen(originalOpen)

    local ok, err = pcall(Core.run, corePath, profileName)

    os.run = originalRun
    fs.open = originalOpen

    if not ok then
        writeLog("host_run", err, "core=" .. tostring(corePath) .. " profile=" .. tostring(profileName))
        error(err, 0)
    end
    return true
end

Host.VERSION = HOST_VERSION
Host.ERROR_LOG = ERROR_LOG
return Host
