local Sandbox = {}

Sandbox.VERSION = 2
Sandbox.DATA_ROOT = "/data/sandbox"
Sandbox.LOG_PATH = "/data/security/sandbox_log.json"
Sandbox.MAX_LOG_ENTRIES = 64

local function nowMs()
    if os.epoch then
        return os.epoch("utc")
    end

    return math.floor(os.clock() * 1000)
end

local function sanitizeId(value)
    value = tostring(value or "app"):lower()
    value = value:gsub("[^%w%._%-]", "-")
    value = value:gsub("%-+", "-")
    value = value:gsub("^%-+", ""):gsub("%-+$", "")

    if value == "" then
        value = "app"
    end

    return value:sub(1, 48)
end

local function ensureDir(path)
    if not fs.exists(path) then
        fs.makeDir(path)
    end
end

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then
        return nil
    end

    local file = fs.open(path, "r")

    if not file then
        return nil
    end

    local raw = file.readAll()
    file.close()

    local ok, value = pcall(textutils.unserializeJSON, raw)
    return ok and type(value) == "table" and value or nil
end

local function writeJson(path, value)
    local dir = fs.getDir(path)

    if dir ~= "" then
        if dir:sub(1, 1) ~= "/" then
            dir = "/" .. dir
        end
        ensureDir(dir)
    end

    local ok, raw = pcall(textutils.serializeJSON, value)

    if not ok or type(raw) ~= "string" then
        return false
    end

    local file = fs.open(path, "w")

    if not file then
        return false
    end

    file.write(raw)
    file.close()
    return true
end

local function copyLibrary(source)
    if type(source) ~= "table" then
        return source
    end

    local result = {}

    for key, value in pairs(source) do
        result[key] = value
    end

    return result
end

local function safeGetMetatable(value)
    if type(value) ~= "table" then
        return nil
    end

    local meta = getmetatable(value)
    return type(meta) == "table" and meta or nil
end

local function safeSetMetatable(value, meta)
    if type(value) ~= "table" then
        error("sandbox metatable target must be a table", 2)
    end

    if meta ~= nil and type(meta) ~= "table" then
        error("sandbox metatable must be a table or nil", 2)
    end

    return setmetatable(value, meta)
end

function Sandbox.storageRoot(id)
    id = sanitizeId(id)
    return Sandbox.DATA_ROOT .. "/" .. id
end

function Sandbox.clearStorage(id)
    local root = Sandbox.storageRoot(id)

    if fs.exists(root) then
        fs.delete(root)
    end

    return true
end

local function virtualPath(path)
    if type(path) ~= "string" then
        return nil, "sandbox_path_not_string"
    end

    path = path:gsub("\\", "/")
    local parts = {}

    for part in path:gmatch("[^/]+") do
        if part == "." or part == "" then
            -- Ignore harmless path components.
        elseif part == ".." then
            return nil, "sandbox_parent_traversal_denied"
        else
            table.insert(parts, part)
        end
    end

    if #parts == 0 then
        return "/"
    end

    return "/" .. table.concat(parts, "/")
end

local function joinHost(root, path)
    local normalized, err = virtualPath(path)

    if not normalized then
        return nil, err
    end

    if normalized == "/" then
        return root, normalized
    end

    return root .. "/" .. normalized:sub(2), normalized
end

local function virtualDir(path)
    local normalized, err = virtualPath(path)

    if not normalized then
        return nil, err
    end

    if normalized == "/" then
        return "/"
    end

    local index = normalized:match("^.*()/")

    if not index or index == 1 then
        return "/"
    end

    return normalized:sub(1, index - 1)
end

local function virtualName(path)
    local normalized, err = virtualPath(path)

    if not normalized then
        return nil, err
    end

    if normalized == "/" then
        return ""
    end

    return normalized:match("([^/]+)$") or ""
end

