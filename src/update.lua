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

    local file = fs.open(path, "w")

    if not file then
        error("Cannot write file: " .. path)
    end

    file.write(content)
    file.close()
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

local function clearStage()
    if fs.exists(STAGE_DIR) then
        fs.delete(STAGE_DIR)
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
    writeFile(temp, serialized)

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

print("CC UPDATE")
print("")
print("Downloading manifest...")

local manifestData, manifestError = download(MANIFEST_URL)

if not manifestData then
    error("Manifest download failed: " .. tostring(manifestError))
end

local manifest = textutils.unserializeJSON(manifestData)

if type(manifest) ~= "table" then
    error("Invalid manifest")
end

if type(manifest.files) ~= "table" then
    error("Manifest has no files")
end

print("Version: " .. tostring(manifest.version or "unknown"))
print("")
clearStage()

for index, item in ipairs(manifest.files) do
    if type(item.source) ~= "string" or not validateTarget(item.target) then
        error("Invalid manifest entry #" .. index)
    end

    print("[" .. index .. "/" .. #manifest.files .. "] " .. item.target)

    local content, err = download(BASE_URL .. item.source)

    if not content then
        fs.delete(STAGE_DIR)
        error("Download failed: " .. item.source .. "\n" .. tostring(err))
    end

    local stagePath = fs.combine(STAGE_DIR, item.target)
    writeFile(stagePath, content)
end

print("")
print("Installing...")

for _, item in ipairs(manifest.files) do
    local source = fs.combine(STAGE_DIR, item.target)
    local target = "/" .. item.target
    ensureParent(target)

    if fs.exists(target) then
        fs.delete(target)
    end

    fs.move(source, target)
end

if fs.exists(STAGE_DIR) then
    fs.delete(STAGE_DIR)
end

writeFile(VERSION_FILE, tostring(manifest.version or "unknown"))

local baselineOk, baselineError = refreshSecurityBaseline(manifest)

print("")
print("Update complete.")
print("Installed version: " .. tostring(manifest.version or "unknown"))

if baselineOk then
    print("Integrity baseline: refreshed")
else
    print("Integrity baseline: WARNING " .. tostring(baselineError))
end
