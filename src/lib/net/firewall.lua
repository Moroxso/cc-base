local Address = require("lib.net.address")
local Protocol = require("lib.net.protocol")

local Firewall = {}
Firewall.__index = Firewall

Firewall.VERSION = 1
Firewall.DEFAULT_PATH = "/data/network/firewall.json"
Firewall.LOG_PATH = "/data/network/firewall_log.json"
Firewall.STATUS_PATH = "/data/network/firewall_status.json"
Firewall.MAX_LOG_ENTRIES = 64

Firewall.CHAIN_INPUT = "INPUT"
Firewall.CHAIN_FORWARD = "FORWARD"
Firewall.CHAIN_OUTPUT = "OUTPUT"
Firewall.ACTION_ALLOW = "ALLOW"
Firewall.ACTION_DROP = "DROP"

local VALID_CHAINS = {
    INPUT = true,
    FORWARD = true,
    OUTPUT = true
}

local VALID_ACTIONS = {
    ALLOW = true,
    DROP = true
}

local function defaultData()
    return {
        version = Firewall.VERSION,
        enabled = true,
        policies = {
            INPUT = Firewall.ACTION_ALLOW,
            FORWARD = Firewall.ACTION_DROP,
            OUTPUT = Firewall.ACTION_ALLOW
        },
        rateLimit = {
            enabled = true,
            packets = 64,
            windowMs = 1000
        },
        rules = {}
    }
end

local function ensureParent(path)
    local dir = fs.getDir(path)

    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function readJson(path)
    if not fs.exists(path) then
        return nil
    end

    local file = fs.open(path, "r")

    if not file then
        return nil
    end

    local raw = file.readAll()
    file.close()

    if raw == "" then
        return nil
    end

    local ok, data = pcall(textutils.unserializeJSON, raw)

    if not ok or type(data) ~= "table" then
        return nil
    end

    return data
end

local function writeAtomic(path, data)
    ensureParent(path)

    local ok, serialized = pcall(textutils.serializeJSON, data)

    if not ok or type(serialized) ~= "string" then
        return false, "firewall_serialize_failed"
    end

    local tempPath = path .. ".tmp"
    local backupPath = path .. ".bak"

    if fs.exists(tempPath) then
        fs.delete(tempPath)
    end

    local file = fs.open(tempPath, "w")

    if not file then
        return false, "firewall_temp_open_failed"
    end

    file.write(serialized)
    file.close()

    if not readJson(tempPath) then
        fs.delete(tempPath)
        return false, "firewall_temp_validation_failed"
    end

    if fs.exists(backupPath) then
        fs.delete(backupPath)
    end

    if fs.exists(path) then
        fs.move(path, backupPath)
    end

    fs.move(tempPath, path)

    if not readJson(path) then
        if fs.exists(path) then
            fs.delete(path)
        end

        if fs.exists(backupPath) then
            fs.move(backupPath, path)
        end

        return false, "firewall_commit_validation_failed"
    end

    if fs.exists(backupPath) then
        fs.delete(backupPath)
    end

    return true
end

local function normalizePort(value)
    if value == nil or value == "" then
        return nil
    end

    value = tonumber(value)

    if not value or value ~= math.floor(value) or value < 0 or value > 65535 then
        return nil
    end

    return value
end

local function normalizeNetwork(network, prefix)
    if network == nil or network == "" then
        return nil, nil
    end

    prefix = math.floor(tonumber(prefix) or 32)

    if prefix < 0 or prefix > 32 or not Address.isIPv4(network) then
        return nil, nil
    end

    local normalized = Address.networkAddress(network, prefix)

    if not normalized then
        return nil, nil
    end

    return normalized, prefix
end

local function normalizeRule(rule, index)
    if type(rule) ~= "table" then
        return nil
    end

    local chain = tostring(rule.chain or ""):upper()
    local action = tostring(rule.action or ""):upper()

    if not VALID_CHAINS[chain] or not VALID_ACTIONS[action] then
        return nil
    end

    local protocolId = rule.protocol

    if protocolId ~= nil and protocolId ~= "" then
        protocolId = tonumber(protocolId)

        if not protocolId or protocolId ~= math.floor(protocolId) or
            protocolId < 0 or protocolId > 255
        then
            return nil
        end
    else
        protocolId = nil
    end

    local source, sourcePrefix = normalizeNetwork(
        rule.source,
        rule.sourcePrefix
    )
    local destination, destinationPrefix = normalizeNetwork(
        rule.destination,
        rule.destinationPrefix
    )

    local id = tostring(rule.id or ("rule-" .. tostring(index or 1)))

    if id == "" then
        id = "rule-" .. tostring(index or 1)
    end

    return {
        id = id:sub(1, 64),
        name = tostring(rule.name or id):sub(1, 32),
        enabled = rule.enabled ~= false,
        chain = chain,
        action = action,
        protocol = protocolId,
        source = source,
        sourcePrefix = sourcePrefix,
        destination = destination,
        destinationPrefix = destinationPrefix,
        sourcePort = normalizePort(rule.sourcePort),
        destinationPort = normalizePort(rule.destinationPort)
    }
