local Security = {}
Security.__index = Security

Security.VERSION = "0.23.0-alpha.6.1.1"
Security.STATE_SCHEMA = 1
Security.DEFAULT_STATE_PATH = "/data/fleet_security_state.json"
Security.DEFAULT_LOG_PATH = "/data/fleet_security_log.json"
Security.MAX_LOG_ENTRIES = 32
Security.REQUEST_CACHE_LIMIT = 128
Security.COMMAND_WINDOW_MS = 2000
Security.COMMAND_WINDOW_MAX = 20
Security.UPDATE_MAX_AGE_MS = 5000
Security.UPDATE_FUTURE_SKEW_MS = 2000
Security.UPDATE_COOLDOWN_MS = 30000
Security.BLOCKED_COMMAND = "__fleet_guard_blocked__"

local function nowMs()
    if os and type(os.epoch) == "function" then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then return math.floor(value) end
    end
    if os and type(os.clock) == "function" then return math.floor(os.clock() * 1000) end
    return 0
end

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
    local tmp, bak = path .. ".tmp", path .. ".bak"
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

local function normalizedState(value)
    value = type(value) == "table" and value or {}
    local last = type(value.lastUpdate) == "table" and value.lastUpdate or nil
    if last then
        last = {
            requestId = tostring(last.requestId or ""),
            operator = tostring(last.operator or ""),
            operatorBoot = tostring(last.operatorBoot or ""),
            commandSeq = math.max(0, math.floor(tonumber(last.commandSeq) or 0)),
            issuedAt = math.floor(tonumber(last.issuedAt) or 0),
            acceptedAt = math.floor(tonumber(last.acceptedAt) or 0),
            bootMarker = tostring(last.bootMarker or ""),
        }
        if last.requestId == "" then last = nil end
    end
    return {schema = Security.STATE_SCHEMA, lastUpdate = last}
end

local function packetTargeted(packet, computerId, role)
    local target = packet and packet.target
    if target == nil or target == "*" then return true end
    if tonumber(target) == computerId then return true end
    return tostring(target) == tostring(role or "")
end

local function commandKey(payload)
    return tostring(payload.operator or "?") .. ":" .. tostring(payload.operatorBoot or "?")
end

local function commandMeta(payload)
    return {
        requestId = tostring(payload.requestId or ""),
        operator = tostring(payload.operator or ""),
        operatorBoot = tostring(payload.operatorBoot or ""),
        commandSeq = math.max(0, math.floor(tonumber(payload.commandSeq) or 0)),
        issuedAt = math.floor(tonumber(payload.issuedAt) or 0),
        command = tostring(payload.command or ""),
    }
end

local function countTable(value, limit)
    local count = 0
    for _ in pairs(value) do
        count = count + 1
        if count > limit then return count end
    end
    return count
end

function Security.precheck(packet)
    if type(packet) ~= "table" then return false, "packet_not_table" end
    if packet.type ~= "command" then return true end
    local payload = packet.payload
    if type(payload) ~= "table" then return false, "command_payload" end
    if type(payload.command) ~= "string" or payload.command == "" or #payload.command > 64 then
        return false, "command_name"
    end
    if type(payload.requestId) ~= "string" or payload.requestId == "" or #payload.requestId > 128 then
        return false, "command_request_id"
    end
    if type(payload.operatorBoot) ~= "string" or payload.operatorBoot == "" or #payload.operatorBoot > 96 then
        return false, "command_operator_boot"
    end
    if tonumber(payload.operator) == nil then return false, "command_operator" end
    local seq = tonumber(payload.commandSeq)
    if not seq or seq < 1 or seq ~= math.floor(seq) then return false, "command_seq" end
    if tonumber(payload.issuedAt) == nil then return false, "command_time" end
    if payload.args ~= nil and type(payload.args) ~= "table" then return false, "command_args" end
    if type(payload.args) == "table" and countTable(payload.args, 32) > 32 then return false, "command_args_large" end
    return true
end

function Security.new(options)
    options = type(options) == "table" and options or {}
    local self = setmetatable({}, Security)
    self.computerId = math.floor(tonumber(options.computerId) or (os.getComputerID and os.getComputerID()) or 0)
    self.role = tostring(options.role or "ASSAULT")
    self.statePath = tostring(options.statePath or Security.DEFAULT_STATE_PATH)
    self.logPath = tostring(options.logPath or Security.DEFAULT_LOG_PATH)
    self.now = type(options.nowMs) == "function" and options.nowMs or nowMs
    self.bootMarker = tostring(options.bootMarker or (self.computerId .. ":" .. self.now() .. ":" .. tostring({})))
    self.state = normalizedState(readJson(self.statePath))
    self.buckets = {}
    self.seen = {}
    self.seenOrder = {}
    self.blocked = {}
    self.pendingUpdates = {}
    self.stats = {
        accepted = 0,
        blocked = 0,
        rateBlocked = 0,
        updateBlocked = 0,
        acceptedUpdates = 0,
    }
    return self
end

