local Registry = {}

Registry.SCHEMA = 1
Registry.DEFAULT_PATH = "/data/system/packages.json"

local function nowMs()
    if os.epoch then
        return os.epoch("utc")
    end

    return math.floor(os.clock() * 1000)
end

local function ensureParent(path)
    local parent = fs.getDir(path)

    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

local function validId(value)
    return type(value) == "string"
        and value ~= ""
        and value:match("^[a-z0-9][a-z0-9%._%-]*$") ~= nil
end

local function validRelativePath(value)
    return type(value) == "string"
        and value ~= ""
        and value:sub(1, 1) ~= "/"
        and not value:find("..", 1, true)
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

    if not ok or type(value) ~= "table" then
        return nil
    end

    return value
end

local function normalizeFiles(files)
    local result = {}

    for _, item in ipairs(files or {}) do
        if type(item) == "table" and validRelativePath(item.target) then
            result[#result + 1] = {
                target = item.target,
                size = tonumber(item.size),
                hash = type(item.hash) == "string" and item.hash or nil
            }
        end
    end

    return result
end

function Registry.default()
    return {
        schema = Registry.SCHEMA,
        updatedAt = nowMs(),
        installed = {}
    }
end

function Registry.validate(value)
    if type(value) ~= "table" then
        return false, "package_registry_not_table"
    end

    if value.schema ~= Registry.SCHEMA then
        return false, "package_registry_schema_unsupported"
    end

    if type(value.installed) ~= "table" then
        return false, "package_registry_installed_missing"
    end

    for id, item in pairs(value.installed) do
        if not validId(id) or type(item) ~= "table" then
            return false, "package_registry_entry_invalid"
        end

        if type(item.version) ~= "string" or item.version == "" then
            return false, "package_registry_version_invalid:" .. tostring(id)
        end

        if item.sourceCommit ~= nil and type(item.sourceCommit) ~= "string" then
            return false, "package_registry_source_commit_invalid:" .. tostring(id)
        end

        if item.files ~= nil then
            if type(item.files) ~= "table" then
                return false, "package_registry_files_invalid:" .. tostring(id)
            end

            for index, file in ipairs(item.files) do
                if type(file) ~= "table" or not validRelativePath(file.target) then
                    return false,
                        "package_registry_file_invalid:"
                        .. tostring(id)
                        .. ":"
                        .. tostring(index)
                end

                if file.size ~= nil and (type(file.size) ~= "number" or file.size < 0) then
                    return false, "package_registry_file_size_invalid:" .. tostring(id)
                end

                if file.hash ~= nil and (type(file.hash) ~= "string" or file.hash == "") then
                    return false, "package_registry_file_hash_invalid:" .. tostring(id)
                end
            end
        end
    end

    return true
end

function Registry.load(path)
    path = path or Registry.DEFAULT_PATH

    local value = readJson(path)

    if value == nil then
        return Registry.default(), false
    end

    local valid, err = Registry.validate(value)

    if not valid then
        return nil, err
    end

    return value, true
end

function Registry.save(registry, path)
    path = path or Registry.DEFAULT_PATH

    local valid, err = Registry.validate(registry)

    if not valid then
        return false, err
    end

    registry.updatedAt = nowMs()
    ensureParent(path)

    local ok, raw = pcall(textutils.serializeJSON, registry)

    if not ok or type(raw) ~= "string" then
        return false, "package_registry_serialize_failed"
    end

    local temp = path .. ".tmp"
    local backup = path .. ".bak"

    if fs.exists(temp) then
        fs.delete(temp)
    end

    local file = fs.open(temp, "w")

    if not file then
        return false, "package_registry_temp_open_failed"
    end

    local writeOk, writeError = pcall(function()
        file.write(raw)
    end)

    pcall(function()
        file.close()
    end)

    if not writeOk then
        if fs.exists(temp) then
            fs.delete(temp)
        end

        return false, "package_registry_write_failed:" .. tostring(writeError)
    end

    local verify = readJson(temp)
    local verifyOk = verify and Registry.validate(verify)

    if not verifyOk then
        fs.delete(temp)
        return false, "package_registry_temp_validation_failed"
    end

    if fs.exists(backup) then
        fs.delete(backup)
    end

    if fs.exists(path) then
        fs.move(path, backup)
    end

    fs.move(temp, path)

    local committed = readJson(path)
    local committedOk = committed and Registry.validate(committed)

    if not committedOk then
        if fs.exists(path) then
            fs.delete(path)
        end

        if fs.exists(backup) then
            fs.move(backup, path)
        end

        return false, "package_registry_commit_validation_failed"
    end

    if fs.exists(backup) then
        fs.delete(backup)
    end

    return true
end

function Registry.get(registry, id)
    if type(registry) ~= "table" or type(registry.installed) ~= "table" then
        return nil
    end

    return registry.installed[id]
end

function Registry.isInstalled(registry, id)
    return Registry.get(registry, id) ~= nil
end

function Registry.setInstalled(registry, id, info)
    if type(registry) ~= "table" or type(registry.installed) ~= "table" then
        return false, "package_registry_invalid"
    end

    if not validId(id) then
        return false, "package_id_invalid"
    end

    if type(info) ~= "table" or type(info.version) ~= "string" or info.version == "" then
        return false, "package_registry_info_invalid"
    end

    local previous = registry.installed[id]
    local installedAt = previous and previous.installedAt or nowMs()

    registry.installed[id] = {
        version = info.version,
        source = tostring(info.source or "unknown"),
        managedBy = tostring(info.managedBy or "package"),
        mount = tostring(info.mount or "unknown"),
        sourceCommit = info.sourceCommit
            or (previous and previous.sourceCommit)
            or nil,
        files = normalizeFiles(
            info.files
            or (previous and previous.files)
            or {}
        ),
        installedAt = installedAt,
        updatedAt = nowMs()
    }

    return true
end

function Registry.removeInstalled(registry, id)
    if type(registry) ~= "table" or type(registry.installed) ~= "table" then
        return false, "package_registry_invalid"
    end

    registry.installed[id] = nil
    return true
end

function Registry.expectedFile(registry, id, target)
    local item = Registry.get(registry, id)

    if not item then
        return nil
    end

    for _, file in ipairs(item.files or {}) do
        if file.target == target then
            return file
        end
    end

    return nil
end

function Registry.listInstalled(registry)
    local result = {}

    if type(registry) ~= "table" or type(registry.installed) ~= "table" then
        return result
    end

    for id, item in pairs(registry.installed) do
        result[#result + 1] = {
            id = id,
            version = item.version,
            source = item.source,
            managedBy = item.managedBy,
            mount = item.mount,
            sourceCommit = item.sourceCommit,
            fileCount = #(item.files or {}),
            installedAt = item.installedAt,
            updatedAt = item.updatedAt
        }
    end

    table.sort(result, function(a, b)
        return a.id < b.id
    end)

    return result
end

return Registry
