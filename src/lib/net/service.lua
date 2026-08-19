local Protocol = require("lib.net.protocol")
local Transport = require("lib.net.transport")
local Peers = require("lib.net.peers")
local Router = require("lib.net.router")
local Pairing = require("lib.net.pairing")

local Service = {}
Service.__index = Service

local DEFAULT_STATUS_PATH = "/data/network/status.json"
local MAX_SEEN_PACKETS = 128

local function ensureParent(path)
    local dir = fs.getDir(path)

    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function localLabel()
    return os.getComputerLabel() or
        ("Computer " .. tostring(os.getComputerID()))
end

local function localServices()
    return {
        "ccbase.discovery",
        "ccbase.ping",
        "ccbase.pairing"
    }
end

local function peerInfoFromPayload(payload)
    payload = type(payload) == "table" and payload or {}

    return {
        label = payload.label,
        protocolVersion = tonumber(payload.protocolVersion) or 0,
        services = payload.services
    }
end

function Service.new(options)
    options = options or {}

    local self = setmetatable({}, Service)

    self.peersPath = options.peersPath or Peers.DEFAULT_PATH
    self.statusPath = options.statusPath or DEFAULT_STATUS_PATH
    self.peers = Peers.load(self.peersPath)
    self.router = Router.new()
    self.pendingPairs = {}
    self.seenPackets = {}
    self.running = false
    self.lastError = ""

    self:configureRoutes()

    return self
end

function Service:getLocalInfo()
    return {
        label = localLabel(),
        protocolVersion = Protocol.VERSION,
        services = localServices()
    }
end

function Service:savePeers()
    local ok, err = Peers.save(self.peers, self.peersPath)

    if not ok then
        self.lastError = tostring(err)
    end

    return ok
end

function Service:observePeer(sender, info)
    local changed = Peers.observe(
        self.peers,
        sender,
        info
    )

    if changed then
        self:savePeers()
        os.queueEvent("ccbase_net_peers_changed", sender)
    end
end

function Service:getPairingStates()
    local states = {}

    for _, pending in pairs(self.pendingPairs) do
        local public = Pairing.publicState(pending)

        if public then
            table.insert(states, public)
        end
    end

    table.sort(states, function(a, b)
        return a.peerId < b.peerId
    end)

    return states
end

function Service:writeStatus()
    ensureParent(self.statusPath)

    local openModems = {}
    local trustedCount = 0

    for _, name in ipairs(Transport.getModems()) do
        local ok, isOpen = pcall(rednet.isOpen, name)

        if ok and isOpen then
            table.insert(openModems, name)
        end
    end

    for _, peer in ipairs(self.peers.peers or {}) do
        if peer.trusted then
            trustedCount = trustedCount + 1
        end
    end

    local status = {
        version = 2,
        running = self.running,
        updatedAt = Protocol.nowMs(),
        computerId = os.getComputerID(),
        label = localLabel(),
        rednetOpen = Transport.isOpen(),
        modems = openModems,
        peerCount = #(self.peers.peers or {}),
        trustedCount = trustedCount,
        pairings = self:getPairingStates(),
        lastError = self.lastError
    }

    local file = fs.open(self.statusPath, "w")

    if not file then
        return false
    end

    file.write(textutils.serializeJSON(status))
    file.close()

    return true
end

function Service:sendCore(recipient, messageType, payload)
    local packet = Protocol.new(
        "core",
        messageType,
        payload
    )

    local ok, err = Transport.send(recipient, packet)

    if not ok and err then
        self.lastError = tostring(err)
    end

    return ok, packet.packetId
end

function Service:broadcastDiscovery()
    local packet = Protocol.new(
        "core",
        "discover",
        self:getLocalInfo()
    )

    local ok, err = Transport.broadcast(packet)

    if not ok and err then
        self.lastError = tostring(err)
    else
        self.lastError = ""
    end

    self:writeStatus()
    return ok
end

function Service:rememberPacket(sender, packetId)
    local bucket = self.seenPackets[sender]

    if not bucket then
        bucket = {
            map = {},
            order = {}
        }
        self.seenPackets[sender] = bucket
    end

    if bucket.map[packetId] then
        return false
    end

    bucket.map[packetId] = true
    table.insert(bucket.order, packetId)

    while #bucket.order > MAX_SEEN_PACKETS do
        local old = table.remove(bucket.order, 1)
        bucket.map[old] = nil
    end

    return true
