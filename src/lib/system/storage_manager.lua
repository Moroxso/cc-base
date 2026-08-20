local Registry = require("lib.package.registry")
local Storage = require("lib.package.storage")

local StorageManager = {}
StorageManager.__index = StorageManager

StorageManager.COPY_RESERVE = 4096
StorageManager.DEPLOY_PATH = "/deploy.json"
StorageManager.PACKAGE_REGISTRY_PATH = Registry.DEFAULT_PATH

local SYSTEM_PREFIXES = {
    "/data/system",
    "/data/security",
    "/lib",
    "/apps",
    "/games"
}

local SYSTEM_EXACT = {
    ["/.project-version"] = "system",
    ["/deploy.json"] = "system",
    ["/packages.json"] = "system",
    ["/.cc_updater_next.lua"] = "system",
    ["/.cc_updater_prev.lua"] = "system"
}

local function normalize(path)
    path = tostring(path or "/"):gsub("\\", "/")
    if path == "" then return "/" end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    while path:find("//", 1, true) do
        path = path:gsub("//", "/")
    end
    if #path > 1 then path = path:gsub("/+$", "") end
    return path
end

local function isInside(path, parent)
    path = normalize(path)
    parent = normalize(parent)
    if parent == "/" then return true end
    return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function basename(path)
    path = normalize(path)
    if path == "/" then return "/" end
    return fs.getName(path)
end

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local raw = file.readAll()
    file.close()
    local ok, value = pcall(textutils.unserializeJSON, raw)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

local function validName(name)
    return type(name) == "string"
        and name ~= ""
        and name ~= "."
        and name ~= ".."
        and not name:find("/", 1, true)
        and not name:find("\\", 1, true)
end

function StorageManager.new(options)
    options = type(options) == "table" and options or {}
    local self = setmetatable({
        deployPath = options.deployPath or StorageManager.DEPLOY_PATH,
        registryPath = options.registryPath or StorageManager.PACKAGE_REGISTRY_PATH,
        owned = {},
        protectedTargets = {},
        lastOwnershipError = nil
    }, StorageManager)
    self:refreshOwnership()
    return self
end

