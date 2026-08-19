local Protocol = require("lib.net.protocol")

local Peers = {}

Peers.DEFAULT_PATH = "/data/network/peers.json"
Peers.TRUST_PATH = "/data/network/trust.json"

local function defaultData()
    return {
        version = 3,
        peers = {}
    }
end

local function defaultTrustData()
    return {
        version = 1,
        peers = {}
    }
end

local function ensureParent(path)
    local dir = fs.getDir(path)

    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function normalizeServices(services)
    local result = {}

    if type(services) ~= "table" then
        return result
    end

    for _, service in ipairs(services) do
        if type(service) == "string" and
            service ~= "" and
            #service <= 64
        then
            table.insert(result, service)
        end
    end

    return result
end

local function normalizePeer(peer)
    if type(peer) ~= "table" then
        return nil
    end

    local id = tonumber(peer.id)

    if not id then
        return nil
    end

    id = math.floor(id)
    local trusted = peer.trusted == true
    local sessionId = nil

    if trusted and type(peer.sessionId) == "string" and peer.sessionId ~= "" then
        sessionId = peer.sessionId:sub(1, 128)
    else
        trusted = false
    end

    return {
        id = id,
        label = tostring(peer.label or ("Computer " .. tostring(id))),
        trusted = trusted,
        pairedAt = math.max(0, math.floor(tonumber(peer.pairedAt) or 0)),
        sessionId = sessionId,
        rxSeq = math.max(0, math.floor(tonumber(peer.rxSeq) or 0)),
        txSeq = math.max(0, math.floor(tonumber(peer.txSeq) or 0)),
        lastSeen = math.max(0, math.floor(tonumber(peer.lastSeen) or 0)),
        latencyMs = math.max(0, math.floor(tonumber(peer.latencyMs) or 0)),
        protocolVersion = math.max(0, math.floor(tonumber(peer.protocolVersion) or 0)),
        services = normalizeServices(peer.services)
    }
end

local function normalize(data)
    local result = defaultData()

    if type(data) ~= "table" or type(data.peers) ~= "table" then
        return result
    end

    for _, peer in ipairs(data.peers) do
        local normalized = normalizePeer(peer)

        if normalized and normalized.id ~= os.getComputerID() then
            table.insert(result.peers, normalized)
        end
    end

    table.sort(result.peers, function(a, b)
        return a.id < b.id
    end)

    return result
end

local function normalizeTrustPeer(peer)
    if type(peer) ~= "table" then
        return nil
    end

    local id = tonumber(peer.id)

    if not id or
        type(peer.sessionId) ~= "string" or
        peer.sessionId == ""
    then
        return nil
    end

    id = math.floor(id)

    if id == os.getComputerID() then
        return nil
    end

    return {
        id = id,
        sessionId = peer.sessionId:sub(1, 128),
        pairedAt = math.max(0, math.floor(tonumber(peer.pairedAt) or 0)),
        rxSeq = math.max(0, math.floor(tonumber(peer.rxSeq) or 0)),
        txSeq = math.max(0, math.floor(tonumber(peer.txSeq) or 0))
    }
end

local function normalizeTrust(data)
    local result = defaultTrustData()

    if type(data) ~= "table" or type(data.peers) ~= "table" then
        return result
    end

    for _, peer in ipairs(data.peers) do
        local normalized = normalizeTrustPeer(peer)

        if normalized then
            table.insert(result.peers, normalized)
        end
    end

    table.sort(result.peers, function(a, b)
        return a.id < b.id
    end)

    return result
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

    local ok, data = pcall(textutils.unserializeJSON, raw)

    if not ok or type(data) ~= "table" then
        return nil
    end

    return data
end

local function readJsonRecovering(path)
    local data = readJson(path)

    if data then
        return data
    end

    data = readJson(path .. ".bak")

    if data then
        return data
    end

    return readJson(path .. ".tmp")
end