end

function Service:emitPairState(peerId, state, code)
    os.queueEvent(
        "ccbase_net_pair_state",
        peerId,
        state,
        code or ""
    )
    self:writeStatus()
end

function Service:startPair(peerId)
    peerId = math.floor(tonumber(peerId) or -1)
    local peer = Peers.find(self.peers, peerId)

    if not peer then
        return false, "unknown_peer"
    end

    if peer.trusted then
        return false, "already_trusted"
    end

    local pending, err = Pairing.createOutgoing(peerId)

    if not pending then
        return false, err
    end

    self.pendingPairs[peerId] = pending

    local ok = self:sendCore(
        peerId,
        "pair_request",
        {
            requestId = pending.requestId,
            nonceA = pending.nonceA,
            label = localLabel(),
            protocolVersion = Protocol.VERSION,
            services = localServices()
        }
    )

    if not ok then
        self.pendingPairs[peerId] = nil
        return false, "pair_request_failed"
    end

    self:emitPairState(peerId, "waiting_challenge")
    return true
end

function Service:finalizePair(peerId, pending)
    if not pending or not pending.sessionId then
        return false
    end

    local changed = Peers.setTrusted(
        self.peers,
        peerId,
        true,
        pending.sessionId
    )

    if not changed then
        return false
    end

    self:savePeers()
    self.pendingPairs[peerId] = nil
    os.queueEvent("ccbase_net_peers_changed", peerId)
    self:emitPairState(peerId, "trusted")
    return true
end

function Service:confirmPair(peerId)
    peerId = math.floor(tonumber(peerId) or -1)
    local pending = self.pendingPairs[peerId]

    if not pending or Pairing.isExpired(pending) then
        self.pendingPairs[peerId] = nil
        return false, "no_pending_pair"
    end

    if not pending.code or not pending.sessionId then
        return false, "pair_code_not_ready"
    end

    if pending.localConfirmed then
        return false, "already_confirmed"
    end

    pending.localConfirmed = true

    local ok = self:sendCore(
        peerId,
        "pair_confirm",
        {
            requestId = pending.requestId,
            code = pending.code
        }
    )

    if not ok then
        pending.localConfirmed = false
        return false, "pair_confirm_failed"
    end

    self:emitPairState(
        peerId,
        pending.remoteConfirmed and "completing" or "waiting_remote",
        pending.code
    )

    if pending.remoteConfirmed then
        self:sendCore(
            peerId,
            "pair_complete",
            {
                requestId = pending.requestId,
                code = pending.code,
                sessionId = pending.sessionId
            }
        )
        self:finalizePair(peerId, pending)
    end

    return true
end

function Service:untrust(peerId)
    peerId = math.floor(tonumber(peerId) or -1)
    local changed = Peers.setTrusted(
        self.peers,
        peerId,
        false
    )

    if not changed then
        return false, "peer_not_trusted"
    end

    self:savePeers()
    self.pendingPairs[peerId] = nil
    os.queueEvent("ccbase_net_peers_changed", peerId)
    self:emitPairState(peerId, "untrusted")
    return true
end

function Service:cleanupPairings()
    local expired = {}

    for peerId, pending in pairs(self.pendingPairs) do
        if Pairing.isExpired(pending) then
            table.insert(expired, peerId)
        end
    end

    for _, peerId in ipairs(expired) do
        self.pendingPairs[peerId] = nil
        self:emitPairState(peerId, "expired")
    end
end