local function createFs(root)
    ensureDir(Sandbox.DATA_ROOT)
    ensureDir(root)

    local safeFs = {}

    local function map(path)
        local host, normalizedOrError = joinHost(root, path)

        if not host then
            error(normalizedOrError, 3)
        end

        return host, normalizedOrError
    end

    function safeFs.combine(...)
        local args = {...}
        local combined = ""

        for _, value in ipairs(args) do
            value = tostring(value or "")

            if combined == "" then
                combined = value
            elseif value ~= "" then
                combined = combined .. "/" .. value
            end
        end

        local normalized, err = virtualPath(combined)

        if not normalized then
            error(err, 2)
        end

        return normalized
    end

    function safeFs.getName(path)
        local name, err = virtualName(path)
        if name == nil then error(err, 2) end
        return name
    end

    function safeFs.getDir(path)
        local dir, err = virtualDir(path)
        if dir == nil then error(err, 2) end
        return dir
    end

    function safeFs.exists(path)
        local host = map(path)
        return fs.exists(host)
    end

    function safeFs.isDir(path)
        local host = map(path)
        return fs.exists(host) and fs.isDir(host)
    end

    function safeFs.isReadOnly(_)
        return false
    end

    function safeFs.list(path)
        local host = map(path)

        if not fs.exists(host) or not fs.isDir(host) then
            error("Not a directory", 2)
        end

        return fs.list(host)
    end

    function safeFs.makeDir(path)
        local host = map(path)
        fs.makeDir(host)
    end

    function safeFs.delete(path)
        local host, normalized = map(path)

        if normalized == "/" then
            if fs.exists(root) then
                fs.delete(root)
            end
            ensureDir(root)
            return
        end

        if fs.exists(host) then
            fs.delete(host)
        end
    end

    function safeFs.move(fromPath, toPath)
        local fromHost = map(fromPath)
        local toHost = map(toPath)
        local parent = fs.getDir(toHost)

        if parent ~= "" then
            ensureDir(parent)
        end

        fs.move(fromHost, toHost)
    end

    function safeFs.copy(fromPath, toPath)
        local fromHost = map(fromPath)
        local toHost = map(toPath)
        local parent = fs.getDir(toHost)

        if parent ~= "" then
            ensureDir(parent)
        end

        fs.copy(fromHost, toHost)
    end

    function safeFs.getSize(path)
        local host = map(path)
        return fs.getSize(host)
    end

    function safeFs.getFreeSpace(_)
        return fs.getFreeSpace(root)
    end

    if fs.getCapacity then
        function safeFs.getCapacity(_)
            return fs.getCapacity(root)
        end
    end

    function safeFs.getDrive(_)
        return "sandbox"
    end

    if fs.attributes then
        function safeFs.attributes(path)
            local host = map(path)
            local attributes = fs.attributes(host)

            if type(attributes) ~= "table" then
                return attributes
            end

            local copy = {}
            for key, value in pairs(attributes) do copy[key] = value end
            return copy
        end
    end

    function safeFs.open(path, mode)
        mode = mode or "r"
        local host = map(path)
        local first = mode:sub(1, 1)

        if first == "w" or first == "a" then
            local parent = fs.getDir(host)

            if parent ~= "" then
                ensureDir(parent)
            end
        end

        return fs.open(host, mode)
    end

    return safeFs
end

local SAFE_EVENTS = {
    key = true,
    key_up = true,
    char = true,
    paste = true,
    mouse_click = true,
    mouse_up = true,
    mouse_drag = true,
    mouse_scroll = true,
    monitor_touch = true,
    term_resize = true
}

local function createOs()
    local safeOs = {}
    local timers = {}

    safeOs.clock = os.clock
    safeOs.time = os.time
    safeOs.day = os.day
    safeOs.epoch = os.epoch
    safeOs.date = os.date
    safeOs.getComputerID = os.getComputerID
    safeOs.getComputerLabel = os.getComputerLabel

    function safeOs.startTimer(seconds)
        local id = os.startTimer(seconds)
        timers[id] = true
        return id
    end

    function safeOs.cancelTimer(id)
        if timers[id] ~= true then
            return false
        end

        timers[id] = nil
        os.cancelTimer(id)
        return true
    end

    local function pull(filter, raw)
        while true do
            local event = {os.pullEventRaw()}
            local name = event[1]

            if name == "terminate" then
                if raw then
                    return table.unpack(event)
                end

                error("Terminated", 0)
            end

            local allowed = SAFE_EVENTS[name] == true

            if name == "timer" then
                allowed = timers[event[2]] == true

                if allowed then
                    timers[event[2]] = nil
                end
            end

            if allowed and (filter == nil or filter == name) then
                return table.unpack(event)
            end
        end
    end

    function safeOs.pullEvent(filter)
        return pull(filter, false)
    end

    function safeOs.pullEventRaw(filter)
        return pull(filter, true)
    end

    return safeOs
