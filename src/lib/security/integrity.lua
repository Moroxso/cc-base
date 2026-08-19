local Integrity = {}

Integrity.VERSION = 1
Integrity.MANIFEST_PATH = "/deploy.json"
Integrity.VERSION_PATH = "/.project-version"
Integrity.BASELINE_PATH = "/data/security/integrity.json"
Integrity.STATUS_PATH = "/data/security/status.json"
Integrity.LOG_PATH = "/data/security/integrity_log.json"
Integrity.QUARANTINE_DIR = "/data/security/quarantine"
Integrity.MAX_LOG_ENTRIES = 64

local PROTECTED_ROOTS = {
    "/startup.lua",
    "/main.lua",
    "/update.lua",
    "/deploy.json",
    "/lib",
    "/apps",
    "/games"
}

local function nowMs()
    if os.epoch then
        return os.epoch("utc")
    end

    return math.floor(os.clock() * 1000)
end

local function ensureParent(path)
    local dir = fs.getDir(path)

    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function readAll(path)
    if not fs.exists(path) or fs.isDir(path) then
        return nil
    end

    local file = fs.open(path, "r")

    if not file then
        return nil
    end

    local content = file.readAll()
    file.close()
    return content
end

local function readJson(path)
    local raw = readAll(path)

    if not raw or raw == "" then
        return nil
    end

    local ok, value = pcall(textutils.unserializeJSON, raw)

    if not ok or type(value) ~= "table" then
        return nil
    end

    return value
end

local function writeAtomic(path, data)
    ensureParent(path)

    local ok, raw = pcall(textutils.serializeJSON, data)

    if not ok or type(raw) ~= "string" then
        return false, "security_serialize_failed"
    end

    local temp = path .. ".tmp"
    local backup = path .. ".bak"

    if fs.exists(temp) then fs.delete(temp) end

    local file = fs.open(temp, "w")

    if not file then
        return false, "security_temp_open_failed"
    end

    file.write(raw)
    file.close()

    if not readJson(temp) then
        fs.delete(temp)
        return false, "security_temp_validation_failed"
    end

    if fs.exists(backup) then fs.delete(backup) end
    if fs.exists(path) then fs.move(path, backup) end
    fs.move(temp, path)

    if not readJson(path) then
        if fs.exists(path) then fs.delete(path) end
        if fs.exists(backup) then fs.move(backup, path) end
        return false, "security_commit_validation_failed"
    end

    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function hashString(content)
    local hash = 5381

    for index = 1, #content do
        hash = (hash * 33 + string.byte(content, index)) % 4294967296
    end

    return string.format("%08x", hash)
end

function Integrity.hashFile(path)
    local content = readAll(path)

    if content == nil then
        return nil, "file_unreadable"
    end

    return hashString(content), #content
end

local function normalizeTarget(target)
    if type(target) ~= "string" or target == "" then
        return nil
    end

    if target:sub(1, 1) == "/" or target:find("..", 1, true) then
        return nil
    end

    return "/" .. target
end

local function loadManifest()
    local manifest = readJson(Integrity.MANIFEST_PATH)

    if type(manifest) ~= "table" or type(manifest.files) ~= "table" then
        return nil, "security_manifest_missing"
    end

    return manifest
end

local function currentVersion()
    local value = readAll(Integrity.VERSION_PATH)
    return value and value ~= "" and value or "unknown"
end

local function buildBaselineFromManifest(manifest)
    local files = {}
    local seen = {}

    for _, item in ipairs(manifest.files or {}) do
        local path = normalizeTarget(item.target)

        if path and not seen[path] then
            local hash, size = Integrity.hashFile(path)

            if hash then
                table.insert(files, {
                    path = path,
                    hash = hash,
                    size = size
                })
                seen[path] = true
            end
        end
    end

    if fs.exists(Integrity.VERSION_PATH) and not seen[Integrity.VERSION_PATH] then
        local hash, size = Integrity.hashFile(Integrity.VERSION_PATH)

        if hash then
            table.insert(files, {
                path = Integrity.VERSION_PATH,
                hash = hash,
                size = size
            })
        end
    end

    table.sort(files, function(a, b)
        return a.path < b.path
    end)

    return {
        version = Integrity.VERSION,
        projectVersion = tostring(manifest.version or currentVersion()),
        createdAt = nowMs(),
        algorithm = "djb2-32",
        files = files
    }
end

function Integrity.createBaseline()
    local manifest, err = loadManifest()

    if not manifest then
        return nil, err
    end

    local baseline = buildBaselineFromManifest(manifest)

    if #baseline.files == 0 then
        return nil, "security_baseline_empty"
    end

    local ok, saveErr = writeAtomic(Integrity.BASELINE_PATH, baseline)

    if not ok then
        return nil, saveErr
    end

    return baseline
end

function Integrity.loadBaseline()
    local baseline = readJson(Integrity.BASELINE_PATH)

    if type(baseline) ~= "table" or
        baseline.version ~= Integrity.VERSION or
        type(baseline.files) ~= "table"
    then
        return nil
    end

    return baseline
end

function Integrity.ensureBaseline()
    local baseline = Integrity.loadBaseline()

    if baseline then
        return baseline, false
    end

    baseline = Integrity.createBaseline()
    return baseline, baseline ~= nil
end

local function collectFiles(path, output)
    if not fs.exists(path) then
        return
    end

    if not fs.isDir(path) then
        output[path] = true
        return
    end

    for _, name in ipairs(fs.list(path)) do
        collectFiles(fs.combine(path, name), output)
    end
end