function Service:configureRoutes()
    self.router:register(
        "core",
        "discover",
        function(sender, packet)
            self:observePeer(
                sender,
                peerInfoFromPayload(packet.payload)
            )

            self:sendCore(
                sender,
                "hello",
                self:getLocalInfo()
            )
        end
    )

    self.router:register(
        "core",
        "hello",
        function(sender, packet)
            self:observePeer(
                sender,
                peerInfoFromPayload(packet.payload)
            )
        end
    )

    self.router:register(
        "core",
        "ping",
        function(sender, packet)
            self:observePeer(
                sender,
                peerInfoFromPayload(packet.payload)
            )

            self:sendCore(
                sender,
                "pong",
                {
                    label = localLabel(),
                    protocolVersion = Protocol.VERSION,
                    services = localServices(),
                    pingId = packet.packetId,
                    sentAt = packet.payload.sentAt
                }
            )
        end
    )

    self.router:register(
        "core",
        "pong",
        function(sender, packet)
            local sentAt = tonumber(packet.payload.sentAt)
            local latency = 0

            if sentAt then
                latency = math.max(
                    0,
                    Protocol.nowMs() - sentAt
                )
            end

            local info = peerInfoFromPayload(packet.payload)
            info.latencyMs = latency

            self:observePeer(sender, info)
            os.queueEvent(
                "ccbase_net_pong",
                sender,
                latency,
                packet.payload.pingId
            )
        end
    )

    self.router:register(
        "core",
        "pair_request",
        function(sender, packet)
            self:observePeer(
                sender,
                peerInfoFromPayload(packet.payload)
            )

            local existing = self.pendingPairs[sender]

            if existing and not Pairing.isExpired(existing) and
                existing.role == "initiator" and
                os.getComputerID() < sender
            then
                return
            end

            local pending = Pairing.createIncoming(
                sender,
                packet.payload
            )

            if not pending then
                return
            end

            self.pendingPairs[sender] = pending

            self:sendCore(
                sender,
                "pair_challenge",
                {
                    requestId = pending.requestId,
                    nonceB = pending.nonceB
                }
            )

            self:emitPairState(
                sender,
                "confirm_required",
                pending.code
            )
        end
    )

    self.router:register(
        "core",
        "pair_challenge",
        function(sender, packet)
            local pending = self.pendingPairs[sender]

            if not pending or Pairing.isExpired(pending) then
                return
            end

            local ok = Pairing.applyChallenge(
                pending,
                sender,
                packet.payload
            )

            if ok then
                self:emitPairState(
                    sender,
                    "confirm_required",
                    pending.code
                )
            end
        end
    )

    self.router:register(
        "core",
        "pair_confirm",
        function(sender, packet)
            local pending = self.pendingPairs[sender]

            if not pending or Pairing.isExpired(pending) then
                return
            end

            if packet.payload.requestId ~= pending.requestId or
                packet.payload.code ~= pending.code
            then
                return
            end

            pending.remoteConfirmed = true

            if pending.localConfirmed then
                self:sendCore(
                    sender,
                    "pair_complete",
                    {
                        requestId = pending.requestId,
                        code = pending.code,
                        sessionId = pending.sessionId
                    }
                )
                self:finalizePair(sender, pending)
            else
                self:emitPairState(
                    sender,
                    "remote_confirmed",
                    pending.code
                )
            end
        end
    )

    self.router:register(
        "core",
        "pair_complete",
        function(sender, packet)
            local pending = self.pendingPairs[sender]

            if not pending or Pairing.isExpired(pending) or
                not pending.localConfirmed
            then
                return
            end

            if packet.payload.requestId ~= pending.requestId or
                packet.payload.code ~= pending.code or
                packet.payload.sessionId ~= pending.sessionId
            then
                return
            end

            pending.remoteConfirmed = true
            self:finalizePair(sender, pending)
        end
    )

    self.router:setFallback(function(sender, packet)
        if packet.service:sub(1, 7) ~= "ccbase." then
            return false
        end

        local peer = Peers.find(self.peers, sender)

        if not peer or not peer.trusted then
            self.lastError = "drop:untrusted_service_packet"
            return false
        end

        local accepted, reason = Peers.acceptInboundSeq(
            self.peers,
            sender,
            packet.session,
            packet.seq
        )

        if not accepted then
            self.lastError = "drop:" .. tostring(reason)
            return false
        end

        self:savePeers()

        os.queueEvent(
            "ccbase_net_packet",
            sender,
            packet.service,
            packet.type,
            packet.payload,
            packet.packetId,
            true
        )

        return true
    end)
end