end

local function createTerm()
    local safeTerm = {}
    local names = {
        "write",
        "blit",
        "clear",
        "clearLine",
        "getCursorPos",
        "setCursorPos",
        "getCursorBlink",
        "setCursorBlink",
        "isColor",
        "isColour",
        "getSize",
        "scroll",
        "setTextColor",
        "setTextColour",
        "getTextColor",
        "getTextColour",
        "setBackgroundColor",
        "setBackgroundColour",
        "getBackgroundColor",
        "getBackgroundColour",
        "getPaletteColor",
        "getPaletteColour"
    }

    for _, name in ipairs(names) do
        local hostFunction = term[name]

        if type(hostFunction) == "function" then
            safeTerm[name] = function(...)
                return hostFunction(...)
            end
        end
    end

    return safeTerm
end

local function createTextutils()
    return {
        serialize = textutils.serialize,
        serialise = textutils.serialise,
        serializeJSON = textutils.serializeJSON,
        serialiseJSON = textutils.serialiseJSON,
        unserializeJSON = textutils.unserializeJSON,
        unserialiseJSON = textutils.unserialiseJSON,
        urlEncode = textutils.urlEncode
    }
end

local function sandboxSleep(safeOs, seconds)
    seconds = tonumber(seconds) or 0
    local timer = safeOs.startTimer(math.max(0, seconds))

    while true do
        local _, id = safeOs.pullEvent("timer")

        if id == timer then
            return
        end
    end
end

function Sandbox.makeEnvironment(programPath, options)
    options = options or {}

    local id = sanitizeId(options.id or fs.getName(programPath or "app"))
    local root = Sandbox.storageRoot(id)

    if options.resetStorage == true then
        Sandbox.clearStorage(id)
    end

    ensureDir(Sandbox.DATA_ROOT)
    ensureDir(root)

    local safeOs = createOs()
    local env = {
        _VERSION = _VERSION,
        assert = assert,
        error = error,
        ipairs = ipairs,
        next = next,
        pairs = pairs,
        pcall = pcall,
        rawequal = rawequal,
        rawget = rawget,
        rawlen = rawlen,
        rawset = rawset,
        select = select,
        setmetatable = safeSetMetatable,
        getmetatable = safeGetMetatable,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        xpcall = xpcall,
        print = print,
        write = write,
        read = read,
        string = copyLibrary(string),
        table = copyLibrary(table),
        math = copyLibrary(math),
        bit32 = copyLibrary(bit32),
        colors = copyLibrary(colors),
        colours = copyLibrary(colours),
        keys = copyLibrary(keys),
        utf8 = copyLibrary(utf8),
        fs = createFs(root),
        os = safeOs,
        term = createTerm(),
        textutils = createTextutils(),
        sandbox = {
            version = Sandbox.VERSION,
            id = id,
            storage = "/",
            network = false,
            http = false,
            shell = false,
            peripherals = false,
            require = false,
            dynamicLoad = false,
            systemControl = false,
            hostFilesystem = false,
            hostGlobals = false
        }
    }

    env.sleep = function(seconds)
        return sandboxSleep(safeOs, seconds)
    end

    env._G = env
    env._ENV = env

    return env, id, root
end

function Sandbox.appendExecutionLog(entry)
    local log = readJson(Sandbox.LOG_PATH)

    if type(log) ~= "table" then
        log = {}
    end

    entry = type(entry) == "table" and entry or {}
    entry.at = entry.at or nowMs()
    table.insert(log, entry)

    while #log > Sandbox.MAX_LOG_ENTRIES do
        table.remove(log, 1)
    end

    return writeJson(Sandbox.LOG_PATH, log)
end

function Sandbox.loadExecutionLog()
    local log = readJson(Sandbox.LOG_PATH)
    return type(log) == "table" and log or {}
end

return Sandbox
