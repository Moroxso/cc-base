local OWNER = "Moroxso"
local REPO = "cc-base"
local BRANCH = "main"

local LIVE_BASE = "https://raw.githubusercontent.com/"
    .. OWNER .. "/" .. REPO .. "/refs/heads/" .. BRANCH .. "/"
local MANIFEST_URL = LIVE_BASE .. "deploy.json"
local VERSION_FILE = "/.project-version"
local MANIFEST_FILE = "/deploy.json"
local UPDATE_JOURNAL = "/data/system/update-journal.json"
local LEGACY_STAGE = "/.cc_update_stage"

local bit = bit32

local function add32(...)
    local total = 0
    for index = 1, select("#", ...) do
        total = (total + select(index, ...)) % 4294967296
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
    if type(bit) ~= "table" then return nil, "bit32 unavailable" end

    local bitLength = #content * 8
    local message = content .. string.char(0x80)
    local padding = (56 - (#message % 64)) % 64
    message = message .. string.rep("\0", padding)
    message = message
        .. wordToBytes(math.floor(bitLength / 4294967296))
        .. wordToBytes(bitLength % 4294967296)

    local h0, h1, h2, h3, h4 =
        0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
    local words = {}

    for chunkStart = 1, #message, 64 do
        for index = 0, 15 do
            local offset = chunkStart + index * 4
            local a, b, c, d = string.byte(message, offset, offset + 3)
            words[index] = bit.bor(
                bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d
            )
        end

        for index = 16, 79 do
            words[index] = bit.lrotate(bit.bxor(
                words[index - 3], words[index - 8],
                words[index - 14], words[index - 16]
            ), 1)
        end

        local a, b, c, d, e = h0, h1, h2, h3, h4

        for index = 0, 79 do
            local f, k
            if index <= 19 then
                f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
                k = 0x5a827999
            elseif index <= 39 then
                f = bit.bxor(b, c, d)
                k = 0x6ed9eba1
            elseif index <= 59 then
                f = bit.bor(bit.band(b, c), bit.band(b, d), bit.band(c, d))
                k = 0x8f1bbcdc
            else
                f = bit.bxor(b, c, d)
                k = 0xca62c1d6
            end

            local temp = add32(bit.lrotate(a, 5), f, e, k, words[index])
            e, d, c, b, a = d, c, bit.lrotate(b, 30), a, temp
        end

        h0, h1, h2, h3, h4 =
            add32(h0, a), add32(h1, b), add32(h2, c), add32(h3, d), add32(h4, e)
    end

    return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

local function gitBlob(content)
    return sha1("blob " .. tostring(#content) .. "\0" .. content)
end

local function validPath(path)
    return type(path) == "string" and path ~= ""
        and path:sub(1, 1) ~= "/" and not path:find("..", 1, true)
end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
end

local function readFile(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local content = file.readAll()
    file.close()
    return content
end

local function writeFile(path, content)
    ensureParent(path)
    local file, openError = fs.open(path, "w")
    if not file then return false, tostring(openError) end
    local ok, err = pcall(function() file.write(content) end)
    pcall(function() file.close() end)
    return ok, err
end

local function replaceFile(path, content)
    local oldContent = readFile(path)
    if oldContent == content then return true, "unchanged" end
    if fs.exists(path) and fs.isDir(path) then return false, "target is directory" end
    if fs.exists(path) then fs.delete(path) end

    local ok, err = writeFile(path, content)
    if ok and readFile(path) == content then return true, "updated" end

    if fs.exists(path) then pcall(fs.delete, path) end
    if oldContent ~= nil then
        local restored, restoreError = writeFile(path, oldContent)
        if not restored then
            return false, tostring(err) .. "; restore failed: " .. tostring(restoreError)
        end
    end
    return false, tostring(err or "verification failed")
end

local function download(url)
    if type(http) ~= "table" or type(http.get) ~= "function" then
        return nil, "HTTP unavailable"
    end
    local response, err = http.get(url)
    if not response then return nil, err end
    local content = response.readAll()
    response.close()
    return content
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

local function formatBytes(value)
    if value == nil then return "unknown" end
    if value == math.huge then return "unlimited" end
    value = math.max(0, math.floor(tonumber(value) or 0))
    if value >= 1024 * 1024 then return string.format("%.2f MiB", value / 1048576) end
    if value >= 1024 then return string.format("%.1f KiB", value / 1024) end
    return tostring(value) .. " B"
end

local function matches(path, item)
    local content = readFile(path)
    if not content or #content ~= item.size then return false end
    local hash = gitBlob(content)
    return hash and string.lower(hash) == string.lower(item.hash)
end

if fs.exists(LEGACY_STAGE) then pcall(fs.delete, LEGACY_STAGE) end

print("CC CORE RESCUE UPDATE v2")
print("")
print("No staging image is used.")
print("Downloading manifest...")

local manifestRaw, manifestError = download(MANIFEST_URL)
if not manifestRaw then error("Manifest download failed: " .. tostring(manifestError), 0) end

local manifest = textutils.unserializeJSON(manifestRaw)
if type(manifest) ~= "table" or manifest.schema ~= 2
    or type(manifest.sourceCommit) ~= "string"
    or type(manifest.files) ~= "table"
    or manifest.hashAlgorithm ~= "git-blob-sha1"
then
    error("Unsupported or invalid deploy manifest", 0)
end

local baseUrl = "https://raw.githubusercontent.com/"
    .. OWNER .. "/" .. REPO .. "/" .. manifest.sourceCommit .. "/"

print("Target: " .. tostring(manifest.version))
print("Capacity: " .. formatBytes(capacity()))
print("Free: " .. formatBytes(freeSpace()))
print("")
print("Preflight...")

local changes = {}
local unchanged = 0
local netGrowth = 0

for index, item in ipairs(manifest.files) do
    if not validPath(item.source) or not validPath(item.target) then
        error("Invalid manifest entry #" .. tostring(index), 0)
    end

    if item.control ~= "manifest" then
        if type(item.size) ~= "number" or type(item.hash) ~= "string" then
            error("Missing file metadata: " .. item.target, 0)
        end

        local target = "/" .. item.target
        if matches(target, item) then
            unchanged = unchanged + 1
        else
            local old = readFile(target)
            local oldSize = old and #old or 0
            changes[#changes + 1] = item
            netGrowth = netGrowth + item.size - oldSize
        end
    end
end

netGrowth = netGrowth + #manifestRaw - #(readFile(MANIFEST_FILE) or "")
local versionText = tostring(manifest.version or "unknown")
netGrowth = netGrowth + #versionText - #(readFile(VERSION_FILE) or "")

local available = freeSpace()
local required = math.max(0, netGrowth)

print("Changed files: " .. tostring(#changes))
print("Unchanged files: " .. tostring(unchanged))
print("Net growth: " .. formatBytes(netGrowth))
print("Required free: " .. formatBytes(required))

if available ~= nil and available ~= math.huge and available < required then
    error("Final installation does not fit the current disk quota", 0)
end

table.sort(changes, function(a, b)
    local da = a.size - #(readFile("/" .. a.target) or "")
    local db = b.size - #(readFile("/" .. b.target) or "")
    if da ~= db then return da < db end
    return a.target < b.target
end)

print("")
print("Installing...")

for index, item in ipairs(changes) do
    local content, err = download(baseUrl .. item.source)
    if not content then error("Download failed: " .. item.source .. ": " .. tostring(err), 0) end

    if #content ~= item.size then error("Size mismatch: " .. item.source, 0) end
    local hash, hashError = gitBlob(content)
    if not hash then error(hashError, 0) end
    if string.lower(hash) ~= string.lower(item.hash) then
        error("Hash mismatch: " .. item.source, 0)
    end

    print("[" .. index .. "/" .. #changes .. "] " .. item.target)
    local ok, replaceError = replaceFile("/" .. item.target, content)
    if not ok then error("Install failed: " .. item.target .. ": " .. tostring(replaceError), 0) end
end

for _, target in ipairs(manifest.remove or {}) do
    if validPath(target) and fs.exists("/" .. target) then
        pcall(fs.delete, "/" .. target)
    end
end

local manifestOk, manifestWriteError = replaceFile(MANIFEST_FILE, manifestRaw)
if not manifestOk then error("Manifest write failed: " .. tostring(manifestWriteError), 0) end

local versionOk, versionError = replaceFile(VERSION_FILE, versionText)
if not versionOk then error("Version write failed: " .. tostring(versionError), 0) end

if fs.exists(UPDATE_JOURNAL) then pcall(fs.delete, UPDATE_JOURNAL) end
if fs.exists(UPDATE_JOURNAL .. ".bak") then pcall(fs.delete, UPDATE_JOURNAL .. ".bak") end
if fs.exists(UPDATE_JOURNAL .. ".tmp") then pcall(fs.delete, UPDATE_JOURNAL .. ".tmp") end

local managerLoaded, Manager = pcall(require, "lib.package.manager")
if managerLoaded and type(Manager) == "table" and type(Manager.new) == "function" then
    pcall(function() Manager.new():reconcileCurrentInstallation() end)
end

package.loaded["lib.security.integrity"] = nil
local integrityLoaded, Integrity = pcall(require, "lib.security.integrity")
if integrityLoaded and type(Integrity) == "table" and type(Integrity.createBaseline) == "function" then
    pcall(Integrity.createBaseline)
end

print("")
print("Rescue update complete.")
print("Installed version: " .. versionText)
print("Free after update: " .. formatBytes(freeSpace()))
