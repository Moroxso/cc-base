local Storage = {}

local function normalizePath(path)
    path = tostring(path or "/"):gsub("\\", "/")
    if path == "" then return "/" end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    while path:find("//", 1, true) do path = path:gsub("//", "/") end
    if #path > 1 then path = path:gsub("/+$", "") end
    return path
end

local function normalizeSpace(value)
    if value == "unlimited" then return math.huge end
    local number = tonumber(value)
    if number == nil then return nil end
    return math.max(0, number)
end

function Storage.existingAnchor(path)
    local requested = normalizePath(path)
    local current = requested

    while current ~= "/" and not fs.exists(current) do
        local parent = fs.getDir(current)
        if parent == "" then current = "/" else current = normalizePath(parent) end
    end

    if not fs.exists(current) then
        if fs.exists("/") then return "/", requested end
        return nil, requested, "filesystem_root_missing"
    end

    return current, requested
end

local function callFs(name, path)
    local fn = fs[name]
    if type(fn) ~= "function" then return nil, "unsupported" end
    local anchor, requested, anchorError = Storage.existingAnchor(path)
    if not anchor then return nil, anchorError, requested end
    local ok, value = pcall(fn, anchor)
    if not ok then return nil, tostring(value), requested end
    return value, nil, requested, anchor
end

function Storage.getDrive(path)
    local value, err = callFs("getDrive", path)
    if value == nil then return nil, err or "unmounted" end
    return tostring(value)
end

function Storage.getFreeSpace(path)
    local value, err = callFs("getFreeSpace", path)
    if value == nil then return nil, err end
    local normalized = normalizeSpace(value)
    if normalized == nil then return nil, "invalid_free_space" end
    return normalized
end

function Storage.getCapacity(path)
    local value, err = callFs("getCapacity", path)
    if value == nil then return nil, err or "capacity_unavailable" end
    local normalized = normalizeSpace(value)
    if normalized == nil then return nil, "invalid_capacity" end
    return normalized
end

function Storage.isReadOnly(path)
    local value, err = callFs("isReadOnly", path)
    if value == nil then return nil, err end
    return value == true
end

function Storage.fileSize(path)
    path = normalizePath(path)
    if not fs.exists(path) or fs.isDir(path) then return nil, "not_file" end
    local ok, value = pcall(fs.getSize, path)
    if not ok then return nil, tostring(value) end
    return tonumber(value)
end

function Storage.treeSize(path)
    path = normalizePath(path)
    if not fs.exists(path) then return 0 end
    if not fs.isDir(path) then return Storage.fileSize(path) end

    local total = 0
    for _, name in ipairs(fs.list(path)) do
        local child = fs.combine(path, name)
        local size, err = Storage.treeSize(child)
        if size == nil then return nil, err end
        total = total + size
    end
    return total
end

function Storage.snapshot(path)
    local anchor, requested, anchorError = Storage.existingAnchor(path)
    if not anchor then
        return {
            path = requested,
            anchor = nil,
            drive = nil,
            driveError = anchorError,
            free = nil,
            freeError = anchorError,
            capacity = nil,
            capacityError = anchorError,
            readOnly = nil,
            readOnlyError = anchorError,
            used = nil
        }
    end

    local drive, driveError = Storage.getDrive(anchor)
    local free, freeError = Storage.getFreeSpace(anchor)
    local capacity, capacityError = Storage.getCapacity(anchor)
    local readOnly, readOnlyError = Storage.isReadOnly(anchor)
    local used = nil

    if capacity ~= nil and free ~= nil and capacity ~= math.huge and free ~= math.huge then
        used = math.max(0, capacity - free)
    end

    return {
        path = requested,
        anchor = anchor,
        drive = drive,
        driveError = driveError,
        free = free,
        freeError = freeError,
        capacity = capacity,
        capacityError = capacityError,
        readOnly = readOnly,
        readOnlyError = readOnlyError,
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

    if snapshot.readOnly == true then
        safe = false
    elseif snapshot.free == math.huge then
        safe = true
    elseif snapshot.free ~= nil then
        safe = snapshot.free >= required
    end

    return {
        path = snapshot.path,
        anchor = snapshot.anchor,
        drive = snapshot.drive,
        capacity = snapshot.capacity,
        free = snapshot.free,
        used = snapshot.used,
        readOnly = snapshot.readOnly,
        finalDelta = finalDelta,
        peakExtra = peakExtra,
        reserve = reserve,
        required = required,
        safe = safe
    }
end

function Storage.sameDrive(paths)
    local drive = nil
    local anchors = {}

    for _, path in ipairs(paths or {}) do
        local snapshot = Storage.snapshot(path)
        if not snapshot.drive then return false, nil, "drive_unknown:" .. tostring(path) end
        if drive and snapshot.drive ~= drive then
            return false, nil, "multiple_drives:" .. tostring(drive) .. ":" .. tostring(snapshot.drive)
        end
        drive = snapshot.drive
        anchors[#anchors + 1] = snapshot.anchor
    end

    return true, drive, anchors
end

function Storage.formatBytes(value)
    if value == nil then return "unknown" end
    if value == math.huge then return "unlimited" end
    value = math.max(0, math.floor(tonumber(value) or 0))
    if value >= 1024 * 1024 then
        return string.format("%.2f MiB", value / (1024 * 1024))
    elseif value >= 1024 then
        return string.format("%.1f KiB", value / 1024)
    end
    return tostring(value) .. " B"
end

return Storage
