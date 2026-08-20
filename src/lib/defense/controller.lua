local Protocol = require("lib.defense.protocol")
local Transport = require("lib.net.transport")

local Controller = {}
Controller.__index = Controller

Controller.CONFIG_PATH = "/data/defense/controller.json"
Controller.STATUS_PATH = "/data/defense/status.json"
Controller.SCHEMA = 1

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local raw = file.readAll()
    file.close()
    local ok, value = pcall(textutils.unserializeJSON, raw)
    return ok and type(value) == "table" and value or nil
end

local function writeJsonAtomic(path, value)
    ensureParent(path)
    local ok, raw = pcall(textutils.serializeJSON, value)
    if not ok or type(raw) ~= "string" then return false, "serialize_failed" end

    local temp = path .. ".tmp"
    local backup = path .. ".bak"
    if fs.exists(temp) then pcall(fs.delete, temp) end

    local file = fs.open(temp, "w")
    if not file then return false, "temp_open_failed" end
    local wrote, writeError = pcall(function() file.write(raw) end)
    pcall(function() file.close() end)
    if not wrote then
        pcall(fs.delete, temp)
        return false, "write_failed:" .. tostring(writeError)
    end

    if fs.exists(backup) then pcall(fs.delete, backup) end
    if fs.exists(path) then
        local moved, moveError = pcall(fs.move, path, backup)
        if not moved then
            pcall(fs.delete, temp)
            return false, "backup_failed:" .. tostring(moveError)
        end
    end

    local committed, commitError = pcall(fs.move, temp, path)
    if not committed then
        if fs.exists(backup) and not fs.exists(path) then pcall(fs.move, backup, path) end
        return false, "commit_failed:" .. tostring(commitError)
    end
    if fs.exists(backup) then pcall(fs.delete, backup) end
    return true
end

local function randomHex(seed)
    local text = tostring(seed or "") .. ":" .. tostring(math.random()) .. ":" .. tostring(Protocol.nowMs())
    local a, b = 2166136261, 16777619
    for index = 1, #text do
        local byte = text:byte(index)
        a = (a * 131 + byte) % 2147483647
        b = (b * 257 + byte + index) % 2147483647
    end
    return string.format("%08x%08x", a, b)
end

local function unitId(value)
    local number = math.floor(tonumber(value) or -1)
    if number < 0 then return nil end
    return number
end

local function cleanString(value, fallback, maxLength)
    value = tostring(value or fallback or "")
    if value == "" then value = tostring(fallback or "") end
    return value:sub(1, maxLength or 64)
end

local function cleanCapability(value, fallback)
    value = tostring(value or fallback or "unknown")
    if value == "" then value = tostring(fallback or "unknown") end
    return value:sub(1, 48)
end

local function normalizeCapabilities(value)
    value = type(value) == "table" and value or {}
    return {
        move = cleanCapability(value.move, "unknown"),
        modem = cleanCapability(value.modem, "unknown"),
        melee = cleanCapability(value.melee, "unknown"),
        meleeReason = cleanCapability(value.meleeReason, ""),
        dig = cleanCapability(value.dig, "unknown"),
        gps = cleanCapability(value.gps, "not_configured")
    }
end

local function emptyRuntimeUnit(id, name, label, session, enrolledAt, txSeq)
    return {
        id = id,
        name = cleanString(name, "Unit " .. tostring(id), 48),
        label = cleanString(label, "", 48),
        session = tostring(session or ""):sub(1, 128),
        enrolledAt = tonumber(enrolledAt) or Protocol.nowMs(),
        txSeq = math.max(0, math.floor(tonumber(txSeq) or 0)),
        lastSeen = 0,
        bootId = "",
        agentMode = Protocol.MODE_SAFE,
        state = "UNKNOWN",
        fuel = nil,
        fuelLimit = nil,
        fuelState = "UNKNOWN",
        fuelSlots = {},
        capabilities = normalizeCapabilities(nil),
        agentVersion = "",
        color = false,
        lastResult = ""
    }
