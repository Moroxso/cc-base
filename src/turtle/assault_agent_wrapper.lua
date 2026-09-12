local Common = require("lib.fleet.common")
local Industrial = require("lib.fleet.industrial")

local WRAPPER_VERSION = "0.23.0-alpha.6.1"
local CORE_PATH = "/assault_agent_core.lua"
local CONFIG_PATH = "/data/fleet_agent.json"
local LAST_JOB_PATH = "/data/fleet_last_job.json"
local INDUSTRIAL_CHECKPOINT_PATH = "/data/fleet_industrial_job.json"
local PREFLIGHT_CACHE_LIMIT = 64

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
    local bak = path .. ".bak"
    if fs.exists(tmp) then pcall(fs.delete, tmp) end
    local f = fs.open(tmp, "w")
    if not f then return false end
    local wrote = pcall(function() f.write(raw) end)
    pcall(function() f.close() end)
    if not wrote then pcall(fs.delete, tmp); return false end
    if fs.exists(bak) then pcall(fs.delete, bak) end
    if fs.exists(path) then
        local backed = pcall(fs.move, path, bak)
        if not backed then pcall(fs.delete, tmp); return false end
    end
    local committed = pcall(fs.move, tmp, path)
    if not committed then
        if fs.exists(bak) and not fs.exists(path) then pcall(fs.move, bak, path) end
        return false
    end
    if fs.exists(bak) then pcall(fs.delete, bak) end
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

local function poseFromConfig(cfg)
    cfg = type(cfg) == "table" and cfg or {}
    local nav = type(cfg.nav) == "table" and cfg.nav or {}
    return {
        x = tonumber(nav.x) or 0,
        y = tonumber(nav.y) or 0,
        z = tonumber(nav.z) or 0,
        heading = math.floor(tonumber(cfg.heading) or 0) % 4,
        frame = tostring(nav.frame or cfg.fleetId or ""),
    }
end

local function copyPose(pose)
    pose = type(pose) == "table" and pose or {}
    return {
        x = tonumber(pose.x) or 0,
        y = tonumber(pose.y) or 0,
        z = tonumber(pose.z) or 0,
        heading = math.floor(tonumber(pose.heading) or 0) % 4,
        frame = tostring(pose.frame or ""),
    }
end

local function headingNumber(value, fallback)
    if type(value) == "number" then return math.floor(value) % 4 end
    local names = {N=0, E=1, S=2, W=3}
    return names[string.upper(tostring(value or ""))] or math.floor(tonumber(fallback) or 0) % 4
end

local agentConfig = readJson(CONFIG_PATH) or {}
local localRole = tostring(agentConfig.role or "ASSAULT")
local latestPose = poseFromConfig(agentConfig)
local lastJob = copyLastJob(readJson(LAST_JOB_PATH))
local industrialCheckpoint = nil

do
    local saved = readJson(INDUSTRIAL_CHECKPOINT_PATH)
    if type(saved) == "table" then
        local normalized = Industrial.normalizeCheckpoint(saved)
        if normalized and normalized.type == Industrial.TYPE_TUNNEL then
            industrialCheckpoint = normalized
        end
    end
end

local preflight = {}
local preflightOrder = {}