local function atomicWriteJson(path, data)
    ensureParent(path)

    local tempPath = path .. ".tmp"
    local backupPath = path .. ".bak"

    if fs.exists(tempPath) then
        fs.delete(tempPath)
    end

    local file = fs.open(tempPath, "w")

    if not file then
        return false, "cannot_open_temp_file"
    end

    local okSerialize, serialized = pcall(textutils.serializeJSON, data)

    if not okSerialize or type(serialized) ~= "string" then
        file.close()
        fs.delete(tempPath)
        return false, "cannot_serialize_registry"
    end

    file.write(serialized)
    file.close()

    if not readJson(tempPath) then
        fs.delete(tempPath)
        return false, "temp_write_verification_failed"
    end

    if fs.exists(backupPath) then
        fs.delete(backupPath)
    end

    if fs.exists(path) then
        local okBackup = pcall(fs.copy, path, backupPath)

        if not okBackup then
            fs.delete(tempPath)
            return false, "cannot_create_backup"
        end

        fs.delete(path)
    end

    local okMove = pcall(fs.move, tempPath, path)

    if not okMove then
        if fs.exists(backupPath) and not fs.exists(path) then
            pcall(fs.copy, backupPath, path)
        end

        return false, "cannot_commit_registry"
    end

    if not readJson(path) then
        if fs.exists(path) then
            fs.delete(path)
        end

        if fs.exists(backupPath) then
            pcall(fs.copy, backupPath, path)
        end

        return false, "commit_verification_failed"
    end

    if fs.exists(backupPath) then
        fs.delete(backupPath)
    end

    return true
end

local function trustPathFor(path)
    if path == nil or path == Peers.DEFAULT_PATH then
        return Peers.TRUST_PATH
    end

    return path .. ".trust"
end

local function buildTrustData(data)
    local trust = defaultTrustData()

    for _, peer in ipairs(data.peers or {}) do
        if peer.trusted and peer.sessionId then
            table.insert(trust.peers, {
                id = peer.id,
                sessionId = peer.sessionId,
                pairedAt = peer.pairedAt or 0,
                rxSeq = peer.rxSeq or 0,
                txSeq = peer.txSeq or 0
            })
        end
    end

    table.sort(trust.peers, function(a, b)
        return a.id < b.id
    end)

    return trust
end

local function findPeer(data, id)
    for index, peer in ipairs(data.peers or {}) do
        if peer.id == id then
            return peer, index
        end
    end

    return nil, nil
end

local function applyTrust(data, trust)
    for _, peer in ipairs(data.peers or {}) do
        peer.trusted = false
        peer.pairedAt = 0
        peer.sessionId = nil
        peer.rxSeq = 0
        peer.txSeq = 0
    end

    for _, trustedPeer in ipairs(trust.peers or {}) do
        local peer = findPeer(data, trustedPeer.id)

        if not peer then
            peer = {
                id = trustedPeer.id,
                label = "Computer " .. tostring(trustedPeer.id),
                trusted = false,
                pairedAt = 0,
                sessionId = nil,
                rxSeq = 0,
                txSeq = 0,
                lastSeen = 0,
                latencyMs = 0,
                protocolVersion = 0,
                services = {}
            }
            table.insert(data.peers, peer)
        end

        peer.trusted = true
        peer.pairedAt = trustedPeer.pairedAt
        peer.sessionId = trustedPeer.sessionId
        peer.rxSeq = trustedPeer.rxSeq
        peer.txSeq = trustedPeer.txSeq
    end

    table.sort(data.peers, function(a, b)
        return a.id < b.id
    end)
end

function Peers.load(path)
    path = path or Peers.DEFAULT_PATH

    local rawRegistry = readJsonRecovering(path)
    local data = normalize(rawRegistry or defaultData())
    local trustPath = trustPathFor(path)
    local rawTrust = readJsonRecovering(trustPath)

    if rawTrust then
        applyTrust(data, normalizeTrust(rawTrust))
    elseif rawRegistry then
        -- Migration path from 0.16.1: trust used to live only in peers.json.
        local legacyTrust = buildTrustData(data)

        if #legacyTrust.peers > 0 then
            atomicWriteJson(trustPath, legacyTrust)
        end
    end

    return data
end