end

local function defaultConfig()
    return {
        schema = Controller.SCHEMA,
        mode = Protocol.MODE_SAFE,
        modeRevision = 1,
        units = {}
    }
end

local function normalizeConfig(value)
    if type(value) ~= "table" or value.schema ~= Controller.SCHEMA or type(value.units) ~= "table" then
        return defaultConfig()
    end

    local result = defaultConfig()
    result.modeRevision = math.max(1, math.floor(tonumber(value.modeRevision) or 1))
    for key, item in pairs(value.units) do
        local id = unitId(item and item.id or key)
        if id and type(item) == "table" and type(item.session) == "string" and item.session ~= "" then
            result.units[tostring(id)] = emptyRuntimeUnit(
                id, item.name, item.label, item.session, item.enrolledAt, item.txSeq
            )
        end
    end

    result.mode = Protocol.MODE_SAFE
    result.modeRevision = result.modeRevision + 1
    return result
end

function Controller.new(options)
    options = type(options) == "table" and options or {}
    local loaded = readJson(options.configPath or Controller.CONFIG_PATH)
    local config = normalizeConfig(loaded)

    local self = setmetatable({
        configPath = options.configPath or Controller.CONFIG_PATH,
        statusPath = options.statusPath or Controller.STATUS_PATH,
        mode = config.mode,
        modeRevision = config.modeRevision,
        units = config.units,
        pending = {},
        running = false,
        lastError = "",
        startedAt = 0
    }, Controller)

    self:saveConfig()
    self:writeStatus()
    return self
end

function Controller:saveConfig()
    local units = {}
    for key, unit in pairs(self.units) do
        units[key] = {
            id = unit.id,
            name = unit.name,
            label = unit.label,
            session = unit.session,
            enrolledAt = unit.enrolledAt,
            txSeq = unit.txSeq
        }
    end

    return writeJsonAtomic(self.configPath, {
        schema = Controller.SCHEMA,
        mode = self.mode,
        modeRevision = self.modeRevision,
        units = units
    })
end

function Controller:isOnline(unit, now)
    now = tonumber(now) or Protocol.nowMs()
    return unit and tonumber(unit.lastSeen) and now - tonumber(unit.lastSeen) <= Protocol.UNIT_OFFLINE_MS
end

function Controller:cleanupPending()
    local now = Protocol.nowMs()
    for key, pending in pairs(self.pending) do
        if now > (tonumber(pending.expiresAt) or 0) then self.pending[key] = nil end
    end
end

function Controller:statusSnapshot()
    self:cleanupPending()
    local now = Protocol.nowMs()
    local units, pending = {}, {}
    local online = 0

    for _, unit in pairs(self.units) do
        local isOnline = self:isOnline(unit, now)
        if isOnline then online = online + 1 end
        units[#units + 1] = {
            id = unit.id,
            name = unit.name,
            label = unit.label,
            enrolledAt = unit.enrolledAt,
            online = isOnline,
            lastSeen = unit.lastSeen,
            bootId = unit.bootId,
            mode = unit.agentMode,
            state = unit.state,
            fuel = unit.fuel,
            fuelLimit = unit.fuelLimit,
            fuelState = unit.fuelState,
            fuelSlots = unit.fuelSlots,
            capabilities = unit.capabilities,
            agentVersion = unit.agentVersion,
            color = unit.color == true,
            lastResult = unit.lastResult or ""
        }
    end

    for _, item in pairs(self.pending) do
        pending[#pending + 1] = {
            id = item.id,
            name = item.name,
            label = item.label,
            code = item.code,
            requestedAt = item.requestedAt,
            expiresAt = item.expiresAt
        }
    end

    table.sort(units, function(a, b) return a.id < b.id end)
    table.sort(pending, function(a, b) return a.id < b.id end)

    return {
        schema = 1,
        running = self.running,
        controllerId = os.getComputerID(),
        mode = self.mode,
        modeRevision = self.modeRevision,
        updatedAt = now,
        startedAt = self.startedAt,
        totalUnits = #units,
        onlineUnits = online,
        pendingCount = #pending,
        units = units,
        pending = pending,
        lastError = self.lastError
    }
