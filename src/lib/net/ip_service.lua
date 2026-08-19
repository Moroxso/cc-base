local Address = require("lib.net.address")
local CCIP = require("lib.net.ccip")
local Protocol = require("lib.net.protocol")

local IPService = {}
IPService.__index = IPService

local CONTROL_PORT = 7
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

function IPService.new()
    local self = setmetatable({}, IPService)

    self.address = Address.localAddress()
    self.pending = {}
    self.running = false
    self.lastError = ""

    return self
end

function IPService:getAddress()
    return self.address
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

function IPService:send(destination, protocolId, sourcePort, destinationPort, payload, requestId)
    local peerId, addressError = Address.toComputerId(destination)

    if peerId == nil then
        return false, addressError
    end

    local packet, packetError = CCIP.new(
        destination,
        protocolId,
        sourcePort,
        destinationPort,
        payload
    )

    if not packet then
        return false, packetError
    end

    if peerId == os.getComputerID() then
        os.queueEvent(
            "ccbase_ip_packet",
            packet.source,
            packet.destination,
            packet.protocol,
            packet.sourcePort,
            packet.destinationPort,
            packet.payload,
            packet.packetId,
            os.getComputerID()
        )

        if requestId ~= nil then
            os.queueEvent(
                "ccbase_ip_send_result",
                requestId,
                true,
                packet.packetId
            )
        end

        return true, packet.packetId
    end

    self:queueSecurePacket(
        peerId,
        packet,
        {
            kind = "send",
            requestId = requestId,
            ipPacketId = packet.packetId,
            destination = destination
        }
    )

    return true, packet.packetId
end

function IPService:sendControl(destination, payload, context)
    local peerId, addressError = Address.toComputerId(destination)

    if peerId == nil then
        return false, addressError
    end

    local packet, packetError = CCIP.new(
        destination,
        CCIP.PROTOCOL_CONTROL,
        CONTROL_PORT,
        CONTROL_PORT,
        payload
    )

    if not packet then
        return false, packetError
    end

    self:queueSecurePacket(peerId, packet, context)
    return true, packet.packetId
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
        return false
    end

    local valid, reason = CCIP.validate(payload)

    if not valid then
        self.lastError = tostring(reason)
        return false
    end

    local expectedSender = Address.toComputerId(payload.source)

    if expectedSender ~= sender then
        self.lastError = "ip_source_mismatch"
        return false
    end

    if payload.destination ~= self.address then
        self.lastError = "ip_not_for_local_host"
        return false
    end

    self.lastError = ""

    if payload.protocol == CCIP.PROTOCOL_CONTROL and
        payload.destinationPort == CONTROL_PORT
    then
        if self:handleControl(payload) then
            return true
        end
    end

    os.queueEvent(
        "ccbase_ip_packet",
        payload.source,
        payload.destination,
        payload.protocol,
        payload.sourcePort,
        payload.destinationPort,
        payload.payload,
        payload.packetId,
        sender
    )

    return true
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
    end

    return true
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
        end
    end
end

function IPService:stop()
    self.running = false
end

return IPService
