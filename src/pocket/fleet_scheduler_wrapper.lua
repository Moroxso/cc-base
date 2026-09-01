local Common = require("lib.fleet.common")

local WRAPPER_VERSION = "0.23.0-alpha.5.1"
local CORE_PATH = "/fleet_scheduler_core.lua"
local STATE_PATH = "/data/fleet_scheduler_state.json"
local RUN_CACHE_MS = 500

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local raw = f.readAll()
    f.close()
    local ok, value = pcall(textutils.unserializeJSON, raw)
    return ok and type(value) == "table" and value or nil
end

local cachedRunId = nil
local cachedAt = 0

local function currentRunId()
    local now = Common.nowMs()
    if now - cachedAt < RUN_CACHE_MS then return cachedRunId end
    cachedAt = now
    cachedRunId = nil
    local state = readJson(STATE_PATH)
    if type(state) == "table" and type(state.run) == "table" and not state.run.finished then
        cachedRunId = tostring(state.run.id or "")
        if cachedRunId == "" then cachedRunId = nil end
    end
    return cachedRunId
end

local function completionPayload(statusPayload, lastJob)
    return {
        unit = tonumber(statusPayload.unit),
        event = lastJob.success == true and "DONE" or "FAIL",
        success = lastJob.success == true,
        id = tostring(lastJob.id or ""),
        type = tostring(lastJob.type or "tunnel_roundtrip"),
        phase = "RETURN",
        outbound = math.floor(tonumber(lastJob.outbound) or 0),
        returned = math.floor(tonumber(lastJob.returned) or 0),
        distance = math.floor(tonumber(lastJob.distance) or 0),
        reason = tostring(lastJob.reason or ""),
        recoveries = math.floor(tonumber(lastJob.recoveries) or 0),
        finishedAt = tonumber(lastJob.finishedAt) or 0,
        ledger = true,
    }
end

local originalVerify = Common.verify
Common.verify = function(packet, key, fleetId)
    local valid, err = originalVerify(packet, key, fleetId)
    if not valid then return valid, err end

    if type(packet) == "table" and packet.type == "status" and type(packet.payload) == "table" then
        local p = packet.payload
        local runId = currentRunId()
        local lastJob = type(p.lastJob) == "table" and p.lastJob or nil
        local lastId = lastJob and tostring(lastJob.id or "") or ""
        local noActiveJob = type(p.job) ~= "table"
        local terminalState = p.state == "JOB_DONE" or p.state == "JOB_FAILED"

        if runId and noActiveJob and lastId ~= "" and lastId == runId then
            packet.type = "job_event"
            packet.payload = completionPayload(p, lastJob)
            packet.ttl = 0
        elseif runId and noActiveJob and terminalState then
            -- Never let the alpha.5 core infer completion from a bare terminal state.
            -- A delayed status from an older job is not proof that this run finished.
            packet.type = "job_event"
            packet.payload = {
                unit = tonumber(p.unit),
                event = "VERIFYING",
                id = "__unverified__",
                type = "completion",
                reason = lastId ~= "" and "job_id_mismatch" or "completion_ledger_missing",
                wrapperVersion = WRAPPER_VERSION,
            }
            packet.ttl = 0
        end
    end

    return true
end

local loader, loadErr = loadfile(CORE_PATH, "t", _ENV)
if not loader then error("Scheduler core missing: " .. tostring(loadErr), 0) end
local ok, runErr = pcall(loader)
if not ok then error(runErr, 0) end