end

function Controller:writeStatus()
    return writeJsonAtomic(self.statusPath, self:statusSnapshot())
end

function Controller:sendPacket(recipient, messageType, payload, session, seq)
    recipient = unitId(recipient)
    if not recipient then return false, "invalid_recipient" end

    if not Transport.isOpen() then Transport.openAll() end
    if not Transport.isOpen() then return false, "rednet_not_open" end

    local packet = Protocol.packet(messageType, payload, {session = session, seq = seq})
    local ok, result = pcall(rednet.send, recipient, packet, Protocol.REDNET_PROTOCOL)
    if not ok then return false, tostring(result) end
    return result == true
end

function Controller:sendControllerHeartbeat(unit)
    if not unit then return false, "unknown_unit" end
    return self:sendPacket(unit.id, "controller_heartbeat", {
        controllerId = os.getComputerID(),
        mode = self.mode,
        modeRevision = self.modeRevision
    }, unit.session)
end

local function unitIsFailSafeLatched(unit)
    return unit and unit.state == "LINK_LOST_SAFE" and unit.agentMode == Protocol.MODE_SAFE
end

function Controller:broadcastControllerState(force)
    for _, unit in pairs(self.units) do
        if force == true or self.mode == Protocol.MODE_SAFE or not unitIsFailSafeLatched(unit) then
            self:sendControllerHeartbeat(unit)
        end
    end
end

function Controller:setMode(mode)
    mode = tostring(mode or ""):upper()
    if not Protocol.validMode(mode) then return false, "invalid_mode" end

    self.mode = mode
    self.modeRevision = self.modeRevision + 1
    local saved, saveError = self:saveConfig()
    if not saved then return false, saveError end

    self:broadcastControllerState(true)
    self:writeStatus()
    os.queueEvent("ccbase_defense_state", self.mode)
    return true
end

function Controller:pendingCount()
    local count = 0
    for _ in pairs(self.pending) do count = count + 1 end
    return count
end

function Controller:handleEnrollRequest(sender, payload)
    sender = unitId(sender)
    payload = type(payload) == "table" and payload or {}
    if not sender or self.units[tostring(sender)] then return false end

    local code = tostring(payload.code or "")
    local nonce = tostring(payload.nonce or "")
    if not code:match("^%d%d%d%d%d%d$") or nonce == "" or #nonce > 128 then return false end

    local key = tostring(sender)
    local existing = self.pending[key]
    if not existing and self:pendingCount() >= Protocol.MAX_PENDING then
        self.lastError = "pending_enrollment_limit"
        return false
    end

    local now = Protocol.nowMs()
    self.pending[key] = {
        id = sender,
        code = code,
        nonce = nonce,
        name = cleanString(payload.name, "Unit " .. tostring(sender), 48),
        label = cleanString(payload.label, "", 48),
        requestedAt = existing and existing.requestedAt or now,
        expiresAt = now + Protocol.PENDING_TTL_MS
    }
    self:writeStatus()
    os.queueEvent("ccbase_defense_pending", sender, code)
    return true
end

