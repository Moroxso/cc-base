local Common = require("lib.fleet.common")

local VERSION = "0.23.0-alpha.5.3"
local CONFIG_PATH = "/data/fleet_operator.json"
local CACHE_PATH = "/data/fleet_units_cache.json"
local PERF_PATH = "/data/fleet_performance.json"
local STATE_PATH = "/data/fleet_performance_state.json"

local UNIT_STALE_MS = 30000
local RETRY_TICK = 0.10
local RETRY_DELAYS_MS = {400, 1100, 2400, 4200}
local PENDING_TTL_MS = 9000
local DISCOVERY_DIRECT_MS = 10000
local DISCOVERY_MESH_MS = 45000
local STATE_FLUSH_MS = 1000
local BENCHMARK_COOLDOWN_MS = 10000
local DISPATCH_INTERVAL_MS = 750
local MAX_PROFILE_SESSIONS = 5

-- Keep load control deliberately slow. Measurements are frequent; decisions are not.
local CONTROL_EPOCH_MS = 30000
local CONTROL_CHANGE_COOLDOWN_MS = 60000
local CONTROL_BAD_THRESHOLD = 0.80
local CONTROL_GOOD_THRESHOLD = 0.92
local CONTROL_REQUIRED_EPOCHS = 2
local CONTROL_STEP = 2

local DEFAULT_DELAY = 0.25
local DELAY_CANDIDATES = {0.10, 0.15, 0.20, 0.25, 0.35}

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

local function median(values)
    if #values == 0 then return nil end
    local copy = {}
    for i, value in ipairs(values) do copy[i] = value end
    table.sort(copy)
    local n = #copy
    if n % 2 == 1 then return copy[(n + 1) / 2] end
    return (copy[n / 2] + copy[n / 2 + 1]) / 2
end

local function normalizeTransport(value)
    value = string.upper(tostring(value or "AUTO"))
    if value ~= "DIRECT" and value ~= "MESH" then value = "AUTO" end
    return value
end

local config = readJson(CONFIG_PATH)
if type(config) ~= "table" or type(config.fleetId) ~= "string" or type(config.key) ~= "string" then
    error("Fleet operator config missing. Run Fleet Control once first.", 0)
end
config.schema = math.max(7, tonumber(config.schema) or 0)
config.transportMode = normalizeTransport(config.transportMode)
config.relay = config.relay ~= false

local function confidence(samples)
    samples = math.max(0, math.floor(tonumber(samples) or 0))
    if samples >= 8 then return "HIGH" end
    if samples >= 4 then return "MEDIUM" end
    return "LOW"
end

local function trimSessions(list)
    while #list > MAX_PROFILE_SESSIONS do table.remove(list, 1) end
end

local function normalizePerformance(raw)
    raw = type(raw) == "table" and raw or {}
    if raw.schema == 2 then
        raw.delaySessions = type(raw.delaySessions) == "table" and raw.delaySessions or {}
        raw.concurrencySessions = type(raw.concurrencySessions) == "table" and raw.concurrencySessions or {}
        return raw
    end

    local migrated = {
        schema = 2,
        fleetId = tostring(raw.fleetId or config.fleetId),
        updatedAt = tonumber(raw.updatedAt) or 0,
        delaySessions = {},
        concurrencySessions = {},
        bestDelay = tonumber(raw.bestDelay),
    }

    -- Alpha 5.2 stored only per-setting medians. Preserve them as one historical sample.
    if type(raw.summary) == "table" and #raw.summary > 0 then
        local trials = {}
        for _, item in ipairs(raw.summary) do
            local delay = tonumber(item.delay)
            local duration = tonumber(item.medianDurationMs)
            local rate = tonumber(item.medianBps)
            if delay and duration then
                trials[#trials + 1] = {
                    setting = delay,
                    durationMs = duration,
                    excavationBps = rate,
                    valid = true,
                    imported = true,
                }
            end
        end
        if #trials > 0 then
            migrated.delaySessions[1] = {
                kind = "delay",
                completedAt = tonumber(raw.updatedAt) or 0,
                unitCount = tonumber(raw.unitCount) or 0,
                distance = tonumber(raw.distance) or 0,
                repeats = tonumber(raw.repeats) or 1,
                trials = trials,
                imported = true,
            }
        end
    end
    return migrated
end

local performance = normalizePerformance(readJson(PERF_PATH))

