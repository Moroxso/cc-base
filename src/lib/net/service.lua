local Protocol = require("lib.net.protocol")
local Transport = require("lib.net.transport")
local Peers = require("lib.net.peers")
local Router = require("lib.net.router")

local Service = {}
Service.__index = Service

local DEFAULT_STATUS_PATH = "/data/network/status.json"

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
        "ccbase.ping"
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

function Service:writeStatus()
    ensureParent(self.statusPath)

    local openModems = {}

    for _, name in ipairs(Transport.getModems()) do
        local ok, isOpen = pcall(rednet.isOpen, name)

        if ok and isOpen then
            table.insert(openModems, name)
        end
    end

    local status = {
        version = 1,
        running = self.running,
        updatedAt = Protocol.nowMs(),
        computerId = os.getComputerID(),
        label = localLabel(),
        rednetOpen = Transport.isOpen(),
        modems = openModems,
        peerCount = #(self.peers.peers or {}),
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

    self.router:setFallback(function(sender, packet)
        if packet.service:sub(1, 7) ~= "ccbase." then
            return false
        end

        local peer = Peers.find(self.peers, sender)
        local trusted = peer and peer.trusted == true or false

        os.queueEvent(
            "ccbase_net_packet",
            sender,
            packet.service,
            packet.type,
            packet.payload,
            packet.packetId,
            trusted
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

    local handled, err = self.router:dispatch(
        sender,
        message
    )

    if not handled and err then
        self.lastError = "drop:" .. tostring(err)
    else
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

    local packet = Protocol.new(
        serviceName,
        messageType,
        payload
    )

    local ok, err

    if recipient == nil then
        ok, err = Transport.broadcast(packet)
    else
        ok, err = Transport.send(recipient, packet)
    end

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

        elseif event == "ccbase_net_send" then
            self:handleLocalSend(a, b, c, d, e)

        elseif event == "peripheral" or event == "peripheral_detach" then
            Transport.openAll()
            self:writeStatus()

        elseif event == "timer" and a == maintenanceTimer then
            Transport.openAll()
            self.peers = Peers.load(self.peersPath)
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