function Controller:confirmEnrollment(id, code)
    id = unitId(id)
    if not id then return false, "invalid_unit" end
    local pending = self.pending[tostring(id)]
    if not pending then return false, "no_pending_enrollment" end
    if code ~= nil and tostring(code) ~= pending.code then return false, "pairing_code_mismatch" end

    local session = randomHex(tostring(id) .. ":" .. pending.nonce .. ":" .. tostring(math.random(0, 999999)))
    local unit = emptyRuntimeUnit(id, pending.name, pending.label, session, Protocol.nowMs(), 0)
    unit.state = "ENROLLED"
    self.units[tostring(id)] = unit
    self.pending[tostring(id)] = nil

    local saved, saveError = self:saveConfig()
    if not saved then
        self.units[tostring(id)] = nil
        return false, saveError
    end

    local sent, sendError = self:sendPacket(id, "enroll_accept", {
        nonce = pending.nonce,
        session = session,
        mode = Protocol.MODE_SAFE,
        modeRevision = self.modeRevision,
        controllerId = os.getComputerID()
    })
    if not sent then self.lastError = "enroll_accept_send_failed:" .. tostring(sendError or "") end

    self:writeStatus()
    os.queueEvent("ccbase_defense_enrolled", id)
    return true
end

function Controller:revoke(id)
    id = unitId(id)
    if not id then return false, "invalid_unit" end
    local key = tostring(id)
    local unit = self.units[key]
    if not unit then return false, "unknown_unit" end

    self:sendPacket(id, "revoke", {reason = "controller_revoked"}, unit.session)
    self.units[key] = nil
    local saved, saveError = self:saveConfig()
    if not saved then return false, saveError end

    self:writeStatus()
    os.queueEvent("ccbase_defense_revoked", id)
    return true
end

