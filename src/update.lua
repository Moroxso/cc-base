local ENGINE_PATH = "/lib/system/updater.lua"
local ENGINE_NEXT = "/.cc_updater_next.lua"
local ENGINE_PREV = "/.cc_updater_prev.lua"
local PROGRAM_ENV = _ENV

local function loadEngine(path)
    if not fs.exists(path) or fs.isDir(path) then
        return nil, "missing"
    end

    -- CC:Tweaked injects require/package into each program environment. A raw
    -- loadfile(path) does not reliably preserve that environment in the
    -- Polymania port, so pass it explicitly to updater modules.
    local chunk, loadError = loadfile(path, "t", PROGRAM_ENV)

    if not chunk then
        return nil, tostring(loadError or "load_failed")
    end

    local ok, value = pcall(chunk)

    if not ok then
        return nil, tostring(value or "module_failed")
    end

    if type(value) ~= "table" or type(value.main) ~= "function" then
        return nil, "invalid_updater_module"
    end

    return value
end

local function replaceWith(source)
    if fs.exists(ENGINE_PATH) then
        pcall(fs.delete, ENGINE_PATH)
    end

    local ok, err = pcall(fs.move, source, ENGINE_PATH)

    if not ok then
        return false, tostring(err)
    end

    return true
end

local function resolveEngine()
    local engine, err = loadEngine(ENGINE_PATH)

    if engine then
        return engine
    end

    local nextEngine = loadEngine(ENGINE_NEXT)

    if nextEngine then
        local moved, moveError = replaceWith(ENGINE_NEXT)

        if not moved then
            return nil, "cannot activate updater recovery copy: " .. tostring(moveError)
        end

        return loadEngine(ENGINE_PATH)
    end

    local previousEngine = loadEngine(ENGINE_PREV)

    if previousEngine then
        local moved, moveError = replaceWith(ENGINE_PREV)

        if not moved then
            return nil, "cannot restore previous updater engine: " .. tostring(moveError)
        end

        return loadEngine(ENGINE_PATH)
    end

    return nil, "Updater engine unavailable: " .. tostring(err)
end

local updater, engineError = resolveEngine()

if not updater then
    term.setTextColor(colors.red)
    print("UPDATE BOOTSTRAP FAILED")
    print(tostring(engineError))
    print("")
    print("Use rescue_update.lua to repair the installation.")
    error(engineError, 0)
end

local args = {...}
local ok, result = xpcall(function()
    return updater.main(args)
end, function(message)
    return tostring(message)
end)

if not ok then
    term.setTextColor(colors.red)
    print("")
    print("UPDATE FAILED")
    print(tostring(result))
    error(result, 0)
end

return result