local function collectProtectedFiles()
    local result = {}

    for _, root in ipairs(PROTECTED_ROOTS) do
        collectFiles(root, result)
    end

    result[Integrity.VERSION_PATH] = fs.exists(Integrity.VERSION_PATH) or nil
    return result
end

local function issue(kind, path, expected, actual)
    return {
        kind = kind,
        path = path,
        expected = expected,
        actual = actual
    }
end

function Integrity.scan()
    local baseline, created = Integrity.ensureBaseline()

    if not baseline then
        return {
            ok = false,
            baselineCreated = false,
            scannedAt = nowMs(),
            projectVersion = currentVersion(),
            protectedCount = 0,
            issues = {
                issue("baseline_missing", Integrity.BASELINE_PATH, "present", "missing")
            }
        }
    end

    local issues = {}
    local expected = {}

    for _, entry in ipairs(baseline.files) do
        expected[entry.path] = true

        if not fs.exists(entry.path) then
            table.insert(issues, issue("missing", entry.path, entry.hash, "missing"))
        elseif fs.isDir(entry.path) then
            table.insert(issues, issue("type_changed", entry.path, "file", "directory"))
        else
            local hash, size = Integrity.hashFile(entry.path)

            if not hash then
                table.insert(issues, issue("unreadable", entry.path, entry.hash, "unreadable"))
            elseif hash ~= entry.hash or size ~= entry.size then
                table.insert(issues, issue("modified", entry.path, entry.hash, hash))
            end
        end
    end

    local current = collectProtectedFiles()

    for path in pairs(current) do
        if not expected[path] then
            table.insert(issues, issue("unexpected", path, "not_present", "present"))
        end
    end

    table.sort(issues, function(a, b)
        if a.kind ~= b.kind then
            return a.kind < b.kind
        end

        return a.path < b.path
    end)

    return {
        ok = #issues == 0,
        baselineCreated = created == true,
        scannedAt = nowMs(),
        projectVersion = currentVersion(),
        baselineVersion = baseline.projectVersion or "unknown",
        protectedCount = #baseline.files,
        issues = issues
    }
end

function Integrity.writeStatus(status)
    return writeAtomic(Integrity.STATUS_PATH, status)
end

function Integrity.loadStatus()
    return readJson(Integrity.STATUS_PATH)
end

function Integrity.loadLog()
    local log = readJson(Integrity.LOG_PATH)
    return type(log) == "table" and log or {}
end

function Integrity.appendLog(status)
    if not status or status.ok then
        return true
    end

    local log = Integrity.loadLog()
    local signatureParts = {}

    for _, item in ipairs(status.issues or {}) do
        table.insert(signatureParts, tostring(item.kind) .. ":" .. tostring(item.path))
    end

    local signature = table.concat(signatureParts, "|")
    local last = log[#log]

    if last and last.signature == signature then
        return true
    end

    table.insert(log, {
        at = nowMs(),
        projectVersion = status.projectVersion,
        signature = signature,
        issues = status.issues
    })

    while #log > Integrity.MAX_LOG_ENTRIES do
        table.remove(log, 1)
    end

    return writeAtomic(Integrity.LOG_PATH, log)
end

function Integrity.clearLog()
    return writeAtomic(Integrity.LOG_PATH, {})
end

local function sanitizeName(name)
    name = tostring(name or "payload")
    name = name:gsub("[^%w%._%-]", "_")

    if name == "" then
        name = "payload"
    end

    return name:sub(1, 48)
end

function Integrity.quarantineContent(name, content, metadata)
    if type(content) ~= "string" then
        return nil, "quarantine_content_must_be_string"
    end

    if not fs.exists(Integrity.QUARANTINE_DIR) then
        fs.makeDir(Integrity.QUARANTINE_DIR)
    end

    local id = string.format("%d-%d-%s", nowMs(), os.getComputerID(), sanitizeName(name))
    local dataPath = fs.combine(Integrity.QUARANTINE_DIR, id .. ".bin")
    local metaPath = fs.combine(Integrity.QUARANTINE_DIR, id .. ".json")

    local file = fs.open(dataPath, "w")

    if not file then
        return nil, "quarantine_write_failed"
    end

    file.write(content)
    file.close()

    local meta = type(metadata) == "table" and metadata or {}
    meta.id = id
    meta.originalName = tostring(name or "payload")
    meta.size = #content
    meta.hash = hashString(content)
    meta.createdAt = nowMs()
    meta.executable = false
    meta.autoRun = false

    local ok, err = writeAtomic(metaPath, meta)

    if not ok then
        fs.delete(dataPath)
        return nil, err
    end

    return id, dataPath
end

function Integrity.quarantineUnexpected(path)
    local status = Integrity.scan()
    local allowed = false

    for _, item in ipairs(status.issues or {}) do
        if item.kind == "unexpected" and item.path == path then
            allowed = true
            break
        end
    end

    if not allowed then
        return false, "quarantine_only_unexpected_files"
    end

    local content = readAll(path)

    if content == nil then
        return false, "quarantine_source_unreadable"
    end

    local id, err = Integrity.quarantineContent(fs.getName(path), content, {
        sourcePath = path,
        reason = "unexpected_protected_file"
    })

    if not id then
        return false, err
    end

    fs.delete(path)
    return true, id
end

function Integrity.quarantineCount()
    if not fs.exists(Integrity.QUARANTINE_DIR) then
        return 0
    end

    local count = 0

    for _, name in ipairs(fs.list(Integrity.QUARANTINE_DIR)) do
        if name:sub(-5) == ".json" then
            count = count + 1
        end
    end

    return count
end

return Integrity
