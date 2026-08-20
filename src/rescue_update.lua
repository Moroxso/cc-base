local OWNER = "Moroxso"
local REPO = "cc-base"
local BRANCH = "main"

local BASE_URL =
    "https://raw.githubusercontent.com/"
    .. OWNER .. "/" .. REPO .. "/refs/heads/" .. BRANCH .. "/"

local MANIFEST_URL = BASE_URL .. "deploy.json"
local VERSION_FILE = "/.project-version"
local SECURITY_BASELINE = "/data/security/integrity.json"
local STAGE_DIR = "/.cc_update_stage"

local function download(url)
    local response, err = http.get(url)
    if not response then return nil, err end

    local content = response.readAll()
    response.close()
    return content
end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

local function readFile(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end

    local file = fs.open(path, "r")
    if not file then return nil end

    local content = file.readAll()
    file.close()
    return content
end

local function rawWrite(path, content)
    ensureParent(path)

    local file, openError = fs.open(path, "w")
    if not file then
        return false, "open failed: " .. tostring(openError)
    end

    local ok, writeError = pcall(function()
        file.write(content)
    end)

    pcall(function() file.close() end)

    if not ok then
        return false, tostring(writeError)
    end

    return true
end

local function replaceFile(path, content)
    local oldContent = readFile(path)

    if oldContent == content then
        return true, "unchanged"
    end

    if fs.exists(path) then
        if fs.isDir(path) then
            return false, "target is a directory"
        end
        fs.delete(path)
    end

    local ok, err = rawWrite(path, content)
    local verified = ok and readFile(path) == content

    if verified then
        return true, "updated"
    end

    if fs.exists(path) then
        pcall(fs.delete, path)
    end

    if oldContent ~= nil then
        local restored, restoreError = rawWrite(path, oldContent)
        if not restored then
            return false,
                "write failed: " .. tostring(err)
                .. "; restore failed: " .. tostring(restoreError)
        end
    end

    return false, "write or verification failed: " .. tostring(err)
end

local function hashString(content)
    local hash = 5381
    for index = 1, #content do
        hash = (hash * 33 + string.byte(content, index)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function freeSpace()
    local ok, value = pcall(fs.getFreeSpace, "/")
    if not ok or value == "unlimited" then return math.huge end
    return tonumber(value) or math.huge
end

local function capacity()
    local ok, value = pcall(fs.getCapacity, "/")
    if not ok or value == nil then return math.huge end
    return tonumber(value) or math.huge
end

local function formatBytes(value)
    if value == math.huge then return "unlimited" end
    value = math.max(0, math.floor(tonumber(value) or 0))

    if value >= 1024 * 1024 then
        return string.format("%.2f MiB", value / (1024 * 1024))
    elseif value >= 1024 then
        return string.format("%.1f KiB", value / 1024)
    end

    return tostring(value) .. " B"
end

local function validateTarget(path)
    return type(path) == "string"
        and path ~= ""
        and path:sub(1, 1) ~= "/"
        and not path:find("..", 1, true)
end

local function refreshBaseline(manifest)
    local files = {}
    local seen = {}

    for _, item in ipairs(manifest.files or {}) do
        local path = "/" .. item.target
        if not seen[path] then
            local content = readFile(path)
            if content ~= nil then
                files[#files + 1] = {
                    path = path,
                    hash = hashString(content),
                    size = #content
                }
                seen[path] = true
            end
        end
    end

    local versionContent = readFile(VERSION_FILE)
    if versionContent and not seen[VERSION_FILE] then
        files[#files + 1] = {
            path = VERSION_FILE,
            hash = hashString(versionContent),
            size = #versionContent
        }
    end

    table.sort(files, function(a, b) return a.path < b.path end)

    local baseline = {
        version = 1,
        projectVersion = tostring(manifest.version or "unknown"),
        createdAt = os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000),
        algorithm = "djb2-32",
        files = files
    }

    local ok, serialized = pcall(textutils.serializeJSON, baseline)
    if not ok or type(serialized) ~= "string" then
        return false, "serialize failed"
    end

    return replaceFile(SECURITY_BASELINE, serialized)
end

if fs.exists(STAGE_DIR) then
    pcall(fs.delete, STAGE_DIR)
end

print("CC LOW-SPACE RESCUE UPDATE")
print("")
print("This updater runs from memory and does not use a staging copy.")
print("Downloading manifest...")

local manifestRaw, manifestError = download(MANIFEST_URL)
if not manifestRaw then
    error("Manifest download failed: " .. tostring(manifestError), 0)
end

local manifest = textutils.unserializeJSON(manifestRaw)
if type(manifest) ~= "table" or type(manifest.files) ~= "table" then
    error("Invalid manifest", 0)
end

print("Version: " .. tostring(manifest.version or "unknown"))
print("Capacity: " .. formatBytes(capacity()))
print("Free: " .. formatBytes(freeSpace()))
print("")
print("Preflight...")

local changes = {}
local totalDelta = 0
local unchanged = 0

for index, item in ipairs(manifest.files) do
    if type(item.source) ~= "string" or not validateTarget(item.target) then
        error("Invalid manifest entry #" .. tostring(index), 0)
    end

    local content, err = download(BASE_URL .. item.source)
    if not content then
        error("Download failed: " .. item.source .. "\n" .. tostring(err), 0)
    end

    local target = "/" .. item.target
    local oldContent = readFile(target)

    if oldContent == content then
        unchanged = unchanged + 1
        print("[" .. index .. "/" .. #manifest.files .. "] " .. item.target .. " (unchanged)")
    else
        local oldSize = oldContent and #oldContent or 0
        local delta = #content - oldSize

        changes[#changes + 1] = {
            source = item.source,
            target = item.target,
            newSize = #content,
            oldSize = oldSize,
            delta = delta,
            hash = hashString(content)
        }
        totalDelta = totalDelta + delta

        print("[" .. index .. "/" .. #manifest.files .. "] " .. item.target .. " (change)")
    end
end

local versionText = tostring(manifest.version or "unknown")
local oldVersion = readFile(VERSION_FILE)
totalDelta = totalDelta + (#versionText - (oldVersion and #oldVersion or 0))

local requiredGrowth = math.max(0, totalDelta)
local available = freeSpace()

print("")
print(
    "Changed: "
    .. tostring(#changes))
    .. "/"
    .. tostring(#manifest.files)
)
print("Unchanged: " .. tostring(unchanged))
print("Net growth: " .. formatBytes(requiredGrowth))
print("Free now: " .. formatBytes(available))

if available ~= math.huge and available < requiredGrowth then
    error(
        "Final installation does not fit current CC:Tweaked disk quota. "
        .. "Need at least " .. formatBytes(requiredGrowth)
        .. " more free space, but only " .. formatBytes(available)
        .. " is available. Increase computer_space_limit or remove local data.",
        0
    )
end

table.sort(changes, function(a, b)
    if a.delta == b.delta then return a.target < b.target end
    return a.delta < b.delta
end)

print("")
print("Installing in low-space mode...")

for index, item in ipairs(changes) do
    local content, err = download(BASE_URL .. item.source)
    if not content then
        error("Download failed during install: " .. item.source .. "\n" .. tostring(err), 0)
    end

    if #content ~= item.newSize or hashString(content) ~= item.hash then
        error("Repository changed during update: " .. item.source .. ". Run rescue update again.", 0)
    end

    print("[" .. index .. "/" .. #changes .. "] " .. item.target)

    local ok, replaceError = replaceFile("/" .. item.target, content)
    if not ok then
        error("Failed to install " .. item.target .. ": " .. tostring(replaceError), 0)
    end
end

local versionOk, versionError = replaceFile(VERSION_FILE, versionText)
if not versionOk then
    error("Failed to update version file: " .. tostring(versionError), 0)
end

local baselineOk, baselineError = refreshBaseline(manifest)

print("")
print("Rescue update complete.")
print("Installed version: " .. versionText)
print("Free after update: " .. formatBytes(freeSpace()))

if baselineOk then
    print("Integrity baseline: refreshed")
else
    print("Integrity baseline: WARNING " .. tostring(baselineError))
end