local function rememberPreflight(requestId, entry)
    requestId = tostring(requestId or "")
    if requestId == "" then return end
    if preflight[requestId] == nil then
        preflightOrder[#preflightOrder + 1] = requestId
    end
    preflight[requestId] = entry
    while #preflightOrder > PREFLIGHT_CACHE_LIMIT do
        local old = table.remove(preflightOrder, 1)
        preflight[old] = nil
    end
end

local function commandTargetsThis(packet)
    local target = packet.target
    if target == nil or target == "*" then return true end
    if tonumber(target) == os.getComputerID() then return true end
    return tostring(target) == localRole
end

local function tunnelSpecFromJob(job)
    if type(job) ~= "table" or tostring(job.type or "") ~= Industrial.TYPE_TUNNEL then return nil end
    local delay = tonumber(job.delay or job.stepDelay) or Industrial.DEFAULT_DELAY
    delay = math.max(Industrial.MIN_DELAY, math.min(Industrial.MAX_DELAY, delay))
    return {
        type = Industrial.TYPE_TUNNEL,
        distance = job.distance,
        stepDelay = delay,
    }
end

local function updateLatestPose(payload)
    if type(payload) ~= "table" then return end
    local nav = type(payload.navPos) == "table" and payload.navPos or nil
    if nav then
        latestPose.x = tonumber(nav.x) or latestPose.x
        latestPose.y = tonumber(nav.y) or latestPose.y
        latestPose.z = tonumber(nav.z) or latestPose.z
    end
    if payload.navFrame ~= nil then latestPose.frame = tostring(payload.navFrame) end
    if payload.heading ~= nil then latestPose.heading = headingNumber(payload.heading, latestPose.heading) end
end

local function syncIndustrialCheckpoint(job, eventName, pose)
    local spec = tunnelSpecFromJob(job)
    if not spec then return nil end

    local id = tostring(job.id or "")
    if id == "" then return nil end

    if not industrialCheckpoint or industrialCheckpoint.jobId ~= id then
        local cp = Industrial.newCheckpoint(id, spec, pose or latestPose)
        if not cp then return nil end
        industrialCheckpoint = cp
    end

    local cp = industrialCheckpoint
    cp.spec = Industrial.normalizeSpec(spec) or cp.spec
    local plan = Industrial.plan(cp.spec)
    if plan then
        cp.plan = {
            volume = plan.volume,
            workMoves = plan.workMoves,
            returnMoves = plan.returnMoves,
            estimatedMoves = plan.estimatedMoves,
            fuelRequired = plan.fuelRequired,
            fuelReserve = plan.fuelReserve,
        }
    end

    local phase = tostring(job.phase or cp.phase or "OUT")
    if eventName == "DONE" then phase = "DONE"
    elseif eventName == "FAIL" then phase = "FAILED"
    elseif eventName == "RETURN" then phase = "RETURN"
    elseif phase ~= "OUT" and phase ~= "RETURN" and phase ~= "DONE" and phase ~= "FAILED" then phase = "OUT" end
    cp.phase = phase

    cp.progress = type(cp.progress) == "table" and cp.progress or {}
    cp.progress.completed = math.max(0, math.floor(tonumber(job.outbound) or tonumber(cp.progress.completed) or 0))
    cp.progress.returned = math.max(0, math.floor(tonumber(job.returned) or tonumber(cp.progress.returned) or 0))
    cp.progress.cursor = cp.progress.completed
    cp.progress.layer = 0

    cp.pose = copyPose(pose or latestPose)
    cp.reason = tostring(job.reason or cp.reason or "")
    cp.stats = type(cp.stats) == "table" and cp.stats or {}
    cp.stats.moves = math.max(0, cp.progress.completed + cp.progress.returned)
    cp.stats.digs = math.max(0, math.floor(tonumber(cp.stats.digs) or 0))
    cp.stats.unloaded = 0
    cp.stats.refuels = math.max(0, math.floor(tonumber(cp.stats.refuels) or 0))
    cp.stats.recoveries = math.max(0, math.floor(tonumber(job.recoveries) or tonumber(cp.stats.recoveries) or 0))
    cp.savedAt = Common.nowMs()

    local normalized = Industrial.normalizeCheckpoint(cp)
    if normalized then industrialCheckpoint = normalized end
    writeJson(INDUSTRIAL_CHECKPOINT_PATH, industrialCheckpoint)
    return industrialCheckpoint
end

local function industrialSummary(job, requestId)
    local cp
    if type(job) == "table" then cp = syncIndustrialCheckpoint(job, nil, latestPose) end
    local plan
    if requestId ~= nil then
        local entry = preflight[tostring(requestId)]
        plan = entry and entry.plan or nil
    end
    if not plan and cp and type(cp.plan) == "table" then plan = cp.plan end
    if not cp and not plan then return nil end
    return {
        engineVersion = Industrial.VERSION,
        checkpointSchema = Industrial.CHECKPOINT_SCHEMA,
        type = cp and cp.type or Industrial.TYPE_TUNNEL,
        phase = cp and cp.phase or nil,
        completed = cp and cp.progress and cp.progress.completed or nil,
        returned = cp and cp.progress and cp.progress.returned or nil,
        fuelRequired = plan and plan.fuelRequired or nil,
        fuelReserve = plan and plan.fuelReserve or nil,
        checkpoint = cp and INDUSTRIAL_CHECKPOINT_PATH or nil,
    }
end

local originalVerify = Common.verify
local originalNewPacket = Common.newPacket

Common.verify = function(packet, key, fleetId)
    local valid, verifyErr = originalVerify(packet, key, fleetId)
    if not valid then return valid, verifyErr end

    if localRole == "ASSAULT" and commandTargetsThis(packet) and packet.type == "command" then
        local payload = type(packet.payload) == "table" and packet.payload or {}
        if tostring(payload.command or "") == "job_tunnel_roundtrip" then
            local args = type(payload.args) == "table" and payload.args or {}
            payload.args = args
            local delay = tonumber(args.stepDelay) or Industrial.DEFAULT_DELAY
            delay = math.max(Industrial.MIN_DELAY, math.min(Industrial.MAX_DELAY, delay))
            local plan, planErr = Industrial.plan({
                type = Industrial.TYPE_TUNNEL,
                distance = args.distance,
                stepDelay = delay,
            })
            local requestId = tostring(payload.requestId or "")
            if plan then
                args.distance = plan.spec.distance
                args.stepDelay = plan.spec.stepDelay
                args.industrialFuelRequired = plan.fuelRequired
                rememberPreflight(requestId, {plan=plan})
            else
                -- Preserve the core result/command path instead of dropping a valid
                -- signed command silently. distance=0 makes the unchanged core
                -- reject it; the outgoing result is rewritten with the planner error.
                args.distance = 0
                rememberPreflight(requestId, {error=tostring(planErr or "industrial_preflight")})
            end
        end
    end

    return valid, verifyErr
end

Common.newPacket = function(config, state, messageType, target, payload, ttl)
    payload = type(payload) == "table" and payload or {}

    if messageType == "job_event" then
        local eventName = tostring(payload.event or "")
        syncIndustrialCheckpoint(payload, eventName, latestPose)
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
        payload.industrial = industrialSummary(payload)
    end

    if messageType == "status" then
        updateLatestPose(payload)
        if type(payload.job) == "table" then syncIndustrialCheckpoint(payload.job, nil, latestPose) end
        payload.lastJob = copyLastJob(lastJob)
        payload.version = WRAPPER_VERSION
        payload.capabilities = type(payload.capabilities) == "table" and payload.capabilities or {}
        payload.capabilities.completionLedger = true
        if localRole == "ASSAULT" then
            payload.capabilities.industrialJobs = true
            payload.capabilities.industrialTunnel = true
            payload.capabilities.industrialCheckpoint = true
            payload.industrial = industrialSummary(payload.job)
        end
    elseif messageType == "result" then
        payload.lastJob = copyLastJob(lastJob)
        local requestId = tostring(payload.requestId or "")
        local entry = preflight[requestId]
        if entry and entry.error and tostring(payload.command or "") == "job_tunnel_roundtrip" then
            payload.ok = false
            payload.detail = "industrial_preflight:" .. tostring(entry.error)
        end
        if type(payload.job) == "table" then syncIndustrialCheckpoint(payload.job, nil, latestPose) end
        payload.industrial = industrialSummary(payload.job, requestId)
    end

    return originalNewPacket(config, state, messageType, target, payload, ttl)
end

local loader, loadErr = loadfile(CORE_PATH, "t", _ENV)
if not loader then error("Fleet core missing: " .. tostring(loadErr), 0) end
local ok, runErr = pcall(loader)
if not ok then error(runErr, 0) end
