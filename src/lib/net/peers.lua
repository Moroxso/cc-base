local Protocol = require("lib.net.protocol")

local Peers = {}

Peers.DEFAULT_PATH = "/data/network/peers.json"

local function defaultData()
    return {
        version = 2,
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

    local trusted = peer.trusted == true
    local sessionId = nil

    if trusted and type(peer.sessionId) == "string" and peer.sessionId ~= "" then
        sessionId = peer.sessionId:sub(1, 128)
    end

    return {
        id = math.floor(id),
        label = tostring(peer.label or ("Computer " .. tostring(math.floor(id)))),
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

function Peers.load(path)
    path = path or Peers.DEFAULT_PATH

    if not fs.exists(path) then
        return defaultData()
    end

    local file = fs.open(path, "r")

    if not file then
        return defaultData()
    end

    local raw = file.readAll()
    file.close()

    local ok, data = pcall(textutils.unserializeJSON, raw)

    if not ok then
        return defaultData()
    end

    return normalize(data)
end

function Peers.save(data, path)
    path = path or Peers.DEFAULT_PATH
    data = normalize(data)

    ensureParent(path)

    local file = fs.open(path, "w")

    if not file then
        return false, "cannot_open_peer_registry"
    end

    file.write(textutils.serializeJSON(data))
    file.close()

    return true
end

function Peers.find(data, id)
    id = tonumber(id)

    if not id or type(data) ~= "table" then
        return nil, nil
    end

    for index, peer in ipairs(data.peers or {}) do
        if peer.id == id then
            return peer, index
        end
    end

    return nil, nil
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
