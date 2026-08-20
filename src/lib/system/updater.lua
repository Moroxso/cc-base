local Updater = {}

Updater.MANIFEST_SCHEMA = 2
Updater.JOURNAL_SCHEMA = 1
Updater.OWNER = "Moroxso"
Updater.REPO = "cc-base"
Updater.BRANCH = "main"
Updater.VERSION_FILE = "/.project-version"
Updater.MANIFEST_FILE = "/deploy.json"
Updater.JOURNAL_FILE = "/data/system/update-journal.json"
Updater.PACKAGE_JOURNAL = "/data/system/package-journal.json"
Updater.LEGACY_STAGE = "/.cc_update_stage"
Updater.ENGINE_PATH = "/lib/system/updater.lua"
Updater.ENGINE_NEXT = "/.cc_updater_next.lua"
Updater.ENGINE_PREV = "/.cc_updater_prev.lua"
Updater.SPACE_RESERVE = 8192

local LIVE_BASE = "https://raw.githubusercontent.com/"
    .. Updater.OWNER .. "/" .. Updater.REPO .. "/refs/heads/" .. Updater.BRANCH .. "/"
local MANIFEST_URL = LIVE_BASE .. "deploy.json"

local bit = bit32

local function nowMs()
    if os.epoch then
        return os.epoch("utc")
    end

    return math.floor(os.clock() * 1000)
end

local function add32(...)
    local total = 0

    for index = 1, select("#", ...) do
        total = (total + (select(index, ...))) % 4294967296
    end

    return total
end

local function wordToBytes(value)
    return string.char(
        bit.band(bit.rshift(value, 24), 0xff),
        bit.band(bit.rshift(value, 16), 0xff),
        bit.band(bit.rshift(value, 8), 0xff),
        bit.band(value, 0xff)
    )
end