function StorageManager:refreshOwnership()
    local owned = {}
    local protectedTargets = {}

    for path, owner in pairs(SYSTEM_EXACT) do
        owned[path] = owner
        protectedTargets[#protectedTargets + 1] = path
    end

    for _, prefix in ipairs(SYSTEM_PREFIXES) do
        protectedTargets[#protectedTargets + 1] = prefix
    end

    local deploy = readJson(self.deployPath)
    if type(deploy) == "table" and type(deploy.files) == "table" then
        for _, item in ipairs(deploy.files) do
            if type(item) == "table" and type(item.target) == "string" and item.target ~= "" then
                local target = normalize(item.target)
                owned[target] = "base.core"
                protectedTargets[#protectedTargets + 1] = target
            end
        end
    end

    local registry, registryError = Registry.load(self.registryPath)
    if registry then
        for target, owner in pairs(Registry.ownershipMap(registry)) do
            local path = normalize(target)
            owned[path] = owner
            protectedTargets[#protectedTargets + 1] = path
        end
        self.lastOwnershipError = nil
    else
        self.lastOwnershipError = registryError
    end

    self.owned = owned
    self.protectedTargets = protectedTargets
    return true
end

function StorageManager:ownerOf(path)
    self:refreshOwnership()
    return self.owned[normalize(path)]
end

function StorageManager:exactProtection(path)
    path = normalize(path)
    local owner = self.owned[path]
    if owner then return owner end

    for _, prefix in ipairs(SYSTEM_PREFIXES) do
        if isInside(path, prefix) then return "system-data" end
    end

    return nil
end

function StorageManager:destructiveProtectionDetails(path)
    path = normalize(path)

    local owner = self.owned[path]
    if owner then
        return {
            owner = owner,
            target = path,
            kind = "exact"
        }
    end

    for _, prefix in ipairs(SYSTEM_PREFIXES) do
        if isInside(path, prefix) then
            return {
                owner = "system-data",
                target = prefix,
                kind = "prefix"
            }
        end
    end

    for _, target in ipairs(self.protectedTargets) do
        if isInside(target, path) then
            return {
                owner = self.owned[target] or "managed-content",
                target = target,
                kind = "contains"
            }
        end
    end

    return nil
end

function StorageManager:destructiveProtection(path)
    local details = self:destructiveProtectionDetails(path)
    return details and details.owner or nil
end

function StorageManager:list(path)
    path = normalize(path)
    if not fs.exists(path) then return nil, "path_not_found" end
    if not fs.isDir(path) then return nil, "path_not_directory" end

    self:refreshOwnership()

    local ok, names = pcall(fs.list, path)
    if not ok then return nil, tostring(names) end

    local entries = {}
    for _, name in ipairs(names) do
        local child = normalize(fs.combine(path, name))
        local isDir = fs.isDir(child)
        local size = nil
        if not isDir then
            local sizeOk, value = pcall(fs.getSize, child)
            if sizeOk then size = tonumber(value) end
        end

        local readOnly = nil
        if type(fs.isReadOnly) == "function" then
            local roOk, value = pcall(fs.isReadOnly, child)
            if roOk then readOnly = value == true end
        end

        entries[#entries + 1] = {
            name = name,
            path = child,
            isDir = isDir,
            size = size,
            owner = self.owned[child],
            protected = self:destructiveProtection(child) ~= nil,
            readOnly = readOnly
        }
    end

    table.sort(entries, function(a, b)
        if a.isDir ~= b.isDir then return a.isDir end
        return string.lower(a.name) < string.lower(b.name)
    end)

    return entries
end

function StorageManager:inspect(path, includeTreeSize)
    path = normalize(path)
    if not fs.exists(path) then return nil, "path_not_found" end

    self:refreshOwnership()

    local isDir = fs.isDir(path)
    local size = nil
    if isDir then
        if includeTreeSize then
            size = Storage.treeSize(path)
        end
    else
        size = Storage.fileSize(path)
    end

    local attributes = nil
    if type(fs.attributes) == "function" then
        local ok, value = pcall(fs.attributes, path)
        if ok and type(value) == "table" then attributes = value end
    end

    local snapshot = Storage.snapshot(path)
    local exact = self:exactProtection(path)
    local protectionDetails = self:destructiveProtectionDetails(path)
    local destructive = protectionDetails and protectionDetails.owner or nil

    return {
        path = path,
        name = basename(path),
        isDir = isDir,
        size = size,
        attributes = attributes,
        drive = snapshot.drive,
        free = snapshot.free,
        capacity = snapshot.capacity,
        readOnly = snapshot.readOnly,
        owner = self.owned[path],
        exactProtection = exact,
        protected = destructive ~= nil,
        protection = destructive,
        protectionTarget = protectionDetails and protectionDetails.target or nil,
        protectionKind = protectionDetails and protectionDetails.kind or nil
    }
end

function StorageManager:listMounts()
    local result = {}
    local seen = {}

    local function add(path)
        path = normalize(path)
        local snapshot = Storage.snapshot(path)
        local key = tostring(snapshot.drive or "?") .. ":" .. path
        if not seen[key] then
            seen[key] = true
            result[#result + 1] = {
                path = path,
                drive = snapshot.drive,
                capacity = snapshot.capacity,
                free = snapshot.free,
                used = snapshot.used,
                readOnly = snapshot.readOnly
            }
        end
    end

    add("/")

    local rootDrive = Storage.getDrive("/")
    local ok, names = pcall(fs.list, "/")
    if ok and type(names) == "table" then
        for _, name in ipairs(names) do
            local child = normalize(fs.combine("/", name))
            if fs.isDir(child) then
                local drive = Storage.getDrive(child)
                local driveRoot = false
                if type(fs.isDriveRoot) == "function" then
                    local rootOk, value = pcall(fs.isDriveRoot, child)
                    driveRoot = rootOk and value == true
                end
                if driveRoot or (drive and drive ~= rootDrive) then
                    add(child)
                end
            end
        end
    end

    table.sort(result, function(a, b) return a.path < b.path end)
    return result
end

function StorageManager:_destination(source, destinationDir)
    source = normalize(source)
    destinationDir = normalize(destinationDir)
    if not fs.exists(destinationDir) or not fs.isDir(destinationDir) then
        return nil, "destination_not_directory"
    end
    local target = normalize(fs.combine(destinationDir, basename(source)))
    if fs.exists(target) then return nil, "destination_exists:" .. target end
    if isInside(target, source) and fs.isDir(source) then
        return nil, "destination_inside_source"
    end
    local protection = self:exactProtection(target)
    if protection then
        return nil, "destination_protected:" .. tostring(protection)
    end
    local readOnly = Storage.isReadOnly(destinationDir)
    if readOnly == true then return nil, "destination_read_only" end
    return target
end

function StorageManager:copyTo(source, destinationDir)
    source = normalize(source)
    destinationDir = normalize(destinationDir)
    if source == "/" then return false, "root_copy_blocked" end
    if not fs.exists(source) then return false, "source_not_found" end

    self:refreshOwnership()
    local target, targetError = self:_destination(source, destinationDir)
    if not target then return false, targetError end

    local bytes, sizeError = Storage.treeSize(source)
    if bytes == nil then return false, "source_size_failed:" .. tostring(sizeError) end

    local plan = Storage.plan(destinationDir, bytes, 0, StorageManager.COPY_RESERVE)
    if not plan.safe then
        return false, "insufficient_space:" .. Storage.formatBytes(plan.required)
    end

    local ok, err = pcall(fs.copy, source, target)
    if not ok then
        if fs.exists(target) and not self:destructiveProtection(target) then
            pcall(fs.delete, target)
        end
        return false, "copy_failed:" .. tostring(err)
    end

    return true, target, bytes
end

function StorageManager:moveTo(source, destinationDir)
    source = normalize(source)
    destinationDir = normalize(destinationDir)
    if source == "/" then return false, "root_move_blocked" end
    if not fs.exists(source) then return false, "source_not_found" end

    self:refreshOwnership()
    local protection = self:destructiveProtection(source)
    if protection then return false, "source_protected:" .. tostring(protection) end

    local target, targetError = self:_destination(source, destinationDir)
    if not target then return false, targetError end

    local same, _, driveError = Storage.sameDrive({source, destinationDir})
    if not same then
        return false, "cross_drive_move_blocked:" .. tostring(driveError or "different_mounts")
    end

    local ok, err = pcall(fs.move, source, target)
    if not ok then return false, "move_failed:" .. tostring(err) end
    return true, target
end

function StorageManager:rename(path, newName)
    path = normalize(path)
    if path == "/" then return false, "root_rename_blocked" end
    if not validName(newName) then return false, "name_invalid" end
    if not fs.exists(path) then return false, "source_not_found" end

    self:refreshOwnership()
    local protection = self:destructiveProtection(path)
    if protection then return false, "source_protected:" .. tostring(protection) end

    local parent = normalize(fs.getDir(path))
    local target = normalize(fs.combine(parent, newName))
    if fs.exists(target) then return false, "destination_exists:" .. target end
    local targetProtection = self:exactProtection(target)
    if targetProtection then
        return false, "destination_protected:" .. tostring(targetProtection)
    end

    local ok, err = pcall(fs.move, path, target)
    if not ok then return false, "rename_failed:" .. tostring(err) end
    return true, target
end

function StorageManager:makeDir(parent, name)
    parent = normalize(parent)
    if not validName(name) then return false, "name_invalid" end
    if not fs.exists(parent) or not fs.isDir(parent) then
        return false, "parent_not_directory"
    end

    local target = normalize(fs.combine(parent, name))
    if fs.exists(target) then return false, "destination_exists:" .. target end
    local protection = self:exactProtection(target)
    if protection then
        return false, "destination_protected:" .. tostring(protection)
    end

    local readOnly = Storage.isReadOnly(parent)
    if readOnly == true then return false, "destination_read_only" end

    local ok, err = pcall(fs.makeDir, target)
    if not ok then return false, "mkdir_failed:" .. tostring(err) end
    return true, target
end

function StorageManager:delete(path)
    path = normalize(path)
    if path == "/" then return false, "root_delete_blocked" end
    if not fs.exists(path) then return false, "path_not_found" end

    self:refreshOwnership()

    local protection = self:destructiveProtectionDetails(path)
    if protection then
        return false,
            "path_protected:"
            .. tostring(protection.owner)
            .. ":"
            .. tostring(protection.target)
    end

    local readOnly = Storage.isReadOnly(path)
    if readOnly == true then
        return false, "path_read_only:" .. path
    end

    local parent = normalize(fs.getDir(path))
    local parentReadOnly = Storage.isReadOnly(parent)
    if parentReadOnly == true then
        return false, "parent_read_only:" .. parent
    end

    local called, result, detail = pcall(fs.delete, path)

    if not called then
        return false, "delete_failed:" .. tostring(result)
    end

    if result == false then
        return false, "delete_failed:" .. tostring(detail or "false_return")
    end

    if fs.exists(path) then
        return false, "delete_failed:path_still_exists:" .. path
    end

    return true
end

function StorageManager:readPreview(path, maxBytes)
    path = normalize(path)
    maxBytes = math.max(256, math.floor(tonumber(maxBytes) or 8192))
    if not fs.exists(path) or fs.isDir(path) then return nil, "not_file" end

    local file = fs.open(path, "r")
    if not file then return nil, "file_open_failed" end
    local raw = file.readAll()
    file.close()

    local truncated = #raw > maxBytes
    if truncated then raw = raw:sub(1, maxBytes) end

    local nonPrintable = 0
    for index = 1, #raw do
        local byte = raw:byte(index)
        if byte < 9 or (byte > 13 and byte < 32) then
            nonPrintable = nonPrintable + 1
        end
    end

    if #raw > 0 and nonPrintable / #raw > 0.08 then
        return nil, "binary_file"
    end

    raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    raw = raw:gsub("[^\t\n\032-\126]", "?")
    return raw, truncated
end

StorageManager.normalizePath = normalize
StorageManager.formatBytes = Storage.formatBytes

return StorageManager
