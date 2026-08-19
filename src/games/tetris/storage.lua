local Storage = {}

local DEFAULT_PATH = "/data/tetris.json"

local function defaultData()
    return {
        version = 1,
        highScore = 0,
        bestLines = 0,
        bestLevel = 1
    }
end

local function ensureParent(path)
    local dir = fs.getDir(path)

    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function normalize(data)
    if type(data) ~= "table" then
        return defaultData()
    end

    return {
        version = 1,
        highScore = math.max(0, math.floor(tonumber(data.highScore) or 0)),
        bestLines = math.max(0, math.floor(tonumber(data.bestLines) or 0)),
        bestLevel = math.max(1, math.floor(tonumber(data.bestLevel) or 1))
    }
end

function Storage.load(path)
    path = path or DEFAULT_PATH

    if not fs.exists(path) then
        return defaultData()
    end

    local file = fs.open(path, "r")

    if not file then
        return defaultData()
    end

    local raw = file.readAll()
    file.close()

    local ok, data = pcall(textutils.unserializeJSON, raw)

    if not ok then
        return defaultData()
    end

    return normalize(data)
end

function Storage.save(data, path)
    path = path or DEFAULT_PATH
    data = normalize(data)

    ensureParent(path)

    local file = fs.open(path, "w")

    if not file then
        return false, "Cannot open Tetris data for writing"
    end

    file.write(textutils.serializeJSON(data))
    file.close()

    return true
end

function Storage.update(records, game)
    records = normalize(records)
    local changed = false

    if game.score > records.highScore then
        records.highScore = game.score
        changed = true
    end

    if game.lines > records.bestLines then
        records.bestLines = game.lines
        changed = true
    end

    if game.level > records.bestLevel then
        records.bestLevel = game.level
        changed = true
    end

    return records, changed
end

return Storage
