local CCIP = require("lib.net.ccip")
local CCDP = require("lib.net.ccdp")
local Protocol = require("lib.net.protocol")

local DatagramService = {}
DatagramService.__index = DatagramService

local PING_TIMEOUT_MS = 2000
local internalSequence = 0

local function newInternalId(prefix)
    internalSequence = internalSequence + 1

    return string.format(
        "%s:%d:%d:%d",
        prefix,
        os.getComputerID(),
        Protocol.nowMs(),
        internalSequence
    )
end

function DatagramService.new()
    local self = setmetatable({}, DatagramService)

    self.pending = {}
    self.pendingPings = {}
    self.running = false
    self.lastError = ""

    return self
end

function DatagramService:queueIPSend(
    destination,
    sourcePort,
    destinationPort,
    datagram,
    requestId,
    context
)
    local ipRequestId = newInternalId("ccdp-ip")

    self.pending[ipRequestId] = {
        requestId = requestId,
        datagramId = datagram.datagramId,
        context = context
    }

    os.queueEvent(
        "ccbase_ip_send",
        destination,
        CCIP.PROTOCOL_CCDP,
        sourcePort,
        destinationPort,
        datagram,
        ipRequestId
    )

    return ipRequestId
end

function DatagramService:send(
    destination,
    sourcePort,
    destinationPort,
    datagram,
    requestId,
    context
)
    local valid, reason = CCDP.validate(datagram)

    if not valid then
        return false, reason
    end

    sourcePort = tonumber(sourcePort)
    destinationPort = tonumber(destinationPort)

    if not sourcePort or
        sourcePort ~= math.floor(sourcePort) or
        sourcePort < 1 or
        sourcePort > 65535
    then
        return false, "ccdp_bad_source_port"
    end

    if not destinationPort or
        destinationPort ~= math.floor(destinationPort) or
        destinationPort < 1 or
        destinationPort > 65535
    then
        return false, "ccdp_bad_destination_port"
    end

    self:queueIPSend(
        destination,
        sourcePort,
        destinationPort,
        datagram,
        requestId,
        context
    )

    return true
end

function DatagramService:sendPayload(
    destination,
    sourcePort,
    destinationPort,
    payload,
    context
)
    local datagram, err = CCDP.new(payload)

    if not datagram then
        return false, err
    end

    local requestId = newInternalId("ccdp-internal")

    return self:send(
        destination,
        sourcePort,
        destinationPort,
        datagram,
        requestId,
        context
    )
end

function DatagramService:ping(destination)
    local pingId = newInternalId("ccdp-ping")
    local sourcePort = CCDP.nextEphemeralPort()
    local sentAt = Protocol.nowMs()

    local ok, err = self:sendPayload(
        destination,
        sourcePort,
        CCDP.DIAGNOSTIC_PORT,
        {
            kind = "echo_request",
            pingId = pingId,
            sentAt = sentAt
        },
        {
            kind = "ping",
            pingId = pingId,
            destination = destination
        }
    )

    if ok then
        self.pendingPings[pingId] = {
            destination = destination,
            sourcePort = sourcePort,
            sentAt = sentAt,
            expiresAt = sentAt + PING_TIMEOUT_MS
        }
    end

    os.queueEvent(
        "ccbase_ccdp_ping_started",
        destination,
        ok == true,
        err or pingId
    )

    return ok, err or pingId
end

function DatagramService:handleDiagnostic(
    source,
    sourcePort,
    destinationPort,
    data
)
    if destinationPort == CCDP.DIAGNOSTIC_PORT and
        data.kind == "echo_request"
    then
        self:sendPayload(
            source,
            CCDP.DIAGNOSTIC_PORT,
            sourcePort,
            {
                kind = "echo_reply",
                pingId = data.pingId,
                sentAt = data.sentAt,
                responderAt = Protocol.nowMs()
            },
            {
                kind = "echo_reply"
            }
        )

        return true
    end

    if data.kind == "echo_reply" and
        type(data.pingId) == "string"
    then
        local pending = self.pendingPings[data.pingId]

        if pending then
            local latency = math.max(
                0,
                Protocol.nowMs() - pending.sentAt
            )

            self.pendingPings[data.pingId] = nil

            os.queueEvent(
                "ccbase_ccdp_pong",
                source,
                latency,
                data.pingId
            )

            return true
        end
    end

    return false
end

function DatagramService:handleIPPacket(
    source,
    destination,
    protocolId,
    sourcePort,
    destinationPort,
    payload,
    ipPacketId
)
    if protocolId ~= CCIP.PROTOCOL_CCDP then
        return false
    end

    local valid, reason = CCDP.validate(payload)

    if not valid then
        self.lastError = tostring(reason)
        return false
    end

    self.lastError = ""

    if self:handleDiagnostic(
        source,
        sourcePort,
        destinationPort,
        payload.payload
    ) then
        return true
    end

    os.queueEvent(
        "ccbase_ccdp_datagram",
        source,
        sourcePort,
        destinationPort,
        payload.payload,
        payload.datagramId,
        ipPacketId
    )

    return true
end

function DatagramService:handleIPSendResult(
    ipRequestId,
    ok,
    detail
)
    local pending = self.pending[ipRequestId]

    if not pending then
        return false
    end

    self.pending[ipRequestId] = nil

    if pending.requestId ~= nil then
        os.queueEvent(
            "ccbase_ccdp_send_result",
            pending.requestId,
            ok == true,
            detail or pending.datagramId,
            pending.datagramId
        )
    end

    return true
end

function DatagramService:checkPingTimeouts()
    local now = Protocol.nowMs()
    local expired = {}

    for pingId, pending in pairs(self.pendingPings) do
        if now >= pending.expiresAt then
            table.insert(expired, pingId)
        end
    end

    for _, pingId in ipairs(expired) do
        local pending = self.pendingPings[pingId]
        self.pendingPings[pingId] = nil

        os.queueEvent(
            "ccbase_ccdp_ping_failed",
            pending.destination,
            "timeout",
            pingId
        )
    end
end

function DatagramService:run()
    self.running = true
    local timer = os.startTimer(0.25)

    while self.running do
        local event, a, b, c, d, e, f, g = os.pullEvent()

        if event == "ccbase_ip_packet" then
            self:handleIPPacket(a, b, c, d, e, f, g)

        elseif event == "ccbase_ip_send_result" then
            self:handleIPSendResult(a, b, c)

        elseif event == "ccbase_ccdp_send" then
            local ok, err = self:send(a, b, c, d, e)

            if not ok and e ~= nil then
                os.queueEvent(
                    "ccbase_ccdp_send_result",
                    e,
                    false,
                    err or "ccdp_send_failed",
                    d and d.datagramId or ""
                )
            end

        elseif event == "ccbase_ccdp_ping" then
            self:ping(a)

        elseif event == "timer" and a == timer then
            self:checkPingTimeouts()
            timer = os.startTimer(0.25)
        end
    end
end

function DatagramService:stop()
    self.running = false
end

return DatagramService