function Service:handleNetworkMessage(sender, message, protocol)
    if protocol ~= Protocol.REDNET_PROTOCOL then
        return false
    end

    local valid, reason = Protocol.validate(message, sender)

    if not valid then
        self.lastError = "drop:" .. tostring(reason)
        self:writeStatus()
        return false
    end

    if not self:rememberPacket(sender, message.packetId) then
        self.lastError = "drop:duplicate_packet"
        self:writeStatus()
        return false
    end

    local handled, err = self.router:dispatch(
        sender,
        message
    )

    if not handled and err then
        self.lastError = "drop:" .. tostring(err)
    elseif handled then
        self.lastError = ""
    end

    self:writeStatus()
    return handled
end

function Service:handleLocalSend(recipient, serviceName, messageType, payload, requestId)
    if type(serviceName) ~= "string" or
        serviceName:sub(1, 7) ~= "ccbase." or
        serviceName == "ccbase.core"
    then
        os.queueEvent(
            "ccbase_net_send_result",
            requestId,
            false,
            "service_not_allowed"
        )
        return
    end

    recipient = tonumber(recipient)

    if not recipient then
        os.queueEvent(
            "ccbase_net_send_result",
            requestId,
            false,
            "secure_broadcast_not_allowed"
        )
        return
    end

    recipient = math.floor(recipient)
    local peer = Peers.find(self.peers, recipient)

    if not peer or not peer.trusted then
        os.queueEvent(
            "ccbase_net_send_result",
            requestId,
            false,
            "untrusted_peer"
        )
        return
    end

    local seq, sessionId = Peers.nextOutboundSeq(
        self.peers,
        recipient
    )

    if not seq then
        os.queueEvent(
            "ccbase_net_send_result",
            requestId,
            false,
            "no_trusted_session"
        )
        return
    end

    self:savePeers()

    local packet = Protocol.new(
        serviceName,
        messageType,
        payload,
        {
            session = sessionId,
            seq = seq
        }
    )

    local ok, err = Transport.send(recipient, packet)

    os.queueEvent(
        "ccbase_net_send_result",
        requestId,
        ok == true,
        err or packet.packetId
    )
end

function Service:ping(peerId)
    local sentAt = Protocol.nowMs()

    return self:sendCore(
        tonumber(peerId),
        "ping",
        {
            label = localLabel(),
            protocolVersion = Protocol.VERSION,
            services = localServices(),
            sentAt = sentAt
        }
    )
end

function Service:run()
    self.running = true

    local opened, errors = Transport.openAll()

    if #opened == 0 then
        self.lastError = "no_open_modem"
    elseif next(errors) ~= nil then
        self.lastError = "some_modems_failed"
    else
        self.lastError = ""
    end

    self:writeStatus()

    if #opened > 0 then
        self:broadcastDiscovery()
    end

    local maintenanceTimer = os.startTimer(2)

    while self.running do
        local event, a, b, c, d, e = os.pullEvent()

        if event == "rednet_message" then
            self:handleNetworkMessage(a, b, c)

        elseif event == "ccbase_net_scan" then
            local ok = self:broadcastDiscovery()
            os.queueEvent("ccbase_net_scan_started", ok)

        elseif event == "ccbase_net_ping" then
            local ok, packetId = self:ping(a)
            os.queueEvent(
                "ccbase_net_ping_started",
                a,
                ok,
                packetId
            )

        elseif event == "ccbase_net_pair_start" then
            local ok, err = self:startPair(a)
            os.queueEvent(
                "ccbase_net_pair_action",
                a,
                "start",
                ok,
                err or ""
            )

        elseif event == "ccbase_net_pair_confirm" then
            local ok, err = self:confirmPair(a)
            os.queueEvent(
                "ccbase_net_pair_action",
                a,
                "confirm",
                ok,
                err or ""
            )

        elseif event == "ccbase_net_untrust" then
            local ok, err = self:untrust(a)
            os.queueEvent(
                "ccbase_net_pair_action",
                a,
                "untrust",
                ok,
                err or ""
            )

        elseif event == "ccbase_net_send" then
            self:handleLocalSend(a, b, c, d, e)

        elseif event == "peripheral" or event == "peripheral_detach" then
            Transport.openAll()
            self:writeStatus()

        elseif event == "timer" and a == maintenanceTimer then
            Transport.openAll()
            self.peers = Peers.load(self.peersPath)
            self:cleanupPairings()
            self:writeStatus()
            maintenanceTimer = os.startTimer(2)
        end
    end

    self:writeStatus()
end

function Service:stop()
    self.running = false
end

return Service
