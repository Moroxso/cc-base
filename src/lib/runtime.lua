local ccRequire = require("cc.require")
local Sandbox = require("lib.security.sandbox")

local Runtime = {}

Runtime.PROFILE_TRUSTED = "trusted"
Runtime.PROFILE_SANDBOX = "sandbox"

local function normalizeDir(path)
    local dir = fs.getDir(path)

    if dir == "" then
        return "/"
    end

    if dir:sub(1, 1) ~= "/" then
        dir = "/" .. dir
    end

    return dir
end

local function validateProgram(path)
    if type(path) ~= "string" or path == "" then
        return false, "Invalid program path"
    end

    if not fs.exists(path) or fs.isDir(path) then
        return false, "Program not found: " .. path
    end

    return true
end

local function makeTrustedEnvironment(programPath)
    local env = setmetatable({}, {
        __index = _ENV
    })

    env._G = env
    env.require, env.package = ccRequire.make(
        env,
        "/"
    )

    local programDir = normalizeDir(programPath)

    if programDir ~= "/" then
        env.package.path =
            programDir .. "/?.lua;" ..
            programDir .. "/?/init.lua;" ..
            env.package.path
    end

    return env
end

function Runtime.run(path, ...)
    local valid, err = validateProgram(path)

    if not valid then
        return false, err
    end

    local env = makeTrustedEnvironment(path)
    local ok = os.run(env, path, ...)

    if not ok then
        return false, "Program failed: " .. path
    end

    return true
end

function Runtime.runSandboxed(path, options, ...)
    local valid, err = validateProgram(path)

    if not valid then
        return false, err
    end

    options = type(options) == "table" and options or {}

    local env, sandboxId, storageRoot = Sandbox.makeEnvironment(
        path,
        options
    )

    local startedAt = os.epoch and
        os.epoch("utc") or
        math.floor(os.clock() * 1000)

    -- Do not use os.run here. CraftOS deliberately gives os.run
    -- environments a metatable whose __index points at the host _G.
    -- That is convenient for normal programs, but defeats a capability
    -- sandbox because omitted globals (rednet/http/peripheral/etc.) become
    -- visible again. loadfile's explicit environment is used instead.
    local chunk, loadError = loadfile(path, "t", env)

    if not chunk then
        Sandbox.appendExecutionLog({
            sandboxId = sandboxId,
            program = path,
            storageRoot = storageRoot,
            ok = false,
            phase = "load",
            error = tostring(loadError or "load_failed"),
            startedAt = startedAt
        })

        return false,
            "Sandbox load failed: " .. tostring(loadError or "unknown"),
            sandboxId
    end

    local ok, runError = pcall(chunk, ...)

    Sandbox.appendExecutionLog({
        sandboxId = sandboxId,
        program = path,
        storageRoot = storageRoot,
        ok = ok == true,
        phase = "run",
        error = ok and nil or tostring(runError or "runtime_error"),
        startedAt = startedAt
    })

    if not ok then
        return false,
            "Sandboxed program failed: " .. tostring(runError or "unknown"),
            sandboxId
    end

    return true, sandboxId, storageRoot
end

return Runtime
