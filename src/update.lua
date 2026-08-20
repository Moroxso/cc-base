local OWNER = "Moroxso"
local REPO = "cc-base"
local BRANCH = "main"

local BASE_URL =
    "https://raw.githubusercontent.com/"
    .. OWNER
    .. "/"
    .. REPO
    .. "/refs/heads/"
    .. BRANCH
    .. "/"

local MANIFEST_URL = BASE_URL .. "deploy.json"
local STAGE_DIR = "/.cc_update_stage"
local VERSION_FILE = "/.project-version"
local SECURITY_BASELINE = "/data/security/integrity.json"
local SPACE_RESERVE = 4096

local function download(url)
    local response, err = http.get(url)

    if not response then
        return nil, err
    end

    local content = response.readAll()
    response.close()
    return content
end

local function ensureParent(path)
    local directory = fs.getDir(path)

    if directory ~= "" and not fs.exists(directory) then
        fs.makeDir(directory)
    end
end

local function writeFile(path, content)
    ensureParent(path)

    local file, openError = fs.open(path, "w")

    if not file then
        return false, "Cannot open for write: " .. path .. " (" .. tostring(openError) .. ")"
    end

    local ok, writeError = pcall(function()
        file.write(content)
    end)

    pcall(function()
        file.close()
    end)

    if not ok then
        if fs.exists(path) then
            pcall(fs.delete, path)
        end

        return false, tostring(writeError)
    end

    return true
end

local function mustWriteFile(path, content)
    local ok, err = writeFile(path, content)

    if not ok then
        error("Cannot write " .. path .. ": " .. tostring(err), 0)
    end
end

local function readFile(path)
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

local function hashString(content)
    local hash = 5381

    for index = 1, #content do
        hash = (hash * 33 + string.byte(content, index)) % 4294967296
    end

    return string.format("%08x", hash)
end

local function removeStage()
    if fs.exists(STAGE_DIR) then
        pcall(fs.delete, STAGE_DIR)
    end
end

local function clearStage()
    removeStage()

    if fs.exists(STAGE_DIR) then
        error("Cannot clear update staging directory", 0)
    end

    fs.makeDir(STAGE_DIR)
end

local function validateTarget(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    if path:sub(1, 1) == "/" then
        return false
    end

    if path:find("..", 1, true) then
        return false
    end

    return true
end

local function freeSpace()
    local ok, value = pcall(fs.getFreeSpace, "/")

    if not ok or value == "unlimited" then
        return math.huge
    end

    return tonumber(value) or math.huge
end

local function formatBytes(value)
    value = math.max(0, math.floor(tonumber(value) or 0))

    if value >= 1024 * 1024 then
        return string.format("%.1f MiB", value / (1024 * 1024))
    elseif value >= 1024 then
        return string.format("%.1f KiB", value / 1024)
    end

    return tostring(value) .. " B"
end

local function installedMatches(target, content)
    if not fs.exists(target) or fs.isDir(target) then
        return false
    end

    local ok, size = pcall(fs.getSize, target)

    if ok and tonumber(size) and tonumber(size) ~= #content then
        return false
    end

    local installed = readFile(target)
    return installed == content
end

local function refreshSecurityBaseline(manifest)
    local files = {}
    local seen = {}

    for _, item in ipairs(manifest.files or {}) do
        local path = "/" .. item.target

        if not seen[path] then
            local content = readFile(path)

            if content then
                table.insert(files, {
                    path = path,
                    hash = hashString(content),
                    size = #content
                })
                seen[path] = true
            end
        end
    end

    local versionContent = readFile(VERSION_FILE)

    if versionContent and not seen[VERSION_FILE] then
        table.insert(files, {
            path = VERSION_FILE,
            hash = hashString(versionContent),
            size = #versionContent
        })
    end

    table.sort(files, function(a, b)
        return a.path < b.path
    end)

    local baseline = {
        version = 1,
        projectVersion = tostring(manifest.version or "unknown"),
        createdAt = os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000),
        algorithm = "djb2-32",
        files = files
    }

    local ok, serialized = pcall(textutils.serializeJSON, baseline)

    if not ok or type(serialized) ~= "string" then
        return false, "baseline_serialize_failed"
    end

    local temp = SECURITY_BASELINE .. ".tmp"
    local backup = SECURITY_BASELINE .. ".bak"
    ensureParent(SECURITY_BASELINE)

    if fs.exists(temp) then fs.delete(temp) end

    local writeOk, writeError = writeFile(temp, serialized)

    if not writeOk then
        return false, "baseline_write_failed: " .. tostring(writeError)
    end

    local verifyRaw = readFile(temp)
    local verify = verifyRaw and textutils.unserializeJSON(verifyRaw) or nil

    if type(verify) ~= "table" or type(verify.files) ~= "table" then
        fs.delete(temp)
        return false, "baseline_validation_failed"
    end

    if fs.exists(backup) then fs.delete(backup) end
    if fs.exists(SECURITY_BASELINE) then fs.move(SECURITY_BASELINE, backup) end
    fs.move(temp, SECURITY_BASELINE)

    if fs.exists(backup) then fs.delete(backup) end
    return true
