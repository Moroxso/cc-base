local Address = require("lib.net.address")
local CCIP = require("lib.net.ccip")
local Protocol = require("lib.net.protocol")
local Routes = require("lib.net.routes")
local Firewall = require("lib.net.firewall")

local IPService = {}
IPService.__index = IPService

local CONTROL_PORT = 7
local MAX_SEEN_PACKETS = 256
local pendingSequence = 0

local function newRequestId(prefix)
    pendingSequence = pendingSequence + 1

    return string.format(
        "%s:%d:%d:%d",
        prefix,
        os.getComputerID(),
        Protocol.nowMs(),
        pendingSequence
    )
end

function IPService.new(options)
    options = options or {}

    local self = setmetatable({}, IPService)

    self.address = Address.localAddress()
    self.routesPath = options.routesPath or Routes.DEFAULT_PATH
    self.routes = Routes.load(self.routesPath)
    self.firewall = Firewall.new(options.firewallPath)
    self.pending = {}
    self.seenPackets = {}
    self.seenOrder = {}
    self.forwardedPackets = 0
    self.droppedPackets = 0
    self.running = false
    self.lastError = ""

    return self
end

function IPService:getAddress()
    return self.address
end

function IPService:getRoutes()
    return self.routes
end

function IPService:rememberPacket(packetId)
    if type(packetId) ~= "string" or packetId == "" then
        return false
    end

    if self.seenPackets[packetId] then
        return false
    end

    self.seenPackets[packetId] = true
    table.insert(self.seenOrder, packetId)

    while #self.seenOrder > MAX_SEEN_PACKETS do
        local old = table.remove(self.seenOrder, 1)
        self.seenPackets[old] = nil
    end

    return true
end

function IPService:saveRoutes()
    local ok, err = Routes.save(self.routes, self.routesPath)

    if not ok then
        self.lastError = tostring(err or "route_save_failed")
        return false, self.lastError
    end

    os.queueEvent("ccbase_routes_changed")
    return true
end

function IPService:resolve(destination)
    return Routes.resolve(self.routes, destination)
end

function IPService:isValidPreviousHop(source, sender)
    local directId = Address.toComputerId(source)

    if directId == sender then
        return true
    end

    local route = self:resolve(source)

    return route ~= nil and route.peerId == sender
end

function IPService:firewallAllows(chain, packet)
    local allowed, reason = self.firewall:evaluate(chain, packet)

    if allowed then
        return true
    end

    self.droppedPackets = self.droppedPackets + 1
    self.lastError = tostring(reason or "firewall_drop")

    os.queueEvent(
        "ccbase_firewall_drop",
        chain,
        self.lastError,
        packet.source,
        packet.destination,
        packet.protocol,
        packet.destinationPort,
        packet.packetId
    )

    return false, self.lastError
end

function IPService:queueSecurePacket(peerId, ipPacket, context)
    local netRequestId = newRequestId("ipnet")

    self.pending[netRequestId] = context or {
        kind = "internal"
    }

    os.queueEvent(
        "ccbase_net_send",
        peerId,
        "ccbase.ip",
        "packet",
        ipPacket,
        netRequestId
    )

    return netRequestId
end

function IPService:deliverLocal(packet, sender)
    self.lastError = ""

    if packet.protocol == CCIP.PROTOCOL_CONTROL and
        packet.destinationPort == CONTROL_PORT
    then
        if self:handleControl(packet) then
            return true
        end
    end

    os.queueEvent(
        "ccbase_ip_packet",
        packet.source,
        packet.destination,
        packet.protocol,
        packet.sourcePort,
        packet.destinationPort,
        packet.payload,
        packet.packetId,
        sender or os.getComputerID()
    )

    return true
end

function IPService:routePacket(packet, context, forwarding)
    local valid, reason = CCIP.validate(packet)

    if not valid then
        return false, reason
    end

    if packet.destination == self.address then
        self:deliverLocal(packet, os.getComputerID())

        if context and context.kind == "send" and context.requestId ~= nil then
            os.queueEvent(
                "ccbase_ip_send_result",
                context.requestId,
                true,
                packet.packetId
            )
        end

        return true, packet.packetId
    end

    local outbound = packet

    if forwarding then
        if self.routes.forwarding ~= true then
            self.droppedPackets = self.droppedPackets + 1
            return false, "ip_forwarding_disabled"
        end

        outbound, reason = CCIP.forward(packet)

        if not outbound then
            self.droppedPackets = self.droppedPackets + 1
            return false, reason
        end
    end

    local route, routeError = self:resolve(outbound.destination)

    if not route then
        self.droppedPackets = self.droppedPackets + 1
        return false, routeError or "ip_no_route"
    end

    if route.peerId == os.getComputerID() then
        self.droppedPackets = self.droppedPackets + 1
        return false, "ip_route_loop"
    end

    self:queueSecurePacket(route.peerId, outbound, context)

    if forwarding then
        self.forwardedPackets = self.forwardedPackets + 1
    end

    return true, outbound.packetId
