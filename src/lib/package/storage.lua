local Storage = {}

local function normalizePath(path)
    path = tostring(path or "/")

    if path == "" then
        return "/"
    end

    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    return path
end

local function normalizeSpace(value)
    if value == "unlimited" then
        return math.huge
    end

    local number = tonumber(value)

    if number == nil then
        return nil
    end

    return math.max(0, number)
end

function Storage.getDrive(path)
    path = normalizePath(path)

    if type(fs.getDrive) ~= "function" then
        return nil, "unsupported"
    end

    local ok, value = pcall(fs.getDrive, path)

    if not ok then
        return nil, tostring(value)
    end

    if value == nil then
        return nil, "unmounted"
    end

    return tostring(value)
end

function Storage.getFreeSpace(path)
    path = normalizePath(path)

    if type(fs.getFreeSpace) ~= "function" then
        return nil, "unsupported"
    end

    local ok, value = pcall(fs.getFreeSpace, path)

    if not ok then
        return nil, tostring(value)
    end

    local normalized = normalizeSpace(value)

    if normalized == nil then
        return nil, "invalid_free_space"
    end

    return normalized
end

function Storage.getCapacity(path)
    path = normalizePath(path)

    if type(fs.getCapacity) ~= "function" then
        return nil, "unsupported"
    end

    local ok, value = pcall(fs.getCapacity, path)

    if not ok then
        return nil, tostring(value)
    end

    local normalized = normalizeSpace(value)

    if normalized == nil then
        return nil, "invalid_capacity"
    end

    return normalized
end

function Storage.fileSize(path)
    path = normalizePath(path)

    if not fs.exists(path) or fs.isDir(path) then
        return nil, "not_file"
    end

    local ok, value = pcall(fs.getSize, path)

    if not ok then
        return nil, tostring(value)
    end

    return tonumber(value)
end

function Storage.treeSize(path)
    path = normalizePath(path)

    if not fs.exists(path) then
        return 0
    end

    if not fs.isDir(path) then
        return Storage.fileSize(path)
    end

    local total = 0

    for _, name in ipairs(fs.list(path)) do
        local child = fs.combine(path, name)
        local size, err = Storage.treeSize(child)

        if size == nil then
            return nil, err
        end

        total = total + size
    end

    return total
end

function Storage.snapshot(path)
    path = normalizePath(path)

    local drive, driveError = Storage.getDrive(path)
    local free, freeError = Storage.getFreeSpace(path)
    local capacity, capacityError = Storage.getCapacity(path)
    local used = nil

    if capacity ~= nil and free ~= nil and capacity ~= math.huge and free ~= math.huge then
        used = math.max(0, capacity - free)
    end

    return {
        path = path,
        drive = drive,
        driveError = driveError,
        free = free,
        freeError = freeError,
        capacity = capacity,
        capacityError = capacityError,
        used = used
    }
end

function Storage.plan(path, finalDelta, peakExtra, reserve)
    finalDelta = math.max(0, tonumber(finalDelta) or 0)
    peakExtra = math.max(0, tonumber(peakExtra) or 0)
    reserve = math.max(0, tonumber(reserve) or 0)

    local snapshot = Storage.snapshot(path)
    local required = finalDelta + peakExtra + reserve
    local safe = false

    if snapshot.free == math.huge then
        safe = true
    elseif snapshot.free ~= nil then
        safe = snapshot.free >= required
    end

    return {
        path = snapshot.path,
        drive = snapshot.drive,
        capacity = snapshot.capacity,
        free = snapshot.free,
        used = snapshot.used,
        finalDelta = finalDelta,
        peakExtra = peakExtra,
        reserve = reserve,
        required = required,
        safe = safe
    }
end

function Storage.formatBytes(value)
    if value == nil then
        return "unknown"
    end

    if value == math.huge then
        return "unlimited"
    end

    value = math.max(0, math.floor(tonumber(value) or 0))

    if value >= 1024 * 1024 then
        return string.format("%.2f MiB", value / (1024 * 1024))
    elseif value >= 1024 then
        return string.format("%.1f KiB", value / 1024)
    end

    return tostring(value) .. " B"
end

return Storage
