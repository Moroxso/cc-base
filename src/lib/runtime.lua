local ccRequire = require("cc.require")

local Runtime = {}

local function makeEnvironment(baseDir)
    local env = setmetatable({}, {
        __index = _ENV
    })

    env._G = env
    env.require, env.package = ccRequire.make(
        env,
        baseDir or "/"
    )

    return env
end

function Runtime.run(path, ...)
    if type(path) ~= "string" or path == "" then
        return false, "Invalid program path"
    end

    if not fs.exists(path) then
        return false, "Program not found: " .. path
    end

    local env = makeEnvironment("/")
    local ok = os.run(env, path, ...)

    if not ok then
        return false, "Program failed: " .. path
    end

    return true
end

return Runtime