end

function Firewall.normalize(data)
    if type(data) ~= "table" then
        return defaultData()
    end

    local result = defaultData()
    result.enabled = data.enabled ~= false

    for chain in pairs(VALID_CHAINS) do
        local policy = data.policies and tostring(data.policies[chain] or ""):upper()

        if VALID_ACTIONS[policy] then
            result.policies[chain] = policy
        end
    end

    if type(data.rateLimit) == "table" then
        result.rateLimit.enabled = data.rateLimit.enabled ~= false
        result.rateLimit.packets = math.max(
            1,
            math.floor(tonumber(data.rateLimit.packets) or 64)
        )
        result.rateLimit.windowMs = math.max(
            250,
            math.floor(tonumber(data.rateLimit.windowMs) or 1000)
        )
    end

    result.rules = {}

    for index, rule in ipairs(data.rules or {}) do
        local normalized = normalizeRule(rule, index)

        if normalized then
            table.insert(result.rules, normalized)
        end
    end

    return result
end

function Firewall.load(path)
    path = path or Firewall.DEFAULT_PATH

    local data = readJson(path) or
        readJson(path .. ".bak") or
        readJson(path .. ".tmp")

    return Firewall.normalize(data)
end

function Firewall.save(data, path)
    return writeAtomic(
        path or Firewall.DEFAULT_PATH,
        Firewall.normalize(data)
    )
end

function Firewall.loadLog(path)
    local data = readJson(path or Firewall.LOG_PATH)

    if type(data) ~= "table" then
        return {}
    end

    local result = {}

    for _, entry in ipairs(data) do
        if type(entry) == "table" then
            table.insert(result, entry)
        end
    end

    return result
end

function Firewall.clearLog(path)
    path = path or Firewall.LOG_PATH

    if fs.exists(path) then
        fs.delete(path)
    end

    return true
end

function Firewall.setEnabled(data, enabled)
    data = Firewall.normalize(data)
    data.enabled = enabled == true
    return data
end

function Firewall.setPolicy(data, chain, action)
    data = Firewall.normalize(data)
    chain = tostring(chain or ""):upper()
    action = tostring(action or ""):upper()

    if not VALID_CHAINS[chain] then
        return data, false, "invalid_chain"
    end

    if not VALID_ACTIONS[action] then
        return data, false, "invalid_action"
    end

    data.policies[chain] = action
    return data, true
end