function Peers.save(data, path)
    path = path or Peers.DEFAULT_PATH
    data = normalize(data)

    local okRegistry, registryError = atomicWriteJson(path, data)

    if not okRegistry then
        return false, registryError
    end

    local trustData = buildTrustData(data)
    local okTrust, trustError = atomicWriteJson(
        trustPathFor(path),
        trustData
    )

    if not okTrust then
        return false, "trust:" .. tostring(trustError)
    end

    return true
end

function Peers.find(data, id)
    id = tonumber(id)

    if not id or type(data) ~= "table" then
        return nil, nil
    end

    return findPeer(data, math.floor(id))
end

function Peers.observe(data, id, info)
    info = info or {}
    id = tonumber(id)

    if not id or id == os.getComputerID() then
        return false, nil
    end

    id = math.floor(id)
    local peer = Peers.find(data, id)
    local changed = false

    if not peer then
        peer = {
            id = id,
            label = "Computer " .. tostring(id),
            trusted = false,
            pairedAt = 0,
            sessionId = nil,
            rxSeq = 0,
            txSeq = 0,
            lastSeen = 0,
            latencyMs = 0,
            protocolVersion = 0,
            services = {}
        }

        table.insert(data.peers, peer)
        table.sort(data.peers, function(a, b)
            return a.id < b.id
        end)
        changed = true
    end

    local label = tostring(info.label or peer.label)
    local protocolVersion = math.max(
        0,
        math.floor(tonumber(info.protocolVersion) or peer.protocolVersion or 0)
    )
    local services = normalizeServices(info.services or peer.services)
    local latencyMs = peer.latencyMs or 0

    if info.latencyMs ~= nil then
        latencyMs = math.max(
            0,
            math.floor(tonumber(info.latencyMs) or 0)
        )
    end

    if peer.label ~= label then
        peer.label = label
        changed = true
    end

    if peer.protocolVersion ~= protocolVersion then
        peer.protocolVersion = protocolVersion
        changed = true
    end

    if peer.latencyMs ~= latencyMs then
        peer.latencyMs = latencyMs
        changed = true
    end

    local oldServices = textutils.serialize(peer.services or {})
    local newServices = textutils.serialize(services)

    if oldServices ~= newServices then
        peer.services = services
        changed = true
    end

    peer.lastSeen = Protocol.nowMs()
    changed = true

    return changed, peer
end

function Peers.setTrusted(data, id, trusted, sessionId)
    local peer = Peers.find(data, id)

    if not peer then
        return false
    end

    trusted = trusted == true

    if trusted then
        if type(sessionId) ~= "string" or sessionId == "" then
            return false
        end

        peer.trusted = true
        peer.pairedAt = Protocol.nowMs()
        peer.sessionId = sessionId:sub(1, 128)
        peer.rxSeq = 0
        peer.txSeq = 0
        return true
    end

    local changed = peer.trusted or peer.sessionId ~= nil or
        peer.rxSeq ~= 0 or peer.txSeq ~= 0

    peer.trusted = false
    peer.pairedAt = 0
    peer.sessionId = nil
    peer.rxSeq = 0
    peer.txSeq = 0

    return changed
end

function Peers.nextOutboundSeq(data, id)
    local peer = Peers.find(data, id)

    if not peer or not peer.trusted or not peer.sessionId then
        return nil
    end

    peer.txSeq = math.max(0, tonumber(peer.txSeq) or 0) + 1
    return peer.txSeq, peer.sessionId
end

function Peers.acceptInboundSeq(data, id, sessionId, seq)
    local peer = Peers.find(data, id)

    if not peer or not peer.trusted or not peer.sessionId then
        return false, "untrusted_peer"
    end

    if sessionId ~= peer.sessionId then
        return false, "session_mismatch"
    end

    seq = tonumber(seq)

    if not seq or seq ~= math.floor(seq) or seq < 1 then
        return false, "bad_sequence"
    end

    if seq <= (tonumber(peer.rxSeq) or 0) then
        return false, "replayed_sequence"
    end

    peer.rxSeq = seq
    return true
end

return Peers