end

function IPService:send(destination, protocolId, sourcePort, destinationPort, payload, requestId)
    local packet, packetError = CCIP.new(
        destination,
        protocolId,
        sourcePort,
        destinationPort,
        payload,
        {
            source = self.address
        }
    )

    if not packet then
        return false, packetError
    end

    local allowed, firewallError = self:firewallAllows(
        Firewall.CHAIN_OUTPUT,
        packet
    )

    if not allowed then
        return false, firewallError
    end

    self:rememberPacket(packet.packetId)

    return self:routePacket(
        packet,
        {
            kind = "send",
            requestId = requestId,
            ipPacketId = packet.packetId,
            destination = destination
        },
        false
    )
end

function IPService:sendControl(destination, payload, context)
    local packet, packetError = CCIP.new(
        destination,
        CCIP.PROTOCOL_CONTROL,
        CONTROL_PORT,
        CONTROL_PORT,
        payload,
        {
            source = self.address
        }
    )

    if not packet then
        return false, packetError
    end

    local allowed, firewallError = self:firewallAllows(
        Firewall.CHAIN_OUTPUT,
        packet
    )

    if not allowed then
        return false, firewallError
    end

    self:rememberPacket(packet.packetId)

    return self:routePacket(
        packet,
        context or {kind = "internal"},
        false
    )
end

function IPService:ping(destination)
    local pingId = newRequestId("ipping")
    local sentAt = Protocol.nowMs()

    local ok, err = self:sendControl(
        destination,
        {
            type = "echo_request",
            pingId = pingId,
            sentAt = sentAt
        },
        {
            kind = "ping",
            destination = destination,
            pingId = pingId,
            sentAt = sentAt
        }
    )

    os.queueEvent(
        "ccbase_ip_ping_started",
        destination,
        ok == true,
        err or pingId
    )

    return ok, err or pingId
end

function IPService:handleControl(packet)
    local payload = packet.payload

    if payload.type == "echo_request" then
        self:sendControl(
            packet.source,
            {
                type = "echo_reply",
                pingId = payload.pingId,
                sentAt = payload.sentAt,
                responderAt = Protocol.nowMs()
            },
            {
                kind = "internal"
            }
        )

        return true
    end

    if payload.type == "echo_reply" then
        local sentAt = tonumber(payload.sentAt)
        local latency = 0

        if sentAt then
            latency = math.max(
                0,
                Protocol.nowMs() - sentAt
            )
        end

        os.queueEvent(
            "ccbase_ip_pong",
            packet.source,
            latency,
            payload.pingId or ""
        )

        return true
    end

    return false
end

function IPService:handleIncoming(sender, serviceName, messageType, payload, trusted)
    if serviceName ~= "ccbase.ip" or messageType ~= "packet" then
        return false
    end

    if trusted ~= true then
        self.lastError = "ip_untrusted_outer_packet"
        self.droppedPackets = self.droppedPackets + 1
        return false
    end

    local valid, reason = CCIP.validate(payload)

    if not valid then
        self.lastError = tostring(reason)
        self.droppedPackets = self.droppedPackets + 1
        return false
    end

    if not self:isValidPreviousHop(payload.source, sender) then
        self.lastError = "ip_reverse_path_mismatch"
        self.droppedPackets = self.droppedPackets + 1
        return false
    end

    if not self:rememberPacket(payload.packetId) then
        self.lastError = "ip_duplicate_packet"
        self.droppedPackets = self.droppedPackets + 1
        return false
    end

    if payload.destination == self.address then
        local allowed, firewallError = self:firewallAllows(
            Firewall.CHAIN_INPUT,
            payload
        )

        if not allowed then
            return false, firewallError
        end

        return self:deliverLocal(payload, sender)
    end

    local allowed, firewallError = self:firewallAllows(
        Firewall.CHAIN_FORWARD,
        payload
    )

    if not allowed then
        return false, firewallError
    end

    local ok, forwardError = self:routePacket(
        payload,
        {
            kind = "forward",
            source = payload.source,
            destination = payload.destination
        },
        true
    )

    if not ok then
        self.lastError = tostring(forwardError or "ip_forward_failed")
    else
        self.lastError = ""
    end

    return ok
