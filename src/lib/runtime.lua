local ccRequire = require("cc.require")

local Runtime = {}

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

local function makeEnvironment(programPath)
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
    if type(path) ~= "string" or path == "" then
        return false, "Invalid program path"
    end

    if not fs.exists(path) then
        return false, "Program not found: " .. path
    end

    local env = makeEnvironment(path)
    local ok = os.run(env, path, ...)

    if not ok then
        return false, "Program failed: " .. path
    end

    return true
end

return Runtime