function Firewall.addRule(data, rule)
    data = Firewall.normalize(data)
    local normalized = normalizeRule(rule, #data.rules + 1)

    if not normalized then
        return data, false, "invalid_rule"
    end

    for index, existing in ipairs(data.rules) do
        if existing.id == normalized.id then
            data.rules[index] = normalized
            return Firewall.normalize(data), true
        end
    end

    table.insert(data.rules, normalized)
    return Firewall.normalize(data), true
end

function Firewall.removeRule(data, ruleId)
    data = Firewall.normalize(data)
    ruleId = tostring(ruleId or "")

    for index, rule in ipairs(data.rules) do
        if rule.id == ruleId then
            table.remove(data.rules, index)
            return data, true
        end
    end

    return data, false
end

function Firewall.toggleRule(data, ruleId)
    data = Firewall.normalize(data)
    ruleId = tostring(ruleId or "")

    for _, rule in ipairs(data.rules) do
        if rule.id == ruleId then
            rule.enabled = not rule.enabled
            return data, true
        end
    end

    return data, false
end

local function ruleMatches(rule, chain, packet)
    if not rule.enabled or rule.chain ~= chain then
        return false
    end

    if rule.protocol ~= nil and packet.protocol ~= rule.protocol then
        return false
    end

    if rule.source and not Address.matches(
        packet.source,
        rule.source,
        rule.sourcePrefix or 32
    ) then
        return false
    end

    if rule.destination and not Address.matches(
        packet.destination,
        rule.destination,
        rule.destinationPrefix or 32
    ) then
        return false
    end

    if rule.sourcePort ~= nil and packet.sourcePort ~= rule.sourcePort then
        return false
    end

    if rule.destinationPort ~= nil and
        packet.destinationPort ~= rule.destinationPort
    then
        return false
    end

    return true
end

function Firewall.new(path)
    local self = setmetatable({}, Firewall)

    self.path = path or Firewall.DEFAULT_PATH
    self.config = Firewall.load(self.path)
    self.buckets = {}
    self.stats = {
        allowed = 0,
        dropped = 0,
        rateDropped = 0,
        lastDrop = nil
    }
    self.lastStatusWrite = 0
    self.lastLogWrite = 0
    self.suppressedLogDrops = 0

    self:writeStatus(true)
    return self
end

function Firewall:reload()
    self.config = Firewall.load(self.path)
    self.buckets = {}
    self:writeStatus(true)
    return self.config
end

function Firewall:resetStats()
    self.stats = {
        allowed = 0,
        dropped = 0,
        rateDropped = 0,
        lastDrop = nil
    }
    self.buckets = {}
    self:writeStatus(true)
end

function Firewall:writeStatus(force)
    local now = Protocol.nowMs()

    if not force and now - self.lastStatusWrite < 500 then
        return
    end

    self.lastStatusWrite = now
    ensureParent(Firewall.STATUS_PATH)

    local file = fs.open(Firewall.STATUS_PATH, "w")

    if not file then
        return
    end

    file.write(textutils.serializeJSON({
        version = Firewall.VERSION,
        updatedAt = now,
        enabled = self.config.enabled,
        policies = self.config.policies,
        ruleCount = #self.config.rules,
        allowed = self.stats.allowed,
        dropped = self.stats.dropped,
        rateDropped = self.stats.rateDropped,
        lastDrop = self.stats.lastDrop
    }))
    file.close()
end

function Firewall:appendDrop(entry)
    local now = Protocol.nowMs()

    self.stats.lastDrop = entry

    if now - self.lastLogWrite < 250 then
        self.suppressedLogDrops = self.suppressedLogDrops + 1
        self:writeStatus(false)
        return
    end

    entry.suppressedBefore = self.suppressedLogDrops
    self.suppressedLogDrops = 0
    self.lastLogWrite = now

    local log = Firewall.loadLog()
    table.insert(log, entry)

    while #log > Firewall.MAX_LOG_ENTRIES do
        table.remove(log, 1)
    end

    writeAtomic(Firewall.LOG_PATH, log)
    self:writeStatus(true)
end

function Firewall:rateAllowed(chain, packet)
    local limit = self.config.rateLimit

    if not limit.enabled or chain == Firewall.CHAIN_OUTPUT then
        return true
    end

    local now = Protocol.nowMs()
    local key = chain .. ":" .. tostring(packet.source)
    local bucket = self.buckets[key]

    if not bucket or now - bucket.startedAt >= limit.windowMs then
        bucket = {
            startedAt = now,
            count = 0
        }
        self.buckets[key] = bucket
    end

    bucket.count = bucket.count + 1
    return bucket.count <= limit.packets
end

function Firewall:evaluate(chain, packet)
    chain = tostring(chain or ""):upper()

    if not VALID_CHAINS[chain] or type(packet) ~= "table" then
        return false, "firewall_invalid_context"
    end

    if not self.config.enabled then
        self.stats.allowed = self.stats.allowed + 1
        self:writeStatus(false)
        return true, "firewall_disabled"
    end

    if not self:rateAllowed(chain, packet) then
        self.stats.dropped = self.stats.dropped + 1
        self.stats.rateDropped = self.stats.rateDropped + 1

        self:appendDrop({
            time = Protocol.nowMs(),
            chain = chain,
            reason = "rate_limit",
            action = Firewall.ACTION_DROP,
            source = packet.source,
            destination = packet.destination,
            protocol = packet.protocol,
            sourcePort = packet.sourcePort,
            destinationPort = packet.destinationPort,
            packetId = packet.packetId
        })

        return false, "firewall_rate_limit"
    end

    for _, rule in ipairs(self.config.rules) do
        if ruleMatches(rule, chain, packet) then
            if rule.action == Firewall.ACTION_ALLOW then
                self.stats.allowed = self.stats.allowed + 1
                self:writeStatus(false)
                return true, "rule:" .. rule.id
            end

            self.stats.dropped = self.stats.dropped + 1
            self:appendDrop({
                time = Protocol.nowMs(),
                chain = chain,
                reason = "rule",
                ruleId = rule.id,
                action = Firewall.ACTION_DROP,
                source = packet.source,
                destination = packet.destination,
                protocol = packet.protocol,
                sourcePort = packet.sourcePort,
                destinationPort = packet.destinationPort,
                packetId = packet.packetId
            })

            return false, "firewall_rule_drop:" .. rule.id
        end
    end

    local policy = self.config.policies[chain] or Firewall.ACTION_DROP

    if policy == Firewall.ACTION_ALLOW then
        self.stats.allowed = self.stats.allowed + 1
        self:writeStatus(false)
        return true, "policy_allow"
    end

    self.stats.dropped = self.stats.dropped + 1
    self:appendDrop({
        time = Protocol.nowMs(),
        chain = chain,
        reason = "policy",
        action = Firewall.ACTION_DROP,
        source = packet.source,
        destination = packet.destination,
        protocol = packet.protocol,
        sourcePort = packet.sourcePort,
        destinationPort = packet.destinationPort,
        packetId = packet.packetId
    })

    return false, "firewall_policy_drop:" .. chain
end

return Firewall