function Security:rememberSeen(requestId, value)
    requestId = tostring(requestId or "")
    if requestId == "" then return end
    if self.seen[requestId] == nil then self.seenOrder[#self.seenOrder + 1] = requestId end
    self.seen[requestId] = value or true
    while #self.seenOrder > Security.REQUEST_CACHE_LIMIT do
        local old = table.remove(self.seenOrder, 1)
        self.seen[old] = nil
        self.blocked[old] = nil
        self.pendingUpdates[old] = nil
    end
end

function Security:appendLog(reason, meta)
    local log = readJson(self.logPath)
    if type(log) ~= "table" then log = {} end
    log[#log + 1] = {
        time = self.now(),
        reason = tostring(reason or "blocked"),
        command = tostring(meta and meta.command or ""),
        requestId = tostring(meta and meta.requestId or ""),
        operator = tostring(meta and meta.operator or ""),
        operatorBoot = tostring(meta and meta.operatorBoot or ""),
        commandSeq = tonumber(meta and meta.commandSeq) or 0,
    }
    while #log > Security.MAX_LOG_ENTRIES do table.remove(log, 1) end
    writeJson(self.logPath, log)
end

function Security:block(payload, reason)
    local meta = commandMeta(payload)
    reason = tostring(reason or "blocked")
    self.stats.blocked = self.stats.blocked + 1
    if reason == "command_rate_limit" then self.stats.rateBlocked = self.stats.rateBlocked + 1 end
    if reason:find("update_", 1, true) == 1 then self.stats.updateBlocked = self.stats.updateBlocked + 1 end
    self.blocked[meta.requestId] = {reason = reason, command = meta.command}
    self:rememberSeen(meta.requestId, {blocked = reason})
    self:appendLog(reason, meta)
    payload.command = Security.BLOCKED_COMMAND
    return false, reason
end

function Security:rateAllowed(payload, isNew)
    if not isNew then return true end
    local now = self.now()
    local key = commandKey(payload)
    local bucket = self.buckets[key]
    if not bucket or now - bucket.startedAt >= Security.COMMAND_WINDOW_MS then
        bucket = {startedAt = now, count = 0}
        self.buckets[key] = bucket
    end
    bucket.count = bucket.count + 1
    return bucket.count <= Security.COMMAND_WINDOW_MAX
end

function Security:inspect(packet)
    if type(packet) ~= "table" or packet.type ~= "command" then return true end
    if not packetTargeted(packet, self.computerId, self.role) then return true end

    local payload = type(packet.payload) == "table" and packet.payload or {}
    local meta = commandMeta(payload)
    local isNew = meta.requestId ~= "" and self.seen[meta.requestId] == nil

    if meta.requestId == "" then return self:block(payload, "command_request_id") end
    if not self:rateAllowed(payload, isNew) then return self:block(payload, "command_rate_limit") end

    local previous = self.seen[meta.requestId]
    if type(previous) == "table" and previous.blocked then
        payload.command = Security.BLOCKED_COMMAND
        self.blocked[meta.requestId] = self.blocked[meta.requestId] or {
            reason = tostring(previous.blocked), command = meta.command,
        }
        return false, tostring(previous.blocked)
    end

    if meta.command == "update" then
        local now = self.now()
        if meta.issuedAt <= 0 or now - meta.issuedAt > Security.UPDATE_MAX_AGE_MS then
            return self:block(payload, "update_stale")
        end
        if meta.issuedAt - now > Security.UPDATE_FUTURE_SKEW_MS then
            return self:block(payload, "update_future")
        end

        local last = self.state.lastUpdate
        if last and last.requestId == meta.requestId then
            if last.bootMarker ~= self.bootMarker then
                return self:block(payload, "update_replay")
            end
        elseif last and last.acceptedAt > 0 and now - last.acceptedAt < Security.UPDATE_COOLDOWN_MS then
            return self:block(payload, "update_cooldown")
        else
            self.pendingUpdates[meta.requestId] = meta
        end
    end

    if isNew then self:rememberSeen(meta.requestId, true) end
    self.stats.accepted = self.stats.accepted + 1
    return true
end

function Security:rewriteResult(payload)
    if type(payload) ~= "table" then return payload end
    local requestId = tostring(payload.requestId or "")
    local blocked = self.blocked[requestId]
    if blocked then
        payload.ok = false
        payload.detail = "fleet_guard:" .. tostring(blocked.reason)
        payload.command = tostring(blocked.command or payload.command or "")
        payload.security = {
            version = Security.VERSION,
            blocked = true,
            reason = blocked.reason,
        }
        return payload
    end

    local pending = self.pendingUpdates[requestId]
    if pending and tostring(payload.command or "") == "update" then
        if payload.ok == true then
            local acceptedAt = self.now()
            self.state.lastUpdate = {
                requestId = requestId,
                operator = pending.operator,
                operatorBoot = pending.operatorBoot,
                commandSeq = pending.commandSeq,
                issuedAt = pending.issuedAt,
                acceptedAt = acceptedAt,
                bootMarker = self.bootMarker,
            }
            writeJson(self.statePath, self.state)
            self.stats.acceptedUpdates = self.stats.acceptedUpdates + 1
            payload.security = {
                version = Security.VERSION,
                remoteUpdate = true,
                replayProtected = true,
                cooldownMs = Security.UPDATE_COOLDOWN_MS,
            }
        end
        self.pendingUpdates[requestId] = nil
    end
    return payload
end

function Security:status()
    local last = self.state.lastUpdate
    return {
        version = Security.VERSION,
        commandWindowMs = Security.COMMAND_WINDOW_MS,
        commandWindowMax = Security.COMMAND_WINDOW_MAX,
        updateMaxAgeMs = Security.UPDATE_MAX_AGE_MS,
        updateCooldownMs = Security.UPDATE_COOLDOWN_MS,
        replayState = self.statePath,
        logPath = self.logPath,
        accepted = self.stats.accepted,
        blocked = self.stats.blocked,
        rateBlocked = self.stats.rateBlocked,
        updateBlocked = self.stats.updateBlocked,
        acceptedUpdates = self.stats.acceptedUpdates,
        lastUpdateAt = last and last.acceptedAt or nil,
    }
end

function Security.selfTest()
    local ok = Security.precheck({
        type = "command",
        payload = {
            command = "update",
            requestId = "1:b:1",
            operator = 1,
            operatorBoot = "b",
            commandSeq = 1,
            issuedAt = 1,
            args = {},
        },
    })
    return ok == true
end

return Security