local function rebuildPerformance()
    local function summarize(sessions, settingField)
        local groups = {}
        for _, session in ipairs(sessions) do
            for _, trial in ipairs(type(session.trials) == "table" and session.trials or {}) do
                if trial.valid ~= false then
                    local setting = tonumber(trial[settingField] or trial.setting)
                    local duration = tonumber(trial.durationMs)
                    local rate = tonumber(trial.excavationBps)
                    if setting and duration then
                        local key = tostring(setting)
                        local group = groups[key]
                        if not group then
                            group = {setting = setting, durations = {}, rates = {}, autoTargets = {}}
                            groups[key] = group
                        end
                        group.durations[#group.durations + 1] = duration
                        if rate then group.rates[#group.rates + 1] = rate end
                        if tonumber(trial.maxAutoTarget) then group.autoTargets[#group.autoTargets + 1] = tonumber(trial.maxAutoTarget) end
                    end
                end
            end
        end
        local summary = {}
        for _, group in pairs(groups) do
            summary[#summary + 1] = {
                setting = group.setting,
                samples = #group.durations,
                medianDurationMs = median(group.durations),
                medianBps = median(group.rates),
                medianAutoTarget = median(group.autoTargets),
            }
        end
        table.sort(summary, function(a, b)
            if a.setting == -1 then return false end
            if b.setting == -1 then return true end
            return a.setting < b.setting
        end)
        return summary
    end

    performance.delaySessions = type(performance.delaySessions) == "table" and performance.delaySessions or {}
    performance.concurrencySessions = type(performance.concurrencySessions) == "table" and performance.concurrencySessions or {}
    trimSessions(performance.delaySessions)
    trimSessions(performance.concurrencySessions)

    local delays = summarize(performance.delaySessions, "delay")
    local concurrencies = summarize(performance.concurrencySessions, "concurrency")
    local bestDelay, bestConcurrency
    for _, item in ipairs(delays) do
        if item.medianDurationMs and (not bestDelay or item.medianDurationMs < bestDelay.medianDurationMs) then bestDelay = item end
    end
    for _, item in ipairs(concurrencies) do
        if item.medianDurationMs and (not bestConcurrency or item.medianDurationMs < bestConcurrency.medianDurationMs) then bestConcurrency = item end
    end

    performance.schema = 2
    performance.fleetId = config.fleetId
    performance.updatedAt = Common.nowMs()
    performance.delaySummary = delays
    performance.concurrencySummary = concurrencies
    if bestDelay then
        performance.bestDelay = bestDelay.setting
        performance.delaySamples = bestDelay.samples
        performance.delayConfidence = confidence(bestDelay.samples)
    end
    if bestConcurrency then
        performance.bestConcurrency = bestConcurrency.setting
        performance.concurrencySamples = bestConcurrency.samples
        performance.concurrencyConfidence = confidence(bestConcurrency.samples)
        performance.bestAutoTarget = bestConcurrency.setting == -1 and bestConcurrency.medianAutoTarget or nil
    end
end

rebuildPerformance()
writeJson(PERF_PATH, performance)

local function recommendedDelay()
    local value = tonumber(performance.bestDelay)
    if value and value >= 0.05 and value <= 2 then return value end
    return DEFAULT_DELAY
end

local function concurrencyLabel(value, total)
    value = tonumber(value)
    if value == -1 then return "AUTO" end
    if value == 0 or (total and value and value >= total) then return "ALL" end
    return tostring(math.floor(value or 0))
end

local function recommendedConcurrency(total)
    local value = tonumber(performance.bestConcurrency)
    if value == -1 then return -1 end
    if value and value > 0 then return math.min(math.floor(value), total) end
    return -1
end

local mesh = {bootId = Common.randomHex(12), seq = 0}
local seen = Common.newSeenCache()
local units = {}
local pending = {}
local commandSeq = 0
local benchmark = nil
local currentRun = nil
local stateDirty = false
local cacheDirty = false
local appRunning = true
local message = "Performance Lab ready"
local lastDispatchAt = 0

local function loadCache()
    local raw = readJson(CACHE_PATH)
    if type(raw) ~= "table" then return end
    for key, value in pairs(raw) do
        local id = tonumber(type(value) == "table" and value.id or key)
        if id and type(value) == "table" then
            value.id = id
            value.lastSeen = tonumber(value.lastSeen) or 0
            value.capabilities = type(value.capabilities) == "table" and value.capabilities or {}
            value.route = tostring(value.route or "?")
            units[id] = value
        end
    end
end

local function saveCache()
    local out = {}
    for id, u in pairs(units) do
        out[tostring(id)] = {
            id=id, name=u.name, role=u.role, state=u.state, linkState=u.linkState,
            fuel=u.fuel, version=u.version, lastSeen=u.lastSeen, hops=u.hops,
            route=u.route, rttMs=u.rttMs, job=u.job, lastJob=u.lastJob,
            navPos=u.navPos, heading=u.heading, capabilities=u.capabilities,
        }
    end
    cacheDirty = false
    return writeJson(CACHE_PATH, out)
end

local function saveState()
    stateDirty = false
    if not (benchmark and benchmark.active) and not (currentRun and not currentRun.finished) then
        if fs.exists(STATE_PATH) then pcall(fs.delete, STATE_PATH) end
        return true
    end
    return writeJson(STATE_PATH, {
        schema = 1,
        savedAt = Common.nowMs(),
        benchmark = benchmark,
        run = currentRun,
    })
end

local function loadState()
    local raw = readJson(STATE_PATH)
    if type(raw) ~= "table" then return end
    if type(raw.benchmark) == "table" and raw.benchmark.active then
        benchmark = raw.benchmark
        benchmark.cooldownUntil = math.max(Common.nowMs() + 3000, tonumber(benchmark.cooldownUntil) or 0)
    end
    if type(raw.run) == "table" and not raw.run.finished then
        currentRun = raw.run
        currentRun.resumeAt = Common.nowMs()
        for _, r in pairs(type(currentRun.units) == "table" and currentRun.units or {}) do
            local s = tostring(r.state or "")
            if s ~= "DONE" and s ~= "FAILED" and s ~= "CANCELED" and s ~= "QUEUED" then
                r.state = "VERIFYING"
            end
        end
        message = "Recovered benchmark run; verifying units"
    end
end

loadCache()
loadState()

local function ensureUnit(id)
    local u = units[id]
    if not u then
        u = {id=id, name="Unit-"..tostring(id), role="ASSAULT", state="?", lastSeen=0, route="?", capabilities={}}
        units[id] = u
    end
    return u
end

local function sendPacket(kind, target, payload, ttl)
    local packet, err = Common.newPacket(config, mesh, kind, target, payload, ttl)
    if not packet then return false, err end
    Common.markSeen(seen, Common.packetId(packet))
    return Common.broadcast(packet)
end

local function packetHops(packet)
    return math.max(0, Common.DEFAULT_TTL - math.max(0, tonumber(packet.ttl) or 0))
end

local function markRoute(u, packet, rtt)
    local hops = packetHops(packet)
    u.hops = hops
    u.route = hops == 0 and "DIRECT" or ("MESH/" .. tostring(hops))
    if rtt then u.rttMs = math.floor(rtt + 0.5) end
    cacheDirty = true
end

local function routeTtl(attempt)
    if config.transportMode == "DIRECT" then return 0 end
    if config.transportMode == "MESH" then return Common.DEFAULT_TTL end
    if attempt <= 1 then return 0 end
    return Common.DEFAULT_TTL
end

local function relay(packet)
    if config.transportMode ~= "MESH" or not config.relay or tonumber(packet.ttl) == nil or packet.ttl <= 0 then return end
    local forwarded = Common.forwardPacket(packet, config.key)
    if forwarded then Common.broadcast(forwarded) end
end

local function sendDiscovery(meshScan)
    local ttl
    if config.transportMode == "DIRECT" then ttl = 0
    elseif config.transportMode == "MESH" then ttl = Common.DEFAULT_TTL
    elseif meshScan then ttl = Common.DEFAULT_TTL else ttl = 0 end
    sendPacket("discover", "*", {operator=os.getComputerID(), app="performance", version=VERSION, transport=config.transportMode}, ttl)
end

local function sendBeacon()
    local ttl = config.transportMode == "MESH" and Common.DEFAULT_TTL or 0
    sendPacket("operator_status", "*", {operator=os.getComputerID(), app="performance", version=VERSION, transport=config.transportMode}, ttl)
end

local function onlineAssaults()
    local now = Common.nowMs()
    local list = {}
    for _, u in pairs(units) do
        if tostring(u.role) == "ASSAULT" and now - (tonumber(u.lastSeen) or 0) <= UNIT_STALE_MS then list[#list + 1] = u end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

local function selectedUnits()
    if not benchmark or type(benchmark.unitIds) ~= "table" then return nil end
    local now = Common.nowMs()
    local list = {}
    for _, id in ipairs(benchmark.unitIds) do
        local u = units[tonumber(id)]
        if not u or now - (tonumber(u.lastSeen) or 0) > UNIT_STALE_MS then return nil end
        list[#list + 1] = u
    end
    return list
end

local ACTIVE_STATES = {DISPATCHED=true, RUNNING=true, RETURN=true, STALLED=true, VERIFYING=true, CANCELING=true}

local function countRunStates()
    local queued, active, done, failed, canceled, stalled = 0, 0, 0, 0, 0, 0
    if not currentRun then return queued, active, done, failed, canceled, stalled end
    for _, r in pairs(currentRun.units or {}) do
        local s = tostring(r.state or "")
        if s == "QUEUED" then queued = queued + 1
        elseif ACTIVE_STATES[s] then active = active + 1; if s == "STALLED" then stalled = stalled + 1 end
        elseif s == "DONE" then done = done + 1
        elseif s == "CANCELED" then canceled = canceled + 1
        else failed = failed + 1 end
    end
    return queued, active, done, failed, canceled, stalled
end

local function runProgress()
    local total = 0
    for _, r in pairs(currentRun and currentRun.units or {}) do
        total = total + math.max(0, tonumber(r.outbound) or 0) + math.max(0, tonumber(r.returned) or 0)
    end
    return total
end

local function issueToUnit(command, args, unitId, purpose)
    commandSeq = commandSeq + 1
    local now = Common.nowMs()
    local rid = string.format("%d:%s:%d", os.getComputerID(), mesh.bootId, commandSeq)
    local payload = {
        operator=os.getComputerID(), operatorBoot=mesh.bootId, commandSeq=commandSeq,
        issuedAt=now, requestId=rid, command=command, args=type(args)=="table" and args or {},
    }
    local item = {target=unitId, payload=payload, purpose=purpose, unitId=unitId, attempts=0, firstSentAt=now, nextRetry=0, expires=now+PENDING_TTL_MS}
    pending[rid] = item
    local function transmit()
        item.attempts = item.attempts + 1
        local ok, err = sendPacket("command", item.target, item.payload, routeTtl(item.attempts))
        item.lastSentAt = Common.nowMs()
        item.nextRetry = item.lastSentAt + RETRY_DELAYS_MS[math.min(item.attempts, #RETRY_DELAYS_MS)]
        if not ok then message = "send failed: " .. tostring(err) end
    end
    item.transmit = transmit
    transmit()
    return rid
end

local function retryPending()
    local now = Common.nowMs()
    for rid, item in pairs(pending) do
        if now >= item.expires then
            pending[rid] = nil
            if item.purpose == "START" and currentRun then
                local r = currentRun.units[tostring(item.unitId)]
                if r and r.state == "DISPATCHED" then
                    r.state = "VERIFYING"
                    r.reason = "dispatch_timeout_verify"
                    currentRun.healthPenalty = (tonumber(currentRun.healthPenalty) or 0) + 1
                    stateDirty = true
                end
            end
        elseif now >= item.nextRetry and item.attempts < #RETRY_DELAYS_MS then
            item.transmit()
        end
    end
end

local function initialAutoTarget(total)
    if total <= 4 then return total end
    if total <= 8 then return 4 end
    return math.min(total, 6)
end

local function concurrencyLimit()
    if not currentRun then return 0 end
    local spec = tonumber(currentRun.concurrency) or 0
    if spec == 0 then return currentRun.total end
    if spec == -1 then return math.max(1, math.floor(tonumber(currentRun.autoTarget) or 1)) end
    return math.max(1, math.min(currentRun.total, math.floor(spec)))
end

local function dispatchQueued()
    if not currentRun or currentRun.finished or currentRun.canceled then return end
    local now = Common.nowMs()
    if now - lastDispatchAt < DISPATCH_INTERVAL_MS then return end
    local _, active = countRunStates()
    if active >= concurrencyLimit() then return end
    for _, id in ipairs(currentRun.order or {}) do
        local r = currentRun.units[tostring(id)]
        if r and r.state == "QUEUED" then
            r.state = "DISPATCHED"
            r.dispatchAt = now
            issueToUnit("job_tunnel_roundtrip", {jobId=currentRun.id, distance=currentRun.distance, stepDelay=currentRun.delay}, id, "START")
            lastDispatchAt = now
            stateDirty = true
            return
        end
    end
end

local function governorStep()
    if not currentRun or currentRun.finished or tonumber(currentRun.concurrency) ~= -1 then return end
    local now = Common.nowMs()
    local c = currentRun.control
    if type(c) ~= "table" then
        currentRun.control = {lastEpochAt=now, lastChangeAt=now, prevProgress=runProgress(), prevRate=nil, goodEpochs=0, badEpochs=0, maxTarget=currentRun.autoTarget}
        stateDirty = true
        return
    end
    if now - (tonumber(c.lastEpochAt) or now) < CONTROL_EPOCH_MS then return end

    local progress = runProgress()
    local elapsed = math.max(1, now - (tonumber(c.lastEpochAt) or now))
    local rate = math.max(0, progress - (tonumber(c.prevProgress) or 0)) / (elapsed / 1000)
    local queued, active, _, _, _, stalled = countRunStates()
    local target = math.max(1, math.floor(tonumber(currentRun.autoTarget) or 1))
    local health = tonumber(currentRun.healthPenalty) or 0
    local changed = false

    if stalled > 0 or health > 0 then
        c.badEpochs = (tonumber(c.badEpochs) or 0) + 1
        c.goodEpochs = 0
    elseif tonumber(c.prevRate) then
        if rate < c.prevRate * CONTROL_BAD_THRESHOLD then
            c.badEpochs = (tonumber(c.badEpochs) or 0) + 1
            c.goodEpochs = 0
        elseif rate >= c.prevRate * CONTROL_GOOD_THRESHOLD then
            c.goodEpochs = (tonumber(c.goodEpochs) or 0) + 1
            c.badEpochs = 0
        else
            c.goodEpochs, c.badEpochs = 0, 0
        end
    else
        c.goodEpochs = 1
    end

    local canChange = now - (tonumber(c.lastChangeAt) or 0) >= CONTROL_CHANGE_COOLDOWN_MS
    if canChange and (tonumber(c.badEpochs) or 0) >= CONTROL_REQUIRED_EPOCHS then
        local nextTarget = math.max(2, target - CONTROL_STEP)
        if nextTarget ~= target then currentRun.autoTarget = nextTarget; c.lastChangeAt = now; changed = true end
        c.badEpochs = 0
    elseif canChange and queued > 0 and active >= target and (tonumber(c.goodEpochs) or 0) >= CONTROL_REQUIRED_EPOCHS then
        local nextTarget = math.min(currentRun.total, target + CONTROL_STEP)
        if nextTarget ~= target then currentRun.autoTarget = nextTarget; c.lastChangeAt = now; changed = true end
        c.goodEpochs = 0
    end

    c.lastEpochAt = now
    c.prevProgress = progress
    c.prevRate = rate
    c.lastRate = rate
    c.maxTarget = math.max(tonumber(c.maxTarget) or target, tonumber(currentRun.autoTarget) or target)
    currentRun.healthPenalty = 0
    stateDirty = true
    if changed then message = string.format("AUTO target %d rate %.2f/s", currentRun.autoTarget, rate) end
end

local function finishRunUnit(id, success, reason, finishedAt)
    if not currentRun then return end
    local r = currentRun.units[tostring(id)]
    if not r or r.state == "DONE" or r.state == "FAILED" or r.state == "CANCELED" then return end
    local now = Common.nowMs()
    local stamp = tonumber(finishedAt)
    if not stamp or stamp <= 0 or math.abs(now - stamp) > 86400000 then stamp = now end
    r.doneAt = stamp
    r.reason = tostring(reason or "")
    r.state = currentRun.canceled and "CANCELED" or (success and "DONE" or "FAILED")
    stateDirty = true
end

local function completionFromLedger(id, lastJob)
    if not currentRun or type(lastJob) ~= "table" then return false end
    if tostring(lastJob.id or "") ~= tostring(currentRun.id) then return false end
    finishRunUnit(id, lastJob.success == true, lastJob.reason or "complete", lastJob.finishedAt)
    return true
end

local function markRunning(id, job, now)
    if not currentRun or tostring(job and job.id or "") ~= tostring(currentRun.id) then return end
    local r = currentRun.units[tostring(id)]
    if not r or r.state == "DONE" or r.state == "FAILED" or r.state == "CANCELED" then return end
    if not r.startAt then r.startAt = now end
    r.outbound = tonumber(job.outbound) or r.outbound or 0
    r.returned = tonumber(job.returned) or r.returned or 0
    r.phase = tostring(job.phase or r.phase or "OUT")
    r.state = job.stalled and "STALLED" or (r.phase == "RETURN" and "RETURN" or "RUNNING")
    if job.stalled then currentRun.healthPenalty = (tonumber(currentRun.healthPenalty) or 0) + 1 end
    stateDirty = true
end

local function reconcileStatus(id, p, now)
    if not currentRun or currentRun.finished then return end
    local r = currentRun.units[tostring(id)]
    if not r then return end
    if type(p.job) == "table" and tostring(p.job.id or "") == tostring(currentRun.id) then markRunning(id, p.job, now); return end
    if completionFromLedger(id, p.lastJob) then return end
    if ACTIVE_STATES[tostring(r.state or "")] then
        r.state = "VERIFYING"
        r.reason = "awaiting_matching_completion"
        stateDirty = true
    end
end

local function handlePacket(packet, protocol)
    if protocol ~= Common.REDNET_PROTOCOL then return end
    local valid = Common.verify(packet, config.key, config.fleetId)
    if not valid then return end
    local pid = Common.packetId(packet)
    if Common.seen(seen, pid) then return end
    Common.markSeen(seen, pid)
    local now = Common.nowMs()

    if packet.type == "status" then
        local p = packet.payload
        local id = tonumber(p.unit or packet.origin)
        if id then
            local u = ensureUnit(id)
            u.name=tostring(p.name or u.name); u.role=tostring(p.role or u.role); u.state=tostring(p.state or u.state)
            u.lastSeen=now; u.job=p.job; u.lastJob=p.lastJob or u.lastJob; u.version=p.version or u.version
            u.capabilities=p.capabilities or u.capabilities or {}; markRoute(u, packet); reconcileStatus(id, p, now)
        end
    elseif packet.type == "job_event" then
        local p = packet.payload
        local id = tonumber(p.unit or packet.origin)
        if id then
            local u = ensureUnit(id); u.lastSeen=now; markRoute(u, packet)
            if currentRun and tostring(p.id or "") == tostring(currentRun.id) then
                local event = tostring(p.event or "")
                if event == "DONE" then finishRunUnit(id, true, p.reason or "complete", p.finishedAt)
                elseif event == "FAIL" then finishRunUnit(id, false, p.reason or "failed", p.finishedAt)
                else markRunning(id, p, now) end
            end
        end
    elseif packet.type == "result" then
        local p = packet.payload
        local id = tonumber(p.unit or packet.origin)
        local item = pending[tostring(p.requestId or "")]
        if id then
            local u = ensureUnit(id); u.lastSeen=now; u.lastJob=p.lastJob or u.lastJob
            markRoute(u, packet, item and (now-item.firstSentAt) or nil)
            if type(p.job) == "table" then markRunning(id, p.job, now) else completionFromLedger(id, p.lastJob) end
        end
        if item then
            pending[tostring(p.requestId or "")] = nil
            local r = currentRun and currentRun.units[tostring(item.unitId)]
            if r and item.purpose == "START" and not p.ok and r.state == "DISPATCHED" then
                finishRunUnit(item.unitId, false, tostring(p.detail or "start_rejected"))
            end
        end
    end
    relay(packet)
    cacheDirty = true
    os.queueEvent("perf_redraw")
end

local function buildConcurrencyCandidates(total)
    local out, seenValues = {}, {}
    local function add(value)
        if value > 0 then value = math.min(total, math.floor(value)) end
        local key = tostring(value)
        if not seenValues[key] then seenValues[key] = true; out[#out + 1] = value end
    end
    if total <= 3 then add(total) else add(4) end
    add(6); add(10); add(14); add(total); add(-1)
    local filtered = {}
    for _, value in ipairs(out) do
        if value == -1 or (value > 0 and value <= total) then filtered[#filtered + 1] = value end
    end
    return filtered
end

local function startRun(setting)
    local list = selectedUnits()
    if not list or #list ~= benchmark.count then return false, "selected_units_offline" end
    local delay = benchmark.kind == "delay" and tonumber(setting) or tonumber(benchmark.delay)
    local concurrency = benchmark.kind == "concurrency" and tonumber(setting) or 0
    local now = Common.nowMs()
    local run = {
        id = string.format("PERF-%d-%d", os.getComputerID(), now),
        kind = benchmark.kind,
        setting = setting,
        distance = benchmark.distance,
        delay = delay,
        concurrency = concurrency,
        total = #list,
        startedAt = now,
        units = {}, order = {}, canceled = false, finished = false,
        healthPenalty = 0,
    }
    if concurrency == -1 then
        run.autoTarget = initialAutoTarget(#list)
        run.control = {lastEpochAt=now, lastChangeAt=now, prevProgress=0, prevRate=nil, goodEpochs=0, badEpochs=0, maxTarget=run.autoTarget}
    end
    for _, u in ipairs(list) do
        run.order[#run.order + 1] = u.id
        run.units[tostring(u.id)] = {id=u.id, state="QUEUED", route=u.route or "?"}
    end
    currentRun = run
    lastDispatchAt = 0
    stateDirty = true
    saveState()
    return true
end

local function finalizeRun()
    if not currentRun or currentRun.finished then return false end
    local queued, active, done, failed, canceled = countRunStates()
    if queued > 0 or active > 0 then return false end
    local now = Common.nowMs()
    currentRun.finished = true
    currentRun.finishedAt = now
    local duration = math.max(1, now - (tonumber(currentRun.startedAt) or now))
    local result = {
        kind = currentRun.kind,
        setting = currentRun.setting,
        delay = currentRun.delay,
        concurrency = currentRun.concurrency,
        total = currentRun.total,
        done = done,
        failed = failed,
        canceled = canceled,
        durationMs = duration,
        excavationBps = (done * currentRun.distance) / (duration / 1000),
        valid = done == currentRun.total and failed == 0 and canceled == 0,
        maxAutoTarget = currentRun.control and currentRun.control.maxTarget or nil,
    }
    return true, result
end

local function finishBenchmark()
    local session = {
        kind = benchmark.kind,
        completedAt = Common.nowMs(),
        unitCount = benchmark.count,
        distance = benchmark.distance,
        repeats = benchmark.repeats,
        fixedDelay = benchmark.delay,
        trials = benchmark.results,
    }
    if benchmark.kind == "delay" then
        performance.delaySessions[#performance.delaySessions + 1] = session
    else
        performance.concurrencySessions[#performance.concurrencySessions + 1] = session
    end
    performance.lastUnitCount = benchmark.count
    performance.lastDistance = benchmark.distance
    rebuildPerformance()
    writeJson(PERF_PATH, performance)
    benchmark.active = false
    currentRun = nil
    stateDirty = true
    saveState()
    local rec = benchmark.kind == "delay" and string.format("delay %.2f", recommendedDelay())
        or ("concurrency " .. concurrencyLabel(recommendedConcurrency(benchmark.count), benchmark.count))
    message = "Benchmark complete; recommended " .. rec
end

local function advanceBenchmark(result)
    benchmark.results[#benchmark.results + 1] = result
    benchmark.repeatIndex = benchmark.repeatIndex + 1
    if benchmark.repeatIndex > benchmark.repeats then
        benchmark.repeatIndex = 1
        benchmark.settingIndex = benchmark.settingIndex + 1
    end
    currentRun = nil
    if benchmark.settingIndex > #benchmark.settings then
        finishBenchmark()
    else
        benchmark.cooldownUntil = Common.nowMs() + BENCHMARK_COOLDOWN_MS
        stateDirty = true
        saveState()
    end
end

local function benchmarkStep()
    if not benchmark or not benchmark.active then return end
    if currentRun and not currentRun.finished then return end
    local now = Common.nowMs()
    if now < (tonumber(benchmark.cooldownUntil) or 0) then return end
    local list = selectedUnits()
    if not list then
        message = "Benchmark waiting for selected units"
        return
    end
    local setting = benchmark.settings[benchmark.settingIndex]
    local ok, err = startRun(setting)
    if ok then
        local label = benchmark.kind == "delay" and string.format("%.2f", setting) or concurrencyLabel(setting, benchmark.count)
        message = string.format("%s %s repeat %d/%d", benchmark.kind, label, benchmark.repeatIndex, benchmark.repeats)
    else
        message = "Cannot start benchmark: " .. tostring(err)
    end
end

local function ask(prompt, default)
    write(prompt .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
    local value = read()
    if value == "" and default ~= nil then return tostring(default) end
    return value
end

local function confirm(text)
    term.clear(); term.setCursorPos(1,1)
    print(text)
    print("Y=CONFIRM N/ESC=CANCEL")
    while true do
        local e, a = os.pullEvent()
        if e == "char" then
            if a:lower() == "y" then return true elseif a:lower() == "n" then return false end
        elseif e == "key" then
            if a == keys.y then return true end
            if a == keys.n or a == keys.escape then return false end
        end
    end
end

local function armBenchmark(kind)
    if benchmark and benchmark.active then message = "Benchmark already active"; return end
    if currentRun and not currentRun.finished then message = "Run still active"; return end
    sendDiscovery(false)
    local online = onlineAssaults()
    if #online == 0 then message = "No online ASSAULT units"; return end

    term.clear(); term.setCursorPos(1,1)
    print(kind == "delay" and "Fleet Delay Benchmark" or "Fleet Concurrency Benchmark")
    local count = math.floor(tonumber(ask("Units", #online)) or #online)
    local distance = math.floor(tonumber(ask("Distance blocks", 50)) or 50)
    local repeats = math.floor(tonumber(ask("Repeats per setting", 2)) or 2)
    count = math.max(1, math.min(#online, count))
    repeats = math.max(1, math.min(5, repeats))
    if distance < 1 or distance > 4096 then message = "Distance must be 1..4096"; return end

    local settings, fixedDelay
    if kind == "delay" then
        settings = DELAY_CANDIDATES
    else
        settings = buildConcurrencyCandidates(count)
        fixedDelay = recommendedDelay()
    end

    local labels = {}
    for _, setting in ipairs(settings) do
        labels[#labels + 1] = kind == "delay" and string.format("%.2f", setting) or concurrencyLabel(setting, count)
    end
    local detail = kind == "delay" and ("Delays: " .. table.concat(labels, " "))
        or (string.format("Delay: %.2f\nConcurrency: %s", fixedDelay, table.concat(labels, " ")))
    if not confirm(string.format("Benchmark %d units x %d blocks?\n%s\nRepeats: %d", count, distance, detail, repeats)) then
        message = "Benchmark cancelled"; return
    end

    local ids = {}
    for i = 1, count do ids[i] = online[i].id end
    benchmark = {
        schema=1, active=true, kind=kind, count=count, distance=distance, repeats=repeats,
        settings=settings, settingIndex=1, repeatIndex=1, results={}, unitIds=ids,
        delay=fixedDelay, startedAt=Common.nowMs(), cooldownUntil=Common.nowMs()+1000,
    }
    currentRun = nil
    stateDirty = true
    saveState()
    message = kind == "delay" and "Delay benchmark armed" or "Concurrency benchmark armed"
end

local function cancelBenchmark()
    if not benchmark or not benchmark.active then message = "No active benchmark"; return end
    if not confirm("Cancel benchmark and return active turtles?") then return end
    benchmark.active = false
    if currentRun and not currentRun.finished then
        currentRun.canceled = true
        for _, r in pairs(currentRun.units or {}) do
            if r.state == "QUEUED" then
                r.state = "CANCELED"
            elseif ACTIVE_STATES[tostring(r.state or "")] then
                r.state = "CANCELING"
                issueToUnit("job_cancel", {}, r.id, "CANCEL")
            end
        end
    end
    stateDirty = true
    saveState()
    message = "Benchmark cancel/return dispatched"
end

local function showProfile()
    term.clear(); term.setCursorPos(1,1)
    print("Fleet Performance Profile v2")
    print(string.format("Delay: %.2f [%s/%d]", recommendedDelay(), tostring(performance.delayConfidence or "LOW"), tonumber(performance.delaySamples) or 0))
    print("Concurrency: " .. concurrencyLabel(recommendedConcurrency(math.max(1, tonumber(performance.lastUnitCount) or 9999))) .. " [" .. tostring(performance.concurrencyConfidence or "LOW") .. "/" .. tostring(performance.concurrencySamples or 0) .. "]")
    print("")
    print("Delay aggregate")
    for _, item in ipairs(type(performance.delaySummary)=="table" and performance.delaySummary or {}) do
        print(string.format(" %.2f %2dx %6.1fs %s", tonumber(item.setting) or 0, tonumber(item.samples) or 0,
            (tonumber(item.medianDurationMs) or 0)/1000,
            item.medianBps and string.format("%.2f b/s", item.medianBps) or "-"))
    end
    print("Concurrency aggregate")
    for _, item in ipairs(type(performance.concurrencySummary)=="table" and performance.concurrencySummary or {}) do
        local label = concurrencyLabel(item.setting)
        local auto = tonumber(item.setting)==-1 and item.medianAutoTarget and (" A~"..string.format("%.0f",item.medianAutoTarget)) or ""
        print(string.format(" %4s %2dx %6.1fs %s%s", label, tonumber(item.samples) or 0,
            (tonumber(item.medianDurationMs) or 0)/1000,
            item.medianBps and string.format("%.2f b/s", item.medianBps) or "-", auto))
    end
    print("Press any key")
    os.pullEvent("key")
end

local function textAt(y, text, color)
    local w = term.getSize()
    term.setCursorPos(1,y); term.setBackgroundColor(colors.black); term.setTextColor(color or colors.white)
    term.write(string.rep(" ",w)); term.setCursorPos(1,y); term.write(tostring(text):sub(1,w))
end

local function draw()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
    term.setCursorPos(1,1); term.setBackgroundColor(colors.purple); term.write(string.rep(" ",w))
    term.setCursorPos(1,1); term.setTextColor(colors.white); term.write("BASE / FLEET PERFORMANCE")
    term.setBackgroundColor(colors.black)

    local online = #onlineAssaults()
    textAt(2, string.format("v%s online:%d %s", VERSION, online, config.transportMode), colors.lightGray)
    local profileTotal = math.max(online, tonumber(performance.lastUnitCount) or 0, 1)
    textAt(3, string.format("D:%.2f C:%s", recommendedDelay(), concurrencyLabel(recommendedConcurrency(profileTotal), profileTotal)), colors.cyan)

    local row = 5
    if benchmark and benchmark.active then
        local setting = benchmark.settings[benchmark.settingIndex]
        local label = benchmark.kind == "delay" and string.format("%.2f", tonumber(setting) or 0) or concurrencyLabel(setting, benchmark.count)
        textAt(row, string.format("%s BENCH %s %d/%d", string.upper(benchmark.kind), label, benchmark.repeatIndex, benchmark.repeats), colors.yellow)
        textAt(row+1, string.format("Units:%d Dist:%d", benchmark.count, benchmark.distance), colors.lightGray)
        row = row + 3
    end
    if currentRun and not currentRun.finished then
        local q,a,d,f,c,s = countRunStates()
        textAt(row, string.format("Q:%d A:%d D:%d F:%d", q,a,d,f+c), s>0 and colors.red or colors.white)
        if currentRun.concurrency == -1 then
            local rate = currentRun.control and currentRun.control.lastRate
            textAt(row+1, string.format("AUTO/%s rate:%s", tostring(currentRun.autoTarget or "?"), rate and string.format("%.2f/s",rate) or "-"), colors.lightGray)
            row = row + 2
        else
            row = row + 1
        end
    end

    local list = onlineAssaults()
    local visible = math.max(1, h-row-4)
    for i=1,math.min(#list,visible) do
        local u=list[i]
        local r=currentRun and currentRun.units[tostring(u.id)]
        local state=r and tostring(r.state or "?") or "IDLE"
        local extra=""
        if r and (state=="RUNNING" or state=="RETURN" or state=="STALLED") then
            local cur=state=="RETURN" and (r.returned or 0) or (r.outbound or 0)
            extra=" "..tostring(cur).."/"..tostring(currentRun.distance)
        end
        textAt(row+i-1,string.format("#%s %-9s%s",u.id,state,extra),state=="STALLED" and colors.red or colors.white)
    end

    textAt(h-2,message,colors.orange)
    textAt(h-1,"D delay K concurrency C cancel P profile Q",colors.lightGray)
end

local function networkLoop()
    if #Common.openModems() == 0 then error("No wireless modem found",0) end
    local retryTimer=os.startTimer(RETRY_TICK)
    local modemTimer=os.startTimer(2)
    local beaconTimer=os.startTimer(0.2)
    local directDiscover=os.startTimer(0.1)
    local meshDiscover=os.startTimer(config.transportMode=="AUTO" and 2.0 or DISCOVERY_MESH_MS/1000)
    local stateTimer=os.startTimer(STATE_FLUSH_MS/1000)
    local schedulerTimer=os.startTimer(0.20)
    local cacheTimer=os.startTimer(2)

    while appRunning do
        local e,a,b,c=os.pullEvent()
        if e=="rednet_message" then handlePacket(b,c)
        elseif e=="timer" and a==retryTimer then retryPending(); retryTimer=os.startTimer(RETRY_TICK)
        elseif e=="timer" and a==modemTimer then Common.openModems(); modemTimer=os.startTimer(2)
        elseif e=="timer" and a==beaconTimer then sendBeacon(); beaconTimer=os.startTimer(4)
        elseif e=="timer" and a==directDiscover then sendDiscovery(false); directDiscover=os.startTimer(DISCOVERY_DIRECT_MS/1000)
        elseif e=="timer" and a==meshDiscover then
            if config.transportMode~="DIRECT" then sendDiscovery(true) end
            meshDiscover=os.startTimer(DISCOVERY_MESH_MS/1000)
        elseif e=="timer" and a==stateTimer then if stateDirty then saveState() end; stateTimer=os.startTimer(STATE_FLUSH_MS/1000)
        elseif e=="timer" and a==cacheTimer then if cacheDirty then saveCache() end; cacheTimer=os.startTimer(2)
        elseif e=="timer" and a==schedulerTimer then
            governorStep(); dispatchQueued()
            local finished,result=finalizeRun()
            if finished and result then
                if benchmark and benchmark.active then advanceBenchmark(result) else currentRun=nil end
            end
            benchmarkStep()
            schedulerTimer=os.startTimer(0.20)
            os.queueEvent("perf_redraw")
        elseif e=="peripheral" or e=="peripheral_detach" then Common.openModems() end
    end
end

local function uiLoop()
    draw()
    while true do
        local e,a=os.pullEvent()
        if e=="key" then
            if a==keys.d then armBenchmark("delay")
            elseif a==keys.k then armBenchmark("concurrency")
            elseif a==keys.c then cancelBenchmark()
            elseif a==keys.p then showProfile()
            elseif a==keys.q or a==keys.escape or a==keys.leftShift then
                appRunning=false
                if cacheDirty then saveCache() end
                if stateDirty then saveState() end
                return
            end
            draw()
        elseif e=="perf_redraw" or e=="term_resize" then draw() end
    end
end

parallel.waitForAny(uiLoop, networkLoop)
