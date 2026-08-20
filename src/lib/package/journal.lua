local Journal = {}

Journal.SCHEMA = 1
Journal.DEFAULT_PATH = "/data/system/package-journal.json"
Journal.CORE_UPDATE_JOURNAL = "/data/system/update-journal.json"

local function nowMs()
    if os.epoch then return os.epoch("utc") end
    return math.floor(os.clock() * 1000)
end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
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

local function validRelativePath(value)
    return type(value) == "string"
        and value ~= ""
        and value:sub(1, 1) ~= "/"
        and not value:find("..", 1, true)
end

local function validId(value)
    return type(value) == "string"
        and value ~= ""
        and value:match("^[a-z0-9][a-z0-9%._%-]*$") ~= nil
end

local function coreUpdatePending()
    local base = Journal.CORE_UPDATE_JOURNAL
    return fs.exists(base) or fs.exists(base .. ".bak") or fs.exists(base .. ".tmp")
end

function Journal.validate(value)
    if type(value) ~= "table" or value.schema ~= Journal.SCHEMA then
        return false, "package_journal_schema_invalid"
    end
    if value.operation ~= "install"
        and value.operation ~= "update"
        and value.operation ~= "remove"
        and value.operation ~= "repair"
    then
        return false, "package_journal_operation_invalid"
    end
    if not validId(value.packageId) then return false, "package_journal_package_invalid" end
    if type(value.version) ~= "string" or value.version == "" then
        return false, "package_journal_version_invalid"
    end
    if value.transactionId ~= nil and (type(value.transactionId) ~= "string" or value.transactionId == "") then
        return false, "package_journal_transaction_invalid"
    end
    if value.operation ~= "remove"
        and (type(value.sourceCommit) ~= "string" or value.sourceCommit == "")
    then
        return false, "package_journal_source_commit_invalid"
    end
    if type(value.files) ~= "table" or type(value.removeFiles) ~= "table" then
        return false, "package_journal_files_invalid"
    end

    local targets = {}

    for index, item in ipairs(value.files) do
        if type(item) ~= "table"
            or not validRelativePath(item.source)
            or not validRelativePath(item.target)
            or type(item.hash) ~= "string"
            or item.hash == ""
            or type(item.size) ~= "number"
            or item.size < 0
        then
            return false, "package_journal_file_invalid:" .. tostring(index)
        end
        if item.state ~= "pending" and item.state ~= "done" then
            return false, "package_journal_file_state_invalid:" .. tostring(index)
        end
        if item.oldHash ~= nil and (type(item.oldHash) ~= "string" or item.oldHash == "") then
            return false, "package_journal_old_hash_invalid:" .. tostring(index)
        end
        if targets[item.target] then
            return false, "package_journal_duplicate_target:" .. item.target
        end
        targets[item.target] = "write"
    end

    for index, item in ipairs(value.removeFiles) do
        if type(item) ~= "table" or not validRelativePath(item.target) then
            return false, "package_journal_remove_invalid:" .. tostring(index)
        end
        if item.state ~= "pending" and item.state ~= "done" then
            return false, "package_journal_remove_state_invalid:" .. tostring(index)
        end
        if targets[item.target] then
            return false, "package_journal_target_collision:" .. item.target
        end
        targets[item.target] = "remove"
    end

    return true
end

local function validCandidate(path)
    local value = readJson(path)
    if not value then return nil end
    local valid = Journal.validate(value)
    if not valid then return nil end
    return value
end

function Journal.load(path)
    path = path or Journal.DEFAULT_PATH
    local candidates = {path, path .. ".bak", path .. ".tmp"}

    for _, candidate in ipairs(candidates) do
        local value = validCandidate(candidate)
        if value then return value, true end
    end

    if fs.exists(path) or fs.exists(path .. ".bak") or fs.exists(path .. ".tmp") then
        return nil, "package_journal_unreadable"
    end
    return nil, false
end

function Journal.save(value, path)
    path = path or Journal.DEFAULT_PATH
    if coreUpdatePending() then return false, "core_update_pending" end

    local valid, err = Journal.validate(value)
    if not valid then return false, err end

    value.updatedAt = nowMs()
    ensureParent(path)

    local ok, raw = pcall(textutils.serializeJSON, value)
    if not ok or type(raw) ~= "string" then return false, "package_journal_serialize_failed" end

    local temp = path .. ".tmp"
    local backup = path .. ".bak"
    if fs.exists(temp) then pcall(fs.delete, temp) end

    local file = fs.open(temp, "w")
    if not file then return false, "package_journal_temp_open_failed" end
    local writeOk, writeError = pcall(function() file.write(raw) end)
    pcall(function() file.close() end)
    if not writeOk then
        if fs.exists(temp) then pcall(fs.delete, temp) end
        return false, "package_journal_write_failed:" .. tostring(writeError)
    end

    local verify = readJson(temp)
    local verifyOk = verify and Journal.validate(verify)
    if not verifyOk then
        pcall(fs.delete, temp)
        return false, "package_journal_temp_validation_failed"
    end

    if fs.exists(backup) then pcall(fs.delete, backup) end
    if fs.exists(path) then
        local moved, moveError = pcall(fs.move, path, backup)
        if not moved then return false, "package_journal_backup_failed:" .. tostring(moveError) end
    end

    local committed, commitError = pcall(fs.move, temp, path)
    if not committed then
        if fs.exists(backup) and not fs.exists(path) then pcall(fs.move, backup, path) end
        return false, "package_journal_commit_move_failed:" .. tostring(commitError)
    end

    local final = readJson(path)
    local finalOk = final and Journal.validate(final)
    if not finalOk then
        if fs.exists(path) then pcall(fs.delete, path) end
        if fs.exists(backup) then pcall(fs.move, backup, path) end
        return false, "package_journal_commit_validation_failed"
    end

    if fs.exists(backup) then pcall(fs.delete, backup) end
    return true
end

function Journal.create(operation, packageItem, sourceCommit, files, removeFiles)
    return {
        schema = Journal.SCHEMA,
        transactionId = tostring(nowMs()) .. "-" .. tostring(os.getComputerID()),
        operation = operation,
        packageId = packageItem.id,
        version = packageItem.version,
        sourceCommit = sourceCommit,
        createdAt = nowMs(),
        updatedAt = nowMs(),
        files = files or {},
        removeFiles = removeFiles or {}
    }
end

function Journal.clear(path)
    path = path or Journal.DEFAULT_PATH
    for _, candidate in ipairs({path, path .. ".bak", path .. ".tmp"}) do
        if fs.exists(candidate) then
            local ok, err = pcall(fs.delete, candidate)
            if not ok then return false, "package_journal_delete_failed:" .. tostring(err) end
        end
    end
    return true
end

function Journal.progress(value)
    local done, total = 0, 0
    for _, item in ipairs(value and value.files or {}) do
        total = total + 1
        if item.state == "done" then done = done + 1 end
    end
    for _, item in ipairs(value and value.removeFiles or {}) do
        total = total + 1
        if item.state == "done" then done = done + 1 end
    end
    return done, total
end

return Journal
