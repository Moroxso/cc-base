local args = {...}
local action = string.lower(tostring(args[1] or "update"))
local profileArg = string.lower(tostring(args[2] or ""))
local quiet = args[3] == "--quiet" or args[2] == "--quiet"

local REPO = "Moroxso/cc-base"
local MANIFEST_URL = "https://raw.githubusercontent.com/" .. REPO .. "/refs/heads/main/fleet.json"
local PROFILE_PATH = "/data/fleet_profile.json"
local RUNTIME_PATH = "/data/fleet_runtime.json"
local STARTUP_DIR = "/startup"

local function say(text)
    if not quiet then print(text) end
end

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r"); if not f then return nil end
    local raw = f.readAll(); f.close()
    local ok, value = pcall(textutils.unserializeJSON, raw)
    return ok and type(value) == "table" and value or nil
end

local function writeJson(path, value)
    ensureParent(path)
    local ok, raw = pcall(textutils.serializeJSON, value)
    if not ok then return false, raw end
    local tmp = path .. ".tmp"
    if fs.exists(tmp) then pcall(fs.delete, tmp) end
    local f = fs.open(tmp, "w"); if not f then return false, "open_failed" end
    f.write(raw); f.close()
    if fs.exists(path) then pcall(fs.delete, path) end
    fs.move(tmp, path)
    return true
end

local function httpText(url)
    local ok, response = pcall(http.get, url, nil, true)
    if not ok or not response then return nil, "http_failed:" .. tostring(response) end
    local body = response.readAll(); response.close()
    return body
end

local function loadCommon()
    local ok, value = pcall(require, "lib.fleet.common")
    if ok and type(value) == "table" and type(value.sha1) == "function" then return value end
    return nil
end

local Common = loadCommon()
local function gitBlob(content)
    if not Common then return nil, "fleet_common_missing" end
    return Common.sha1("blob " .. tostring(#content) .. "\0" .. content)
end

local function atomicWrite(path, content)
    ensureParent(path)
    local tmp, bak = path .. ".next", path .. ".prev"
    if fs.exists(tmp) then pcall(fs.delete, tmp) end
    local f = fs.open(tmp, "w"); if not f then return false, "temp_open_failed" end
    local ok, err = pcall(function() f.write(content) end); pcall(function() f.close() end)
    if not ok then pcall(fs.delete,tmp); return false, tostring(err) end
    if fs.exists(bak) then pcall(fs.delete,bak) end
    if fs.exists(path) then
        local moved = pcall(fs.move, path, bak)
        if not moved then pcall(fs.delete,tmp); return false, "backup_failed" end
    end
    local committed = pcall(fs.move, tmp, path)
    if not committed then
        if fs.exists(bak) and not fs.exists(path) then pcall(fs.move,bak,path) end
        return false, "commit_failed"
    end
    if fs.exists(bak) then pcall(fs.delete,bak) end
    return true
end

local function resolveProfile()
    if profileArg ~= "" and profileArg ~= "--quiet" then return profileArg end
    local cfg = readJson(PROFILE_PATH)
    return cfg and string.lower(tostring(cfg.profile or "")) or ""
end

local profile = resolveProfile()
if action == "install" and profile == "" then
    error("Usage: fleet_update install assault|relay|pocket", 0)
end
if action ~= "install" and profile == "" then
    error("Fleet profile missing. Run fleet_update install <profile>.", 0)
end
if profile ~= "assault" and profile ~= "relay" and profile ~= "pocket" then
    error("Unknown fleet profile: " .. tostring(profile), 0)
end

say("BASE Fleet updater: " .. profile)
local rawManifest, fetchErr = httpText(MANIFEST_URL)
if not rawManifest then
    if quiet then return false end
    error("Cannot fetch fleet manifest: " .. tostring(fetchErr), 0)
end
local okManifest, manifest = pcall(textutils.unserializeJSON, rawManifest)
if not okManifest or type(manifest) ~= "table" or manifest.schema ~= 1 then
    error("Invalid fleet manifest", 0)
end
if type(manifest.sourceCommit) ~= "string" or #manifest.sourceCommit < 7 then error("Manifest sourceCommit missing", 0) end
if type(manifest.profiles) ~= "table" or type(manifest.profiles[profile]) ~= "table" then error("Profile absent from manifest", 0) end

-- Fresh field computers do not have lib.fleet.common yet. Bootstrap it from the
-- same immutable payload commit, then use its SHA-1 implementation to verify
-- every file (including the common module itself) before commit.
if not Common then
    local entry = manifest.files and manifest.files.common
    if type(entry) ~= "table" then error("Manifest common entry missing", 0) end
    local url = "https://raw.githubusercontent.com/" .. REPO .. "/" .. manifest.sourceCommit .. "/" .. entry.source
    local bootstrap, err = httpText(url)
    if not bootstrap then error("Cannot bootstrap fleet common: " .. tostring(err), 0) end
    local tmp = "/.fleet_common_bootstrap.lua"
    local f = fs.open(tmp, "w"); if not f then error("Cannot write bootstrap common", 0) end
    f.write(bootstrap); f.close()
    local loader, loadErr = loadfile(tmp)
    if not loader then pcall(fs.delete,tmp); error("Cannot load bootstrap common: " .. tostring(loadErr), 0) end
    local okLoad, module = pcall(loader)
    pcall(fs.delete, tmp)
    if not okLoad or type(module) ~= "table" or type(module.sha1) ~= "function" then error("Bootstrap common invalid", 0) end
    Common = module
end

local required = {}
for _, fileKey in ipairs(manifest.profiles[profile]) do required[fileKey] = true end
required.common = true; required.watchdog = true; required.startup = true; required.updater = true

local downloaded = {}
for key in pairs(required) do
    local entry = manifest.files and manifest.files[key]
    if type(entry) ~= "table" or type(entry.source) ~= "string" or type(entry.target) ~= "string" then
        error("Manifest file entry missing: " .. tostring(key), 0)
    end
    local url = "https://raw.githubusercontent.com/" .. REPO .. "/" .. manifest.sourceCommit .. "/" .. entry.source
    local content, err = httpText(url)
    if not content then error("Download failed " .. key .. ": " .. tostring(err), 0) end
    if tonumber(entry.size) and #content ~= tonumber(entry.size) then error("Size mismatch: " .. key, 0) end
    if entry.hash then
        local hash, hashErr = gitBlob(content)
        if not hash then error("Hash unavailable: " .. tostring(hashErr), 0) end
        if hash ~= entry.hash then error("Hash mismatch: " .. key, 0) end
    end
    downloaded[#downloaded+1] = {key=key, target=entry.target, content=content}
end

-- Commit updater last so a partial update cannot strand us without the current updater.
table.sort(downloaded, function(a,b)
    if a.key == "updater" then return false end
    if b.key == "updater" then return true end
    return a.key < b.key
end)

for _, item in ipairs(downloaded) do
    local ok, err = atomicWrite(item.target, item.content)
    if not ok then error("Install failed " .. item.key .. ": " .. tostring(err), 0) end
end

if not fs.exists(STARTUP_DIR) then fs.makeDir(STARTUP_DIR) end
if action == "install" or not fs.exists(PROFILE_PATH) then
    writeJson(PROFILE_PATH, {schema=1, profile=profile})
end
writeJson(RUNTIME_PATH, {schema=1, version=manifest.version, sourceCommit=manifest.sourceCommit, profile=profile, updatedAt=os.epoch and os.epoch("utc") or 0})
say("Fleet runtime " .. tostring(manifest.version) .. " installed.")
return true