local function sha1(content)
    if type(bit) ~= "table" then
        return nil, "bit32_unavailable"
    end

    local bitLength = #content * 8
    local highLength = math.floor(bitLength / 4294967296)
    local lowLength = bitLength % 4294967296
    local message = content .. string.char(0x80)
    local padding = (56 - (#message % 64)) % 64
    message = message .. string.rep("\0", padding)
    message = message .. wordToBytes(highLength) .. wordToBytes(lowLength)

    local h0 = 0x67452301
    local h1 = 0xefcdab89
    local h2 = 0x98badcfe
    local h3 = 0x10325476
    local h4 = 0xc3d2e1f0
    local words = {}

    for chunkStart = 1, #message, 64 do
        for index = 0, 15 do
            local offset = chunkStart + index * 4
            local a, b, c, d = string.byte(message, offset, offset + 3)

            words[index] = bit.bor(
                bit.lshift(a, 24),
                bit.lshift(b, 16),
                bit.lshift(c, 8),
                d
            )
        end

        for index = 16, 79 do
            words[index] = bit.lrotate(
                bit.bxor(
                    words[index - 3],
                    words[index - 8],
                    words[index - 14],
                    words[index - 16]
                ),
                1
            )
        end

        local a = h0
        local b = h1
        local c = h2
        local d = h3
        local e = h4

        for index = 0, 79 do
            local roundFunction
            local constant

            if index <= 19 then
                roundFunction = bit.bor(
                    bit.band(b, c),
                    bit.band(bit.bnot(b), d)
                )
                constant = 0x5a827999
            elseif index <= 39 then
                roundFunction = bit.bxor(b, c, d)
                constant = 0x6ed9eba1
            elseif index <= 59 then
                roundFunction = bit.bor(
                    bit.band(b, c),
                    bit.band(b, d),
                    bit.band(c, d)
                )
                constant = 0x8f1bbcdc
            else
                roundFunction = bit.bxor(b, c, d)
                constant = 0xca62c1d6
            end

            local temp = add32(
                bit.lrotate(a, 5),
                roundFunction,
                e,
                constant,
                words[index]
            )

            e = d
            d = c
            c = bit.lrotate(b, 30)
            b = a
            a = temp
        end

        h0 = add32(h0, a)
        h1 = add32(h1, b)
        h2 = add32(h2, c)
        h3 = add32(h3, d)
        h4 = add32(h4, e)
    end

    return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

local function gitBlob(content)
    return sha1("blob " .. tostring(#content) .. "\0" .. content)
end

local function validRelativePath(value)
    return type(value) == "string"
        and value ~= ""
        and value:sub(1, 1) ~= "/"
        and not value:find("..", 1, true)
end

local function validSha(value)
    return type(value) == "string"
        and #value == 40
        and value:match("^[0-9a-fA-F]+$") ~= nil
end

local function isInteger(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
end

local function absoluteTarget(target)
    return "/" .. tostring(target or ""):gsub("^/+", "")
end

local function ensureParent(path)
    local parent = fs.getDir(path)

    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
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

local function writeRaw(path, content)
    ensureParent(path)

    local file, openError = fs.open(path, "w")

    if not file then
        return false, "open_failed:" .. tostring(openError)
    end

    local ok, writeError = pcall(function()
        file.write(content)
    end)

    pcall(function()
        file.close()
    end)

    if not ok then
        return false, "write_failed:" .. tostring(writeError)
    end

    return true
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

local function writeAtomicJson(path, value)
    local ok, raw = pcall(textutils.serializeJSON, value)

    if not ok or type(raw) ~= "string" then
        return false, "json_serialize_failed"
    end

    ensureParent(path)
    local temp = path .. ".tmp"
    local backup = path .. ".bak"

    if fs.exists(temp) then pcall(fs.delete, temp) end

    local wrote, writeError = writeRaw(temp, raw)

    if not wrote then
        return false, writeError
    end

    local verify = readJson(temp)

    if type(verify) ~= "table" then
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
    return true, #raw
end

local function replaceLowSpace(path, content)
    local oldContent = readAll(path)

    if oldContent == content then
        return true, "unchanged"
    end

    if fs.exists(path) and fs.isDir(path) then
        return false, "target_is_directory"
    end

    if fs.exists(path) then
        fs.delete(path)
    end

    local wrote, writeError = writeRaw(path, content)

    if wrote and readAll(path) == content then
        return true, "updated"
    end

    if fs.exists(path) then pcall(fs.delete, path) end

    if oldContent ~= nil then
        local restored, restoreError = writeRaw(path, oldContent)

        if not restored then
            return false, tostring(writeError) .. ";restore_failed:" .. tostring(restoreError)
        end
    end

    return false, tostring(writeError or "verification_failed")
end

local function freeSpace()
    if type(fs.getFreeSpace) ~= "function" then
        return nil
    end

    local ok, value = pcall(fs.getFreeSpace, "/")

    if not ok then return nil end
    if value == "unlimited" then return math.huge end
    return tonumber(value)
end

local function capacity()
    if type(fs.getCapacity) ~= "function" then
        return nil
    end

    local ok, value = pcall(fs.getCapacity, "/")

    if not ok then return nil end
    return tonumber(value)
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

local function download(url)
    if type(http) ~= "table" or type(http.get) ~= "function" then
        return nil, "http_unavailable"
    end

    local response, err = http.get(url)

    if not response then
        return nil, tostring(err or "request_failed")
    end

    local ok, content = pcall(function()
        return response.readAll()
    end)

    pcall(function()
        response.close()
    end)

    if not ok or type(content) ~= "string" then
        return nil, "response_read_failed:" .. tostring(content)
    end

    return content
end

local function sourceUrl(sourceCommit, source)
    return "https://raw.githubusercontent.com/"
        .. Updater.OWNER .. "/" .. Updater.REPO .. "/"
        .. sourceCommit .. "/" .. source
end

local function validateManifest(manifest)
    if type(manifest) ~= "table" or manifest.schema ~= Updater.MANIFEST_SCHEMA then
        return false, "manifest_schema_unsupported"
    end

    if type(manifest.version) ~= "string" or manifest.version == "" then
        return false, "manifest_version_invalid"
    end

    if not validSha(manifest.sourceCommit) then
        return false, "manifest_source_commit_invalid"
    end

    if manifest.hashAlgorithm ~= "git-blob-sha1" then
        return false, "manifest_hash_algorithm_unsupported"
    end

    if type(manifest.files) ~= "table" then
        return false, "manifest_files_missing"
    end

    local seen = {}
    local hasControl = false

    for index, item in ipairs(manifest.files) do
        if type(item) ~= "table"
            or not validRelativePath(item.source)
            or not validRelativePath(item.target)
        then
            return false, "manifest_file_invalid:" .. tostring(index)
        end

        if seen[item.target] then
            return false, "manifest_duplicate_target:" .. item.target
        end
        seen[item.target] = true

        if item.control == "manifest" then
            if item.target ~= "deploy.json" or item.source ~= "deploy.json" then
                return false, "manifest_control_invalid"
            end
            hasControl = true
        else
            if not isInteger(item.size) or not validSha(item.hash) then
                return false, "manifest_file_metadata_invalid:" .. tostring(index)
            end
        end

        if item.bootstrapProtected ~= nil and type(item.bootstrapProtected) ~= "boolean" then
            return false, "manifest_bootstrap_flag_invalid:" .. tostring(index)
        end

        if item.selfEngine ~= nil and type(item.selfEngine) ~= "boolean" then
            return false, "manifest_engine_flag_invalid:" .. tostring(index)
        end
    end

    if not hasControl then
        return false, "manifest_control_missing"
    end

    for index, target in ipairs(manifest.remove or {}) do
        if not validRelativePath(target) then
            return false, "manifest_remove_invalid:" .. tostring(index)
        end
    end

    return true
end

local function manifestIndex(manifest)
    local result = {}

    for _, item in ipairs(manifest and manifest.files or {}) do
        result[item.target] = item
    end

    return result
end

local function matchesEntry(path, entry)
    if not entry or entry.control == "manifest" then
        return false
    end

    if not fs.exists(path) or fs.isDir(path) then
        return false
    end

    if type(fs.getSize) == "function" then
        local ok, size = pcall(fs.getSize, path)

        if ok and tonumber(size) and tonumber(size) ~= entry.size then
            return false
        end
    end

    local content = readAll(path)

    if content == nil or #content ~= entry.size then
        return false
    end

    local hash, hashError = gitBlob(content)

    if not hash then
        error(hashError, 0)
    end

    return string.lower(hash) == string.lower(entry.hash)
end

local function validateJournal(value)
    if type(value) ~= "table" or value.schema ~= Updater.JOURNAL_SCHEMA then
        return false, "journal_schema_invalid"
    end

    if value.operation ~= "core-update"
        or type(value.targetVersion) ~= "string"
        or value.targetVersion == ""
        or not validSha(value.sourceCommit)
        or type(value.manifestRaw) ~= "string"
        or value.manifestRaw == ""
        or type(value.files) ~= "table"
        or type(value.removeFiles) ~= "table"
    then
        return false, "journal_structure_invalid"
    end

    for index, item in ipairs(value.files) do
        if type(item) ~= "table"
            or not validRelativePath(item.source)
            or not validRelativePath(item.target)
            or not isInteger(item.size)
            or not validSha(item.hash)
            or (item.state ~= "pending" and item.state ~= "done")
        then
            return false, "journal_file_invalid:" .. tostring(index)
        end
    end

    for index, item in ipairs(value.removeFiles) do
        if type(item) ~= "table"
            or not validRelativePath(item.target)
            or (item.state ~= "pending" and item.state ~= "done")
        then
            return false, "journal_remove_invalid:" .. tostring(index)
        end
    end

    return true
end

local function loadJournal()
    local paths = {
        Updater.JOURNAL_FILE,
        Updater.JOURNAL_FILE .. ".bak",
        Updater.JOURNAL_FILE .. ".tmp"
    }

    for _, path in ipairs(paths) do
        if fs.exists(path) then
            local value = readJson(path)
            local valid = value and validateJournal(value)

            if valid then
                if path ~= Updater.JOURNAL_FILE then
                    writeAtomicJson(Updater.JOURNAL_FILE, value)
                end

                return value, true
            end
        end
    end

    if fs.exists(Updater.JOURNAL_FILE) then
        return nil, "journal_unreadable"
    end

    return nil, false
end

local function saveJournal(journal)
    journal.updatedAt = nowMs()
    local valid, err = validateJournal(journal)

    if not valid then
        return false, err
    end

    return writeAtomicJson(Updater.JOURNAL_FILE, journal)
end

local function clearJournal()
    local paths = {
        Updater.JOURNAL_FILE,
        Updater.JOURNAL_FILE .. ".bak",
        Updater.JOURNAL_FILE .. ".tmp"
    }

    for _, path in ipairs(paths) do
        if fs.exists(path) then pcall(fs.delete, path) end
    end
end

local function cleanupLegacyStage()
    if fs.exists(Updater.LEGACY_STAGE) then
        pcall(fs.delete, Updater.LEGACY_STAGE)
    end
end

local function fileSize(path)
    if not fs.exists(path) or fs.isDir(path) then
        return 0
    end

    local ok, size = pcall(fs.getSize, path)
    return ok and tonumber(size) or #(readAll(path) or "")
end

local function sortChanges(files)
    table.sort(files, function(a, b)
        local priorityA = a.selfEngine and 90 or 0
        local priorityB = b.selfEngine and 90 or 0

        if priorityA ~= priorityB then
            return priorityA < priorityB
        end

        local deltaA = a.size - (a.oldSize or 0)
        local deltaB = b.size - (b.oldSize or 0)

        if deltaA ~= deltaB then
            return deltaA < deltaB
        end

        return a.target < b.target
    end)
end

local function buildPlan(manifest, manifestRaw, localManifest)
    local oldIndex = manifestIndex(localManifest)
    local files = {}
    local netGrowth = 0
    local enginePeak = 0
    local changed = 0
    local unchanged = 0

    for _, item in ipairs(manifest.files) do
        if item.control ~= "manifest" then
            local path = absoluteTarget(item.target)

            if matchesEntry(path, item) then
                unchanged = unchanged + 1
            else
                if item.bootstrapProtected then
                    return nil, "bootstrap_file_changed_use_rescue:" .. item.target
                end

                local oldEntry = oldIndex[item.target]
                local oldSize = fileSize(path)

                if fs.exists(path) then
                    if fs.isDir(path) then
                        return nil, "target_is_directory:" .. item.target
                    end

                    if oldEntry and oldEntry.hash and oldEntry.size then
                        local oldMatches = matchesEntry(path, oldEntry)
                        local sameExpected = oldEntry.hash == item.hash and oldEntry.size == item.size

                        if not oldMatches and not sameExpected then
                            return nil, "core_file_modified:" .. item.target
                        end
                    elseif not oldEntry then
                        return nil, "core_target_conflict:" .. item.target
                    end
                end

                files[#files + 1] = {
                    source = item.source,
                    target = item.target,
                    size = item.size,
                    hash = item.hash,
                    state = "pending",
                    oldSize = oldSize,
                    selfEngine = item.selfEngine == true
                }

                changed = changed + 1
                netGrowth = netGrowth + item.size - oldSize

                if item.selfEngine then
                    enginePeak = math.max(enginePeak, item.size)
                end
            end
        end
    end

    local removeFiles = {}

    for _, target in ipairs(manifest.remove or {}) do
        local path = absoluteTarget(target)
        local size = fileSize(path)

        if size > 0 or fs.exists(path) then
            removeFiles[#removeFiles + 1] = {
                target = target,
                state = "pending",
                oldSize = size
            }
            netGrowth = netGrowth - size
        end
    end

    local oldManifestRaw = readAll(Updater.MANIFEST_FILE) or ""
    local oldVersionRaw = readAll(Updater.VERSION_FILE) or ""
    netGrowth = netGrowth + #manifestRaw - #oldManifestRaw
    netGrowth = netGrowth + #manifest.version - #oldVersionRaw

    sortChanges(files)

    local journal = {
        schema = Updater.JOURNAL_SCHEMA,
        operation = "core-update",
        transactionId = tostring(nowMs()) .. "-" .. tostring(os.getComputerID()),
        fromVersion = oldVersionRaw ~= "" and oldVersionRaw or "unknown",
        targetVersion = manifest.version,
        sourceCommit = manifest.sourceCommit,
        hashAlgorithm = manifest.hashAlgorithm,
        manifestRaw = manifestRaw,
        createdAt = nowMs(),
        updatedAt = nowMs(),
        files = files,
        removeFiles = removeFiles
    }

    local ok, journalRaw = pcall(textutils.serializeJSON, journal)

    if not ok or type(journalRaw) ~= "string" then
        return nil, "journal_estimate_failed"
    end

    local journalReserve = #journalRaw * 2 + Updater.SPACE_RESERVE
    local required = math.max(0, netGrowth) + enginePeak + journalReserve
    local free = freeSpace()

    return {
        journal = journal,
        changed = changed,
        unchanged = unchanged,
        removals = #removeFiles,
        netGrowth = netGrowth,
        enginePeak = enginePeak,
        journalReserve = journalReserve,
        required = required,
        free = free,
        safe = free == math.huge or (free ~= nil and free >= required)
    }
end

local function verifyDownloaded(item, content)
    if type(content) ~= "string" or #content ~= item.size then
        return false, "size_mismatch"
    end

    local hash, hashError = gitBlob(content)

    if not hash then
        return false, hashError
    end

    if string.lower(hash) ~= string.lower(item.hash) then
        return false, "hash_mismatch"
    end

    return true
end

local function replaceEngine(item, content)
    if fs.exists(Updater.ENGINE_NEXT) then pcall(fs.delete, Updater.ENGINE_NEXT) end

    local wrote, writeError = writeRaw(Updater.ENGINE_NEXT, content)

    if not wrote then
        return false, writeError
    end

    local nextContent = readAll(Updater.ENGINE_NEXT)
    local valid, verifyError = verifyDownloaded(item, nextContent)

    if not valid then
        pcall(fs.delete, Updater.ENGINE_NEXT)
        return false, "engine_temp_invalid:" .. tostring(verifyError)
    end

    if fs.exists(Updater.ENGINE_PREV) then pcall(fs.delete, Updater.ENGINE_PREV) end

    if fs.exists(Updater.ENGINE_PATH) then
        fs.move(Updater.ENGINE_PATH, Updater.ENGINE_PREV)
    end

    local moved, moveError = pcall(fs.move, Updater.ENGINE_NEXT, Updater.ENGINE_PATH)

    if not moved then
        if fs.exists(Updater.ENGINE_PREV) and not fs.exists(Updater.ENGINE_PATH) then
            pcall(fs.move, Updater.ENGINE_PREV, Updater.ENGINE_PATH)
        end
        return false, "engine_activate_failed:" .. tostring(moveError)
    end

    local installed = readAll(Updater.ENGINE_PATH)
    local installedValid, installedError = verifyDownloaded(item, installed)

    if not installedValid then
        if fs.exists(Updater.ENGINE_PATH) then pcall(fs.delete, Updater.ENGINE_PATH) end
        if fs.exists(Updater.ENGINE_PREV) then pcall(fs.move, Updater.ENGINE_PREV, Updater.ENGINE_PATH) end
        return false, "engine_verify_failed:" .. tostring(installedError)
    end

    if fs.exists(Updater.ENGINE_PREV) then pcall(fs.delete, Updater.ENGINE_PREV) end
    return true
end

local function processFile(journal, item, index, total)
    local path = absoluteTarget(item.target)

    if matchesEntry(path, item) then
        item.state = "done"
        local saved, saveError = saveJournal(journal)
        if not saved then return false, saveError end
        print("[" .. index .. "/" .. total .. "] " .. item.target .. " (already done)")
        return true
    end

    local content, downloadError = download(sourceUrl(journal.sourceCommit, item.source))

    if not content then
        return false, "download_failed:" .. item.source .. ":" .. tostring(downloadError)
    end

    local valid, verifyError = verifyDownloaded(item, content)

    if not valid then
        return false, "download_invalid:" .. item.source .. ":" .. tostring(verifyError)
    end

    local currentSize = fileSize(path)
    local free = freeSpace()
    local extra = item.selfEngine and #content or math.max(0, #content - currentSize)

    if free ~= nil and free ~= math.huge and free < extra + Updater.SPACE_RESERVE then
        return false, "space_exhausted:" .. item.target
    end

    print("[" .. index .. "/" .. total .. "] " .. item.target)

    local wrote, writeError

    if item.selfEngine then
        wrote, writeError = replaceEngine(item, content)
    else
        wrote, writeError = replaceLowSpace(path, content)
    end

    if not wrote then
        return false, "install_failed:" .. item.target .. ":" .. tostring(writeError)
    end

    if not matchesEntry(path, item) then
        return false, "post_write_verify_failed:" .. item.target
    end

    item.state = "done"
    local saved, saveError = saveJournal(journal)

    if not saved then
        return false, "journal_progress_save_failed:" .. tostring(saveError)
    end

    return true
end

local function finalize(journal)
    local manifest = textutils.unserializeJSON(journal.manifestRaw)
    local validManifest, manifestError = validateManifest(manifest)

    if not validManifest then
        return false, "journal_manifest_invalid:" .. tostring(manifestError)
    end

    local manifestOk, manifestWriteError = replaceLowSpace(Updater.MANIFEST_FILE, journal.manifestRaw)

    if not manifestOk then
        return false, "manifest_write_failed:" .. tostring(manifestWriteError)
    end

    local committedManifest = readJson(Updater.MANIFEST_FILE)
    local committedValid = committedManifest and validateManifest(committedManifest)

    if not committedValid
        or committedManifest.version ~= journal.targetVersion
        or committedManifest.sourceCommit ~= journal.sourceCommit
    then
        return false, "manifest_commit_validation_failed"
    end

    local versionOk, versionError = replaceLowSpace(Updater.VERSION_FILE, journal.targetVersion)

    if not versionOk then
        return false, "version_write_failed:" .. tostring(versionError)
    end

    local warnings = {}

    local managerLoaded, Manager = pcall(require, "lib.package.manager")

    if managerLoaded and type(Manager) == "table" and type(Manager.new) == "function" then
        local manager = Manager.new()
        local reconciled, reconcileError = manager:reconcileCurrentInstallation()

        if not reconciled then
            warnings[#warnings + 1] = "registry:" .. tostring(reconcileError)
        end
    else
        warnings[#warnings + 1] = "registry:manager_unavailable"
    end

    package.loaded["lib.security.integrity"] = nil
    local integrityLoaded, Integrity = pcall(require, "lib.security.integrity")

    if integrityLoaded and type(Integrity) == "table" and type(Integrity.createBaseline) == "function" then
        local baseline, baselineError = Integrity.createBaseline()

        if not baseline then
            warnings[#warnings + 1] = "integrity:" .. tostring(baselineError)
        end
    else
        warnings[#warnings + 1] = "integrity:service_unavailable"
    end

    clearJournal()
    cleanupLegacyStage()

    if fs.exists(Updater.ENGINE_NEXT) then pcall(fs.delete, Updater.ENGINE_NEXT) end
    if fs.exists(Updater.ENGINE_PREV) then pcall(fs.delete, Updater.ENGINE_PREV) end

    return true, warnings
end

local function executeJournal(journal)
    local total = #journal.files + #journal.removeFiles
    local current = 0

    for _, item in ipairs(journal.files) do
        current = current + 1

        if item.state ~= "done" then
            local ok, err = processFile(journal, item, current, total)
            if not ok then return false, err end
        elseif not matchesEntry(absoluteTarget(item.target), item) then
            return false, "completed_file_changed:" .. item.target
        end
    end

    for _, item in ipairs(journal.removeFiles) do
        current = current + 1

        if item.state ~= "done" then
            local path = absoluteTarget(item.target)
            print("[" .. current .. "/" .. total .. "] remove " .. item.target)

            if fs.exists(path) then
                local ok, deleteError = pcall(fs.delete, path)
                if not ok then return false, "delete_failed:" .. tostring(deleteError) end
            end

            item.state = "done"
            local saved, saveError = saveJournal(journal)
            if not saved then return false, saveError end
        end
    end

    return finalize(journal)
end

local function printPlan(plan, manifest)
    print("CORE UPDATE PLAN")
    print("Target version: " .. manifest.version)
    print("Source commit: " .. manifest.sourceCommit:sub(1, 12))
    print("Changed files: " .. tostring(plan.changed))
    print("Unchanged files: " .. tostring(plan.unchanged))
    print("Remove files: " .. tostring(plan.removals))
    print("Net growth: " .. formatBytes(plan.netGrowth))
    print("Journal reserve: " .. formatBytes(plan.journalReserve))
    print("Updater peak: " .. formatBytes(plan.enginePeak))
    print("Required free: " .. formatBytes(plan.required))
    print("Current free: " .. formatBytes(plan.free))
    print("Safe: " .. (plan.safe and "yes" or "no"))
end

local function prepareUpdate(planOnly)
    if fs.exists(Updater.PACKAGE_JOURNAL) then
        return false, "package_transaction_pending_run_pkg_recover"
    end

    cleanupLegacyStage()
    print("CC CORE UPDATE v2")
    print("")
    print("Downloading manifest...")

    local manifestRaw, manifestDownloadError = download(MANIFEST_URL)

    if not manifestRaw then
        return false, "manifest_download_failed:" .. tostring(manifestDownloadError)
    end

    local ok, manifest = pcall(textutils.unserializeJSON, manifestRaw)

    if not ok or type(manifest) ~= "table" then
        return false, "manifest_json_invalid"
    end

    local manifestValid, manifestError = validateManifest(manifest)

    if not manifestValid then
        return false, manifestError
    end

    local localManifest = readJson(Updater.MANIFEST_FILE)

    if type(localManifest) ~= "table" or localManifest.schema ~= Updater.MANIFEST_SCHEMA then
        return false, "local_manifest_not_v2_use_rescue_or_legacy_updater"
    end

    local plan, planError = buildPlan(manifest, manifestRaw, localManifest)

    if not plan then
        return false, planError
    end

    printPlan(plan, manifest)

    if planOnly then
        return true
    end

    if not plan.safe then
        return false,
            "insufficient_space:required=" .. tostring(plan.required)
            .. ":free=" .. tostring(plan.free)
    end

    if plan.changed == 0 and plan.removals == 0
        and readAll(Updater.MANIFEST_FILE) == manifestRaw
        and readAll(Updater.VERSION_FILE) == manifest.version
    then
        print("")
        print("Already up to date.")
        return true
    end

    local saved, saveError = saveJournal(plan.journal)

    if not saved then
        return false, "journal_create_failed:" .. tostring(saveError)
    end

    print("")
    print("Installing in transactional low-space mode...")
    local completed, detail = executeJournal(plan.journal)

    if not completed then
        return false, detail
    end

    print("")
    print("Update complete.")
    print("Installed version: " .. manifest.version)
    print("Free after update: " .. formatBytes(freeSpace()))

    for _, warning in ipairs(detail or {}) do
        print("WARNING " .. warning)
    end

    return true
end

local function recover()
    local journal, existsOrError = loadJournal()

    if not journal then
        if existsOrError == false then
            print("No pending core update.")
            return true
        end

        return false, existsOrError
    end

    print("RECOVERING CORE UPDATE")
    print("Target version: " .. journal.targetVersion)
    print("Transaction: " .. tostring(journal.transactionId or "unknown"))
    print("")

    local completed, detail = executeJournal(journal)

    if not completed then
        return false, detail
    end

    print("")
    print("Recovery complete.")
    print("Installed version: " .. journal.targetVersion)

    for _, warning in ipairs(detail or {}) do
        print("WARNING " .. warning)
    end

    return true
end

function Updater.main(args)
    args = type(args) == "table" and args or {}
    local command = args[1]

    local pending, pendingState = loadJournal()

    if pending then
        return recover()
    elseif pendingState ~= false then
        error(pendingState, 0)
    end

    if command == "--recover" or command == "recover" then
        return recover()
    elseif command == "--plan" or command == "plan" then
        local ok, err = prepareUpdate(true)
        if not ok then error(err, 0) end
        return true
    elseif command == "--help" or command == "help" or command == "-h" then
        print("Usage: update [--plan|--recover]")
        return true
    elseif command ~= nil then
        error("Unknown update option: " .. tostring(command), 0)
    end

    local ok, err = prepareUpdate(false)

    if not ok then
        print("")
        print("CORE UPDATE PAUSED")
        print(tostring(err))

        if fs.exists(Updater.JOURNAL_FILE) then
            print("Run 'update --recover' after fixing the problem.")
        end

        error(err, 0)
    end

    return true
end

return Updater