end

function IPService:handleNetSendResult(requestId, ok, detail)
    local context = self.pending[requestId]

    if not context then
        return false
    end

    self.pending[requestId] = nil

    if context.kind == "send" and context.requestId ~= nil then
        os.queueEvent(
            "ccbase_ip_send_result",
            context.requestId,
            ok == true,
            detail or context.ipPacketId
        )

    elseif context.kind == "ping" and not ok then
        os.queueEvent(
            "ccbase_ip_ping_failed",
            context.destination,
            detail or "send_failed"
        )

    elseif context.kind == "forward" and not ok then
        self.lastError = "ip_forward_send_failed:" .. tostring(detail or "unknown")
    end

    return true
end

function IPService:setDefaultGateway(gateway, requestId)
    local updated, ok, err = Routes.setDefaultGateway(
        self.routes,
        gateway
    )

    if ok then
        self.routes = updated
        ok, err = self:saveRoutes()
    end

    os.queueEvent(
        "ccbase_route_action",
        requestId or "",
        ok == true,
        err or (gateway or "DIRECT"),
        "default_gateway"
    )

    return ok == true, err
end

function IPService:setForwarding(enabled, requestId)
    self.routes = Routes.setForwarding(self.routes, enabled == true)
    local ok, err = self:saveRoutes()

    os.queueEvent(
        "ccbase_route_action",
        requestId or "",
        ok == true,
        err or (self.routes.forwarding and "ON" or "OFF"),
        "forwarding"
    )

    return ok == true, err
end

function IPService:addRoute(network, prefix, gateway, metric, requestId)
    local updated, ok, err = Routes.add(
        self.routes,
        {
            network = network,
            prefix = prefix,
            gateway = gateway,
            metric = metric
        }
    )

    if ok then
        self.routes = updated
        ok, err = self:saveRoutes()
    end

    os.queueEvent(
        "ccbase_route_action",
        requestId or "",
        ok == true,
        err or "route_saved",
        "route_add"
    )

    return ok == true, err
end

function IPService:removeRoute(network, prefix, requestId)
    local updated, changed = Routes.remove(self.routes, network, prefix)
    local ok = changed
    local err = changed and nil or "route_not_found"

    if changed then
        self.routes = updated
        ok, err = self:saveRoutes()
    end

    os.queueEvent(
        "ccbase_route_action",
        requestId or "",
        ok == true,
        err or "route_removed",
        "route_remove"
    )

    return ok == true, err
end

function IPService:run()
    self.running = true

    while self.running do
        local event, a, b, c, d, e, f = os.pullEvent()

        if event == "ccbase_net_packet" then
            self:handleIncoming(a, b, c, d, f)

        elseif event == "ccbase_net_send_result" then
            self:handleNetSendResult(a, b, c)

        elseif event == "ccbase_ip_send" then
            local ok, detail = self:send(a, b, c, d, e, f)

            if not ok and f ~= nil then
                os.queueEvent(
                    "ccbase_ip_send_result",
                    f,
                    false,
                    detail or "ip_send_failed"
                )
            end

        elseif event == "ccbase_ip_ping" then
            self:ping(a)

        elseif event == "ccbase_route_set_default" then
            self:setDefaultGateway(a, b)

        elseif event == "ccbase_route_clear_default" then
            self:setDefaultGateway(nil, a)

        elseif event == "ccbase_route_set_forwarding" then
            self:setForwarding(a == true, b)

        elseif event == "ccbase_route_add" then
            self:addRoute(a, b, c, d, e)

        elseif event == "ccbase_route_remove" then
            self:removeRoute(a, b, c)

        elseif event == "ccbase_routes_reload" then
            self.routes = Routes.load(self.routesPath)
            os.queueEvent("ccbase_routes_changed")

        elseif event == "ccbase_firewall_reload" then
            self.firewall:reload()
            os.queueEvent("ccbase_firewall_changed")

        elseif event == "ccbase_firewall_reset_stats" then
            self.firewall:resetStats()
            os.queueEvent("ccbase_firewall_changed")
        end
    end
end

function IPService:stop()
    self.running = false
end

return IPService