end

local function runUpdate()
    print("CC UPDATE")
    print("")
    print("Downloading manifest...")

    local manifestData, manifestError = download(MANIFEST_URL)

    if not manifestData then
        error("Manifest download failed: " .. tostring(manifestError), 0)
    end

    local manifest = textutils.unserializeJSON(manifestData)

    if type(manifest) ~= "table" then
        error("Invalid manifest", 0)
    end

    if type(manifest.files) ~= "table" then
        error("Manifest has no files", 0)
    end

    print("Version: " .. tostring(manifest.version or "unknown"))
    print("Free space: " .. formatBytes(freeSpace()))
    print("")

    clearStage()

    local staged = {}
    local stagedBytes = 0
    local unchanged = 0

    for index, item in ipairs(manifest.files) do
        if type(item.source) ~= "string" or not validateTarget(item.target) then
            error("Invalid manifest entry #" .. index, 0)
        end

        local content, err = download(BASE_URL .. item.source)

        if not content then
            error("Download failed: " .. item.source .. "\n" .. tostring(err), 0)
        end

        local target = "/" .. item.target

        if installedMatches(target, content) then
            unchanged = unchanged + 1
            print("[" .. index .. "/" .. #manifest.files .. "] " .. item.target .. " (unchanged)")
        else
            local available = freeSpace()
            local required = #content + SPACE_RESERVE

            if available ~= math.huge and available < required then
                error(
                    "Not enough disk space to stage " .. item.target ..
                    ". Need about " .. formatBytes(required) ..
                    ", free " .. formatBytes(available) ..
                    ". Staging directory will be cleaned automatically.",
                    0
                )
            end

            print("[" .. index .. "/" .. #manifest.files .. "] " .. item.target .. " (update)")

            local stagePath = fs.combine(STAGE_DIR, item.target)
            local writeOk, writeError = writeFile(stagePath, content)

            if not writeOk then
                error(
                    "Failed to stage " .. item.target .. ": " .. tostring(writeError),
                    0
                )
            end

            stagedBytes = stagedBytes + #content
            table.insert(staged, {
                target = item.target,
                stagePath = stagePath
            })
        end
    end

    print("")
    print(
        "Changed files: "
        .. tostring(#staged)
        .. "/"
        .. tostring(#manifest.files)
    )
    print("Stage size: " .. formatBytes(stagedBytes))
    print("Unchanged: " .. tostring(unchanged))
    print("")
    print("Installing...")

    for _, item in ipairs(staged) do
        local target = "/" .. item.target
        ensureParent(target)

        if fs.exists(target) then
            fs.delete(target)
        end

        fs.move(item.stagePath, target)
    end

    removeStage()
    mustWriteFile(VERSION_FILE, tostring(manifest.version or "unknown"))

    local baselineOk, baselineError = refreshSecurityBaseline(manifest)

    print("")
    print("Update complete.")
    print("Installed version: " .. tostring(manifest.version or "unknown"))

    if baselineOk then
        print("Integrity baseline: refreshed")
    else
        print("Integrity baseline: WARNING " .. tostring(baselineError))
    end
end

local ok, err = xpcall(runUpdate, function(message)
    return tostring(message)
end)

if not ok then
    removeStage()
    print("")
    print("UPDATE FAILED")
    print(tostring(err))
    print("Staging cleaned. Existing installation was not intentionally removed.")
    error(err, 0)
end
