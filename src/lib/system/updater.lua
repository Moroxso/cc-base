local Core = require("lib.system.updater_core")
local Hash = require("lib.package.hash")

local Updater = {}

local VERSION_FILE = "/.project-version"
local MANIFEST_FILE = "/deploy.json"
local JOURNAL_FILE = "/data/system/update-journal.json"
local PACKAGE_JOURNAL = "/data/system/package-journal.json"
local HISTORY_FILE = "/data/system/update-history.json"
local HISTORY_SCHEMA = 1
local HISTORY_LIMIT = 8

local STALE_ARTIFACTS = {
    "/.cc_update_stage",
    "/.cc_updater_next.lua",
    "/.cc_updater_prev.lua",
    JOURNAL_FILE .. ".tmp",
    JOURNAL_FILE .. ".bak",
    HISTORY_FILE .. ".tmp",
    HISTORY_FILE .. ".bak"
}

local function nowMs()
    if os.epoch then return os.epoch("utc") end
    return math.floor(os.clock() * 1000)
end

local function readAll(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local content = file.readAll()
    file.close()
    return content
end

local function readJson(path)
    local raw = readAll(path)
    if not raw or raw == "" then return nil end
    local ok, value = pcall(textutils.unserializeJSON, raw)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
end

local function writeRaw(path, content)
    ensureParent(path)
    local file, openError = fs.open(path, "w")
    if not file then return false, "open_failed:" .. tostring(openError) end
    local ok, err = pcall(function() file.write(content) end)
    pcall(function() file.close() end)
    if not ok then return false, "write_failed:" .. tostring(err) end
    return true
end

local function writeAtomicJson(path, value)
    local ok, raw = pcall(textutils.serializeJSON, value)
    if not ok or type(raw) ~= "string" then return false, "json_serialize_failed" end

    ensureParent(path)
    local temp = path .. ".tmp"
    local backup = path .. ".bak"
    if fs.exists(temp) then pcall(fs.delete, temp) end

    local wrote, writeError = writeRaw(temp, raw)
    if not wrote then return false, writeError end
    if type(readJson(temp)) ~= "table" then
        pcall(fs.delete, temp)
        return false, "json_temp_validation_failed"
    end

    if fs.exists(backup) then pcall(fs.delete, backup) end
    if fs.exists(path) then fs.move(path, backup) end
    fs.move(temp, path)

    if type(readJson(path)) ~= "table" then
        if fs.exists(path) then pcall(fs.delete, path) end
        if fs.exists(backup) then fs.move(backup, path) end
        return false, "json_commit_validation_failed"
    end

    if fs.exists(backup) then pcall(fs.delete, backup) end
    return true
end

local function formatBytes(value)
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

local function freeSpace()
    if type(fs.getFreeSpace) ~= "function" then return nil end
    local ok, value = pcall(fs.getFreeSpace, "/")
    if not ok then return nil end
    if value == "unlimited" then return math.huge end
    return tonumber(value)
end

local function capacity()
    if type(fs.getCapacity) ~= "function" then return nil end
    local ok, value = pcall(fs.getCapacity, "/")
    if not ok then return nil end
    return tonumber(value)
end

local function loadHistory()
    local value = readJson(HISTORY_FILE)
    if type(value) ~= "table" or value.schema ~= HISTORY_SCHEMA or type(value.entries) ~= "table" then
        return {schema = HISTORY_SCHEMA, entries = {}}
    end

    local entries = {}
    for _, entry in ipairs(value.entries) do
        if type(entry) == "table" then entries[#entries + 1] = entry end
    end
    while #entries > HISTORY_LIMIT do table.remove(entries, 1) end
    return {schema = HISTORY_SCHEMA, entries = entries}
end

local function appendHistory(entry)
    entry = type(entry) == "table" and entry or {}
    entry.at = nowMs()
    local history = loadHistory()
    history.entries[#history.entries + 1] = entry
    while #history.entries > HISTORY_LIMIT do table.remove(history.entries, 1) end
    return writeAtomicJson(HISTORY_FILE, history)
end

local function journalProgress(journal)
    local done, total = 0, 0
    for _, item in ipairs(journal and journal.files or {}) do
        total = total + 1
        if item.state == "done" then done = done + 1 end
    end
    for _, item in ipairs(journal and journal.removeFiles or {}) do
        total = total + 1
        if item.state == "done" then done = done + 1 end
    end
    return done, total
end

local function manifestIndex(manifest)
    local result = {}
    for _, item in ipairs(manifest and manifest.files or {}) do
        result[item.target] = item
    end
    return result
end

local function manifestDiff(before, after)
    local old = manifestIndex(before)
    local changed = 0
    for _, item in ipairs(after and after.files or {}) do
        if item.control ~= "manifest" then
            local previous = old[item.target]
            if not previous or previous.hash ~= item.hash or previous.size ~= item.size then
                changed = changed + 1
            end
        end
    end
    return changed, #(after and after.remove or {})
end

local function recordCompletion(beforeVersion, beforeManifest, pending, command)
    local afterVersion = readAll(VERSION_FILE) or "unknown"
    local afterManifest = readJson(MANIFEST_FILE)
    if type(afterManifest) ~= "table" then return false, "history_manifest_unavailable" end

    local changed, removals = manifestDiff(beforeManifest, afterManifest)
    local recoveryAttempts = pending and tonumber(pending.recoveryAttempts) or 0
    local diagnostic = pending and pending.diagnostic == true or false

    return appendHistory({
        kind = diagnostic and "diagnostic-recovery"
            or (pending and "recovery" or "update"),
        command = command or "update",
        transactionId = pending and pending.transactionId or nil,
        fromVersion = pending and pending.fromVersion or beforeVersion,
        targetVersion = afterVersion,
        sourceCommit = afterManifest.sourceCommit,
        changed = pending and tonumber(pending.changedCount) or changed,
        removals = pending and tonumber(pending.removalCount) or removals,
        recoveryAttempts = recoveryAttempts,
        diagnostic = diagnostic
    })
end

local function incrementRecoveryAttempt(journal)
    if type(journal) ~= "table" then return journal end
    journal.recoveryAttempts = (tonumber(journal.recoveryAttempts) or 0) + 1
    journal.updatedAt = nowMs()
    local ok = writeAtomicJson(JOURNAL_FILE, journal)
    if not ok then return journal end
    return readJson(JOURNAL_FILE) or journal
end

local function staleCount()
    local count = 0
    for _, path in ipairs(STALE_ARTIFACTS) do
        if fs.exists(path) then count = count + 1 end
    end
    return count
end

local function printStatus()
    local version = readAll(VERSION_FILE) or "unknown"
    local manifest = readJson(MANIFEST_FILE)
    local journal = readJson(JOURNAL_FILE)
    local history = loadHistory()

    print("CORE UPDATE STATUS")
    print("Installed version: " .. version)
    print("Manifest schema: " .. tostring(manifest and manifest.schema or "unknown"))
    print("Source commit: " .. tostring(manifest and manifest.sourceCommit or "unknown"):sub(1, 12))
    print("Capacity: " .. formatBytes(capacity()))
    print("Free: " .. formatBytes(freeSpace()))
    print("Package transaction: " .. (fs.exists(PACKAGE_JOURNAL) and "pending" or "none"))

    if journal then
        local done, total = journalProgress(journal)
        print("Core transaction: pending " .. done .. "/" .. total)
        print("Target: " .. tostring(journal.targetVersion or "unknown"))
        print("Transaction: " .. tostring(journal.transactionId or "unknown"))
        print("Recovery attempts: " .. tostring(journal.recoveryAttempts or 0))
        print("Diagnostic: " .. (journal.diagnostic == true and "yes" or "no"))
    else
        print("Core transaction: none")
    end

    print("History entries: " .. tostring(#history.entries))
    if #history.entries > 0 then
        local last = history.entries[#history.entries]
        print("Last: " .. tostring(last.kind or "update") .. " -> " .. tostring(last.targetVersion or "unknown"))
    end
    print("Stale artifacts: " .. tostring(staleCount()))
    return true
end

local function printHistory()
    local history = loadHistory()
    print("CORE UPDATE HISTORY")
    if #history.entries == 0 then
        print("No completed update transactions recorded.")
        return true
    end

    for index = #history.entries, 1, -1 do
        local entry = history.entries[index]
        local commit = tostring(entry.sourceCommit or "unknown")
        print(tostring(index) .. ". " .. tostring(entry.kind or "update")
            .. " " .. tostring(entry.fromVersion or "?") .. " -> " .. tostring(entry.targetVersion or "?"))
        print("   commit=" .. commit:sub(1, 12)
            .. " changed=" .. tostring(entry.changed or 0)
            .. " removed=" .. tostring(entry.removals or 0)
            .. " recoveries=" .. tostring(entry.recoveryAttempts or 0))
    end
    return true
end

local function cleanupArtifacts()
    if fs.exists(JOURNAL_FILE) then return false, "core_transaction_pending_run_update_recover" end
    if fs.exists(PACKAGE_JOURNAL) then return false, "package_transaction_pending_run_pkg_recover" end

    local removed = 0
    for _, path in ipairs(STALE_ARTIFACTS) do
        if fs.exists(path) then
            local ok = pcall(fs.delete, path)
            if ok and not fs.exists(path) then removed = removed + 1 end
        end
    end
    print("CORE UPDATE CLEANUP")
    print("Removed artifacts: " .. tostring(removed))
    return true
end

local function validManifest(manifest)
    return type(manifest) == "table"
        and manifest.schema == 2
        and type(manifest.version) == "string"
        and type(manifest.sourceCommit) == "string"
        and type(manifest.files) == "table"
end

local function entryMatches(item)
    if type(item) ~= "table" or type(item.target) ~= "string"
        or type(item.size) ~= "number" or type(item.hash) ~= "string" then
        return false
    end
    local path = "/" .. item.target:gsub("^/+", "")
    local content = readAll(path)
    if not content or #content ~= item.size then return false end
    local hash = Hash.gitBlob(content)
    return type(hash) == "string" and string.lower(hash) == string.lower(item.hash)
end

local function diagnosticRecoveryTest()
    if fs.exists(PACKAGE_JOURNAL) then return false, "package_transaction_pending_run_pkg_recover" end
    if fs.exists(JOURNAL_FILE) then return false, "core_transaction_already_pending" end

    local manifestRaw = readAll(MANIFEST_FILE)
    local manifest = manifestRaw and textutils.unserializeJSON(manifestRaw) or nil
    if not validManifest(manifest) then return false, "local_manifest_invalid" end

    local candidates = {}
    for _, item in ipairs(manifest.files) do
        if item.control ~= "manifest" and not item.bootstrapProtected and not item.selfEngine and entryMatches(item) then
            candidates[#candidates + 1] = item
        end
    end
    table.sort(candidates, function(a, b)
        if a.size == b.size then return a.target < b.target end
        return a.size < b.size
    end)
    if #candidates < 2 then return false, "diagnostic_requires_two_verified_core_files" end

    local files = {}
    for index = 1, 2 do
        local item = candidates[index]
        files[index] = {
            source = item.source,
            target = item.target,
            size = item.size,
            hash = item.hash,
            state = index == 1 and "done" or "pending",
            oldSize = item.size,
            selfEngine = false
        }
    end

    local version = readAll(VERSION_FILE) or manifest.version
    local journal = {
        schema = 1,
        operation = "core-update",
        transactionId = "diag-" .. tostring(nowMs()) .. "-" .. tostring(os.getComputerID()),
        fromVersion = version,
        targetVersion = manifest.version,
        sourceCommit = manifest.sourceCommit,
        hashAlgorithm = manifest.hashAlgorithm,
        manifestRaw = manifestRaw,
        createdAt = nowMs(),
        updatedAt = nowMs(),
        changedCount = 0,
        removalCount = 0,
        netGrowth = 0,
        recoveryAttempts = 0,
        diagnostic = true,
        files = files,
        removeFiles = {}
    }

    local saved, saveError = writeAtomicJson(JOURNAL_FILE, journal)
    if not saved then return false, "diagnostic_journal_create_failed:" .. tostring(saveError) end

    print("CORE UPDATE RECOVERY TEST")
    print("Transaction: " .. journal.transactionId)
    print("Checkpoint: 1/2")
    print("No system payload was modified.")
    print("Reboot now. startup.lua should complete recovery automatically.")
    return true
end

local function runCore(args, command)
    local beforeVersion = readAll(VERSION_FILE) or "unknown"
    local beforeManifest = readJson(MANIFEST_FILE)
    local pending = readJson(JOURNAL_FILE)

    if pending then pending = incrementRecoveryAttempt(pending) end

    local ok, result = xpcall(function()
        return Core.main(args)
    end, function(message)
        return tostring(message)
    end)

    if not ok then error(result, 0) end

    if not fs.exists(JOURNAL_FILE) then
        local afterVersion = readAll(VERSION_FILE) or "unknown"
        local afterManifest = readJson(MANIFEST_FILE)
        local changed = afterVersion ~= beforeVersion
            or (beforeManifest and afterManifest and beforeManifest.sourceCommit ~= afterManifest.sourceCommit)
        if pending or changed then
            local historyOk, historyError = recordCompletion(beforeVersion, beforeManifest, pending, command)
            if not historyOk then print("WARNING history:" .. tostring(historyError)) end
        end
    end

    return result
end

local function runWithDiagnosticPause(args, count)
    if type(http) ~= "table" or type(http.get) ~= "function" then
        error("http_unavailable", 0)
    end

    local originalGet = http.get
    local payloadRequests = 0
    local tripped = false

    http.get = function(url, ...)
        local text = tostring(url or "")
        local isPayload = text:find("raw.githubusercontent.com/Moroxso/cc-base/", 1, true) ~= nil
            and text:find("/refs/heads/main/deploy.json", 1, true) == nil
        if isPayload then
            payloadRequests = payloadRequests + 1
            if payloadRequests > count then
                tripped = true
                return nil, "diagnostic_pause_after:" .. tostring(count)
            end
        end
        return originalGet(url, ...)
    end

    local ok, result = pcall(function() return runCore({}, "diagnostic-pause") end)
    http.get = originalGet

    if not ok then
        if tripped and fs.exists(JOURNAL_FILE) then
            print("")
            print("CORE UPDATE DIAGNOSTIC PAUSE")
            print("Payload downloads completed: " .. tostring(count))
            print("Journal preserved. Run 'update --recover' or reboot.")
            return true
        end
        error(result, 0)
    end

    if not tripped then
        print("Diagnostic pause was not reached; update completed or had too few changed payload files.")
    end
    return result
end

local function printHelp()
    print("Usage: update [command]")
    print("  --plan")
    print("  --recover")
    print("  --status")
    print("  --history")
    print("  --cleanup")
    print("  --test-recovery")
    print("  --pause-after <count>  (diagnostic)")
end

function Updater.main(args)
    args = type(args) == "table" and args or {}
    local command = args[1]

    if command == "--status" or command == "status" then
        return printStatus()
    elseif command == "--history" or command == "history" then
        return printHistory()
    elseif command == "--cleanup" or command == "cleanup" then
        local ok, err = cleanupArtifacts()
        if not ok then error(err, 0) end
        return true
    elseif command == "--test-recovery" or command == "test-recovery" then
        local ok, err = diagnosticRecoveryTest()
        if not ok then error(err, 0) end
        return true
    elseif command == "--pause-after" or command == "pause-after" then
        local count = tonumber(args[2])
        if not count or count < 1 or count ~= math.floor(count) then
            error("Usage: update --pause-after <positive-integer>", 0)
        end
        return runWithDiagnosticPause(args, count)
    elseif command == "--help" or command == "help" or command == "-h" then
        printHelp()
        return true
    end

    return runCore(args, command or "update")
end

return Updater