local function cleanFuelSlots(value)
    local result = {}
    if type(value) == "table" then
        for _, slot in ipairs(value) do
            slot = math.floor(tonumber(slot) or 0)
            if slot >= 1 and slot <= 16 then result[#result + 1] = slot end
            if #result >= 8 then break end
        end
    end
    return result
end

function Controller:handleHeartbeat(sender, packet)
    local unit = self.units[tostring(sender)]
    if not unit or packet.session ~= unit.session then return false end

    local payload = packet.payload
    unit.lastSeen = Protocol.nowMs()
    unit.bootId = cleanString(payload.bootId, "", 64)
    unit.agentMode = Protocol.validMode(payload.mode) and payload.mode or Protocol.MODE_SAFE
    unit.state = cleanString(payload.state, "UNKNOWN", 48)
    unit.fuel = payload.fuel
    unit.fuelLimit = payload.fuelLimit
    unit.fuelState = cleanCapability(payload.fuelState, "UNKNOWN")
    unit.fuelSlots = cleanFuelSlots(payload.fuelSlots)
    unit.capabilities = normalizeCapabilities(payload.capabilities)
    unit.agentVersion = cleanString(payload.agentVersion, "", 32)
    unit.color = payload.color == true

    if unit.agentMode ~= self.mode and not unitIsFailSafeLatched(unit) then
        self:sendControllerHeartbeat(unit)
    end

    self:writeStatus()
    return true
end

function Controller:handleCommandResult(sender, packet)
    local unit = self.units[tostring(sender)]
    if not unit or packet.session ~= unit.session then return false end

    local payload = packet.payload
    unit.lastSeen = Protocol.nowMs()
    unit.lastResult = cleanString(
        tostring(payload.command or "?") .. ":" ..
        tostring(payload.ok == true and "ok" or payload.detail or "failed"),
        "", 96
    )
    self:writeStatus()
    os.queueEvent(
        "ccbase_defense_command_result",
        sender,
        tostring(payload.requestId or ""),
        payload.ok == true,
        tostring(payload.detail or "")
    )
    return true
end

function Controller:sendCommand(id, command, requestId)
    id = unitId(id)
    command = tostring(command or "")
    if not id then return false, "invalid_unit" end
    if not Protocol.isRemoteCommand(command) then return false, "command_not_allowed" end

    local unit = self.units[tostring(id)]
    if not unit then return false, "unknown_unit" end
    if not self:isOnline(unit) then return false, "unit_offline" end
    if unitIsFailSafeLatched(unit) then return false, "unit_fail_safe_latched" end

    if Protocol.isCombatCommand(command) then
        if self.mode == Protocol.MODE_SAFE then return false, "safe_mode_combat_blocked" end
        if unit.capabilities and unit.capabilities.melee == "unavailable" then
            return false, "melee_unavailable:" .. tostring(unit.capabilities.meleeReason or "runtime")
        end
    end

    unit.txSeq = (tonumber(unit.txSeq) or 0) + 1
    local saved, saveError = self:saveConfig()
    if not saved then
        unit.txSeq = unit.txSeq - 1
        return false, saveError
    end

    requestId = tostring(requestId or (
        "cmd:" .. tostring(id) .. ":" .. tostring(unit.txSeq) .. ":" .. tostring(Protocol.nowMs())
    ))

    local sent, sendError = self:sendPacket(id, "command", {
        requestId = requestId,
        command = command,
        commandSeq = unit.txSeq
    }, unit.session, unit.txSeq)
    if not sent then return false, "send_failed:" .. tostring(sendError or "") end
    return true, requestId
end

function Controller:handleNetworkMessage(sender, message, protocol)
    if protocol ~= Protocol.REDNET_PROTOCOL then return false end
    local valid, reason = Protocol.validate(message, sender)
    if not valid then
        self.lastError = "drop:" .. tostring(reason)
        self:writeStatus()
        return false
    end

    if message.type == "enroll_request" then
        return self:handleEnrollRequest(sender, message.payload)
    elseif message.type == "heartbeat" then
        return self:handleHeartbeat(sender, message)
    elseif message.type == "command_result" then
        return self:handleCommandResult(sender, message)
    end
    return false
end

function Controller:run()
    self.running = true
    self.startedAt = Protocol.nowMs()
    self.mode = Protocol.MODE_SAFE
    self.modeRevision = self.modeRevision + 1
    self:saveConfig()

    local opened = Transport.openAll()
    self.lastError = #opened == 0 and "no_open_modem" or ""
    self:writeStatus()
    self:broadcastControllerState(true)

    local maintenanceTimer = os.startTimer(1)
    local beaconTimer = os.startTimer(Protocol.CONTROLLER_BEACON_SECONDS)

    while self.running do
        local event, a, b, c = os.pullEvent()
        if event == "rednet_message" then
            self:handleNetworkMessage(a, b, c)
        elseif event == "ccbase_defense_mode_set" then
            local ok, err = self:setMode(a)
            os.queueEvent("ccbase_defense_action_result", "mode", ok, err or self.mode)
        elseif event == "ccbase_defense_enroll_confirm" then
            local ok, err = self:confirmEnrollment(a, b)
            os.queueEvent("ccbase_defense_action_result", "enroll", ok, err or tostring(a))
        elseif event == "ccbase_defense_revoke" then
            local ok, err = self:revoke(a)
            os.queueEvent("ccbase_defense_action_result", "revoke", ok, err or tostring(a))
        elseif event == "ccbase_defense_command" then
            local ok, result = self:sendCommand(a, b, c)
            os.queueEvent("ccbase_defense_action_result", "command", ok, result or "")
        elseif event == "peripheral" or event == "peripheral_detach" then
            Transport.openAll()
        elseif event == "timer" and a == maintenanceTimer then
            self:cleanupPending()
            Transport.openAll()
            self:writeStatus()
            maintenanceTimer = os.startTimer(1)
        elseif event == "timer" and a == beaconTimer then
            self:broadcastControllerState(false)
            beaconTimer = os.startTimer(Protocol.CONTROLLER_BEACON_SECONDS)
        end
    end

    self.mode = Protocol.MODE_SAFE
    self.modeRevision = self.modeRevision + 1
    self:broadcastControllerState(true)
    self:saveConfig()
    self:writeStatus()
end

function Controller:stop()
    self.running = false
end

return Controller
