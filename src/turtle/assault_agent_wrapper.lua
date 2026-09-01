local Common = require("lib.fleet.common")

local WRAPPER_VERSION = "0.23.0-alpha.5.1"
local CORE_PATH = "/assault_agent_core.lua"
local LAST_JOB_PATH = "/data/fleet_last_job.json"

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local raw = f.readAll()
    f.close()
    local ok, value = pcall(textutils.unserializeJSON, raw)
    return ok and type(value) == "table" and value or nil
end

local function writeJson(path, value)
    ensureParent(path)
    local ok, raw = pcall(textutils.serializeJSON, value)
    if not ok then return false end
    local tmp = path .. ".tmp"
    if fs.exists(tmp) then pcall(fs.delete, tmp) end
    local f = fs.open(tmp, "w")
    if not f then return false end
    f.write(raw)
    f.close()
    if fs.exists(path) then pcall(fs.delete, path) end
    fs.move(tmp, path)
    return true
end

local function copyLastJob(job)
    if type(job) ~= "table" then return nil end
    return {
        schema = 1,
        id = tostring(job.id or ""),
        type = tostring(job.type or "tunnel_roundtrip"),
        success = job.success == true,
        reason = tostring(job.reason or ""),
        finishedAt = tonumber(job.finishedAt) or 0,
        outbound = math.floor(tonumber(job.outbound) or 0),
        returned = math.floor(tonumber(job.returned) or 0),
        distance = math.floor(tonumber(job.distance) or 0),
        recoveries = math.floor(tonumber(job.recoveries) or 0),
    }
end

local lastJob = copyLastJob(readJson(LAST_JOB_PATH))
local originalNewPacket = Common.newPacket

Common.newPacket = function(config, state, messageType, target, payload, ttl)
    payload = type(payload) == "table" and payload or {}

    if messageType == "job_event" then
        local eventName = tostring(payload.event or "")
        if eventName == "DONE" or eventName == "FAIL" then
            lastJob = {
                schema = 1,
                id = tostring(payload.id or ""),
                type = tostring(payload.type or "tunnel_roundtrip"),
                success = eventName == "DONE" and payload.success ~= false,
                reason = tostring(payload.reason or ""),
                finishedAt = Common.nowMs(),
                outbound = math.floor(tonumber(payload.outbound) or 0),
                returned = math.floor(tonumber(payload.returned) or 0),
                distance = math.floor(tonumber(payload.distance) or 0),
                recoveries = math.floor(tonumber(payload.recoveries) or 0),
            }
            writeJson(LAST_JOB_PATH, lastJob)
            payload.finishedAt = lastJob.finishedAt
        end
    end

    if messageType == "status" or messageType == "result" then
        payload.lastJob = copyLastJob(lastJob)
        if messageType == "status" then
            payload.version = WRAPPER_VERSION
            payload.capabilities = type(payload.capabilities) == "table" and payload.capabilities or {}
            payload.capabilities.completionLedger = true
        end
    end

    return originalNewPacket(config, state, messageType, target, payload, ttl)
end

local loader, loadErr = loadfile(CORE_PATH, "t", _ENV)
if not loader then error("Fleet core missing: " .. tostring(loadErr), 0) end
local ok, runErr = pcall(loader)
if not ok then error(runErr, 0) end
