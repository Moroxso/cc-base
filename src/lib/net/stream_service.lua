local Address = require("lib.net.address")
local CCIP = require("lib.net.ccip")
local CCTP = require("lib.net.cctp")
local Protocol = require("lib.net.protocol")

local StreamService = {}
StreamService.__index = StreamService

local RETRANSMIT_MS = 700
local MAX_RETRIES = 5
local TIME_WAIT_MS = 5000
local MAINTENANCE_SECONDS = 0.2
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

local function initialSequence()
    return math.random(10000, 900000000)
end

local function validPort(port)
    return type(port) == "number" and
        port == math.floor(port) and
        port >= 1 and port <= 65535
end

function StreamService.new()
    local self = setmetatable({}, StreamService)

    self.connections = {}
    self.listeners = {}
    self.pendingIP = {}
    self.running = false
    self.lastError = ""

    return self
end

function StreamService:queueIP(
    destination,
    sourcePort,
    destinationPort,
    segment,
    connectionId
)
    local requestId = newInternalId("cctp-ip")

    self.pendingIP[requestId] = {
        connectionId = connectionId
    }

    os.queueEvent(
        "ccbase_ip_send",
        destination,
        CCIP.PROTOCOL_CCTP,
        sourcePort,
        destinationPort,
        segment,
        requestId
    )

    return requestId
end

function StreamService:transmitPending(conn)
    if not conn or not conn.pending then
        return false
    end

    conn.pending.lastSentAt = Protocol.nowMs()

    self:queueIP(
        conn.remoteAddress,
        conn.localPort,
        conn.remotePort,
        conn.pending.segment,
        conn.id
    )

    return true
end

function StreamService:armPending(
    conn,
    segment,
    kind,
    requestId,
    expectedAck
)
    conn.pending = {
        segment = segment,
        kind = kind,
        requestId = requestId,
        expectedAck = expectedAck,
        retries = 0,
        lastSentAt = 0
    }

    self:transmitPending(conn)
end

function StreamService:sendUntracked(conn, segment)
    self:queueIP(
        conn.remoteAddress,
        conn.localPort,
        conn.remotePort,
        segment,
        conn.id
    )
end

function StreamService:sendAck(conn, segmentType)
    local segment = CCTP.newSegment(
        segmentType or CCTP.TYPE_ACK,
        conn.id,
        conn.sendNext,
        conn.recvNext,
        {}
    )

    if segment then
        self:sendUntracked(conn, segment)
    end
end

function StreamService:sendReset(
    destination,
    localPort,
    remotePort,
    connectionId,
    ack
)
    local segment = CCTP.newSegment(
        CCTP.TYPE_RST,
        connectionId,
        0,
        math.max(0, tonumber(ack) or 0),
        {}
    )

    if not segment then
        return false
    end

    self:queueIP(
        destination,
        localPort,
        remotePort,
        segment,
        nil
    )

    return true
end

function StreamService:emitClosed(conn, reason)
    if not conn or conn.closeNotified then
        return
    end

    conn.closeNotified = true

    os.queueEvent(
        "ccbase_cctp_closed",
        conn.id,
        reason or "closed",
        conn.remoteAddress,
        conn.remotePort,
        conn.localPort
    )
end

function StreamService:failConnection(conn, reason)
    if not conn or not self.connections[conn.id] then
        return
    end

    reason = tostring(reason or "connection_failed")

    if conn.connectRequestId and not conn.connectedAnnounced then
        os.queueEvent(
            "ccbase_cctp_connect_result",
            conn.connectRequestId,
            false,
            reason,
            conn.id
        )
    end

    if conn.pending and conn.pending.requestId then
        if conn.pending.kind == "data" then
            os.queueEvent(
                "ccbase_cctp_send_result",
                conn.pending.requestId,
                false,
                reason,
                conn.id
            )
        elseif conn.pending.kind == "fin" then
            os.queueEvent(
                "ccbase_cctp_close_result",
                conn.pending.requestId,
                false,
                reason,
                conn.id
            )
        end
    end

    for _, job in ipairs(conn.sendQueue or {}) do
        if job.requestId then
            os.queueEvent(
                "ccbase_cctp_send_result",
                job.requestId,
                false,
                reason,
                conn.id
            )
        end
    end

    if conn.closeRequestId and
        (not conn.pending or conn.pending.kind ~= "fin")
    then
        os.queueEvent(
            "ccbase_cctp_close_result",
            conn.closeRequestId,
            false,
            reason,
            conn.id
        )
    end

    if conn.diagnosticClient then
        os.queueEvent(
            "ccbase_cctp_ping_failed",
            conn.diagnosticClient.destination,
            reason,
            conn.diagnosticClient.pingId
        )
    end

    if conn.connectedAnnounced then
        self:emitClosed(conn, reason)
    end

    self.connections[conn.id] = nil
    self.lastError = reason
end

function StreamService:markEstablished(conn)
    if not conn or conn.connectedAnnounced then
        return
    end

    conn.state = "ESTABLISHED"
    conn.connectedAnnounced = true
    conn.lastActivity = Protocol.nowMs()

    if conn.role == "client" then
        if conn.connectRequestId then
            os.queueEvent(
                "ccbase_cctp_connect_result",
                conn.connectRequestId,
                true,
                conn.id,
                conn.remoteAddress,
                conn.remotePort,
                conn.localPort
            )
        end

        if conn.diagnosticClient then
            self:queueData(
                conn,
                {
                    kind = "echo_request",
                    pingId = conn.diagnosticClient.pingId,
                    sentAt = conn.diagnosticClient.sentAt
                },
                nil
            )
        end
    elseif not conn.diagnosticServer then
        os.queueEvent(
            "ccbase_cctp_accept",
            conn.listenerId or "",
            conn.id,
            conn.remoteAddress,
            conn.remotePort,
            conn.localPort
        )
    end
end

function StreamService:trySendNext(conn)
    if not conn or
        conn.state ~= "ESTABLISHED" or
        conn.pending
    then
        return false
    end

    local job = table.remove(conn.sendQueue, 1)

    if job then
        local segment, err = CCTP.newSegment(
            CCTP.TYPE_DATA,
            conn.id,
            conn.sendNext,
            conn.recvNext,
            job.payload
        )

        if not segment then
            if job.requestId then
                os.queueEvent(
                    "ccbase_cctp_send_result",
                    job.requestId,
                    false,
                    err or "segment_build_failed",
                    conn.id
                )
            end

            return self:trySendNext(conn)
        end

        self:armPending(
            conn,
            segment,
            "data",
            job.requestId,
            conn.sendNext + 1
        )

        return true
    end

    if conn.closeRequested then
        local segment, err = CCTP.newSegment(
            CCTP.TYPE_FIN,
            conn.id,
            conn.sendNext,
            conn.recvNext,
            {}
        )

        if not segment then
            self:failConnection(
                conn,
                err or "fin_build_failed"
            )
            return false
        end

        conn.state = "FIN_WAIT"

        self:armPending(
            conn,
            segment,
            "fin",
            conn.closeRequestId,
            conn.sendNext + 1
        )

        return true
    end

    return false
end

function StreamService:queueData(conn, payload, requestId)
    if not conn or conn.state ~= "ESTABLISHED" then
        if requestId then
            os.queueEvent(
                "ccbase_cctp_send_result",
                requestId,
                false,
                "connection_not_established",
                conn and conn.id or ""
            )
        end
        return false
    end

    if type(payload) ~= "table" then
        if requestId then
            os.queueEvent(
                "ccbase_cctp_send_result",
                requestId,
                false,
                "cctp_bad_payload",
                conn.id
            )
        end
        return false
    end

    table.insert(conn.sendQueue, {
        payload = payload,
        requestId = requestId
    })

    self:trySendNext(conn)
    return true
end

function StreamService:completePending(conn, ack)
    local pending = conn and conn.pending

    if not pending or ack < pending.expectedAck then
        return false
    end

    conn.sendNext = math.max(
        conn.sendNext,
        pending.expectedAck
    )
    conn.pending = nil
    conn.lastActivity = Protocol.nowMs()

    if pending.kind == "data" then
        if pending.requestId then
            os.queueEvent(
                "ccbase_cctp_send_result",
                pending.requestId,
                true,
                pending.segment.segmentId,
                conn.id
            )
        end

        if conn.state == "ESTABLISHED" then
            self:trySendNext(conn)
        end

        return true
    end

    if pending.kind == "syn_ack" then
        self:markEstablished(conn)
        return true
    end

    if pending.kind == "fin" then
        if pending.requestId then
            os.queueEvent(
                "ccbase_cctp_close_result",
                pending.requestId,
                true,
                "closed",
                conn.id
            )
        end

        self:emitClosed(conn, "local_close")
        self.connections[conn.id] = nil
        return true
    end

    return true
end

function StreamService:startConnect(
    destination,
    sourcePort,
    destinationPort,
    requestId,
    diagnostic
)
    if not Address.isValid(destination) then
        return nil, "cctp_bad_destination"
    end

    if not validPort(sourcePort) or not validPort(destinationPort) then
        return nil, "cctp_bad_port"
    end

    local connectionId = CCTP.newConnectionId()

    while self.connections[connectionId] do
        connectionId = CCTP.newConnectionId()
    end

    local isn = initialSequence()
    local conn = {
        id = connectionId,
        role = "client",
        state = "SYN_SENT",
        localPort = sourcePort,
        remoteAddress = destination,
        remotePort = destinationPort,
        sendNext = isn,
        recvNext = 0,
        pending = nil,
        sendQueue = {},
        closeRequested = false,
        closeRequestId = nil,
        connectRequestId = requestId,
        connectedAnnounced = false,
        closeNotified = false,
        createdAt = Protocol.nowMs(),
        lastActivity = Protocol.nowMs(),
        diagnosticClient = diagnostic
    }

    self.connections[connectionId] = conn

    local segment, err = CCTP.newSegment(
        CCTP.TYPE_SYN,
        conn.id,
        conn.sendNext,
        0,
        {}
    )

    if not segment then
        self.connections[connectionId] = nil
        return nil, err
    end

    self:armPending(
        conn,
        segment,
        "syn",
        nil,
        conn.sendNext + 1
    )

    return conn
end

function StreamService:acceptSyn(
    source,
    sourcePort,
    destinationPort,
    segment
)
    local listenerId = self.listeners[destinationPort]
    local diagnostic = destinationPort == CCTP.DIAGNOSTIC_PORT

    if not diagnostic and not listenerId then
        self:sendReset(
            source,
            destinationPort,
            sourcePort,
            segment.connectionId,
            segment.seq + 1
        )
        return false
    end

    local isn = initialSequence()
    local conn = {
        id = segment.connectionId,
        role = "server",
        state = "SYN_RECEIVED",
        localPort = destinationPort,
        remoteAddress = source,
        remotePort = sourcePort,
        sendNext = isn,
        recvNext = segment.seq + 1,
        pending = nil,
        sendQueue = {},
        closeRequested = false,
        closeRequestId = nil,
        connectRequestId = nil,
        connectedAnnounced = false,
        closeNotified = false,
        createdAt = Protocol.nowMs(),
        lastActivity = Protocol.nowMs(),
        listenerId = listenerId,
        diagnosticServer = diagnostic
    }

    self.connections[conn.id] = conn

    local response, err = CCTP.newSegment(
        CCTP.TYPE_SYN_ACK,
        conn.id,
        conn.sendNext,
        conn.recvNext,
        {}
    )

    if not response then
        self.connections[conn.id] = nil
        self.lastError = tostring(err)
        return false
    end

    self:armPending(
        conn,
        response,
        "syn_ack",
        nil,
        conn.sendNext + 1
    )

    return true
end

function StreamService:handleClientHandshake(conn, segment)
    if segment.type ~= CCTP.TYPE_SYN_ACK then
        return false
    end

    if not conn.pending or conn.pending.kind ~= "syn" then
        return false
    end

    if segment.ack ~= conn.pending.expectedAck then
        return false
    end

    conn.sendNext = segment.ack
    conn.recvNext = segment.seq + 1
    conn.pending = nil

    self:sendAck(conn, CCTP.TYPE_ACK)
    self:markEstablished(conn)
    return true
end

function StreamService:deliverData(conn, payload)
    if conn.diagnosticServer and payload.kind == "echo_request" then
        self:queueData(
            conn,
            {
                kind = "echo_reply",
                pingId = payload.pingId,
                sentAt = payload.sentAt,
                responderAt = Protocol.nowMs()
            },
            nil
        )
        return true
    end

    if conn.diagnosticClient and
        payload.kind == "echo_reply" and
        payload.pingId == conn.diagnosticClient.pingId
    then
        local latency = math.max(
            0,
            Protocol.nowMs() - conn.diagnosticClient.sentAt
        )

        os.queueEvent(
            "ccbase_cctp_pong",
            conn.remoteAddress,
            latency,
            payload.pingId,
            conn.id
        )

        conn.diagnosticClient.completed = true
        self:requestClose(conn, nil)
        return true
    end

    os.queueEvent(
        "ccbase_cctp_receive",
        conn.id,
        payload,
        conn.remoteAddress,
        conn.remotePort,
        conn.localPort,
        conn.listenerId or ""
    )

    return true
end

function StreamService:requestClose(conn, requestId)
    if not conn then
        if requestId then
            os.queueEvent(
                "ccbase_cctp_close_result",
                requestId,
                false,
                "unknown_connection",
                ""
            )
        end
        return false
    end

    if conn.state ~= "ESTABLISHED" then
        if requestId then
            os.queueEvent(
                "ccbase_cctp_close_result",
                requestId,
                false,
                "connection_not_established",
                conn.id
            )
        end
        return false
    end

    conn.closeRequested = true
    conn.closeRequestId = requestId
    self:trySendNext(conn)
    return true
end

function StreamService:handleEstablishedSegment(conn, segment)
    if conn.pending and
        segment.ack >= conn.pending.expectedAck
    then
        local removed = conn.pending.kind == "fin"
        self:completePending(conn, segment.ack)

        if removed and not self.connections[conn.id] then
            return true
        end
    end

    if segment.type == CCTP.TYPE_ACK then
        return true
    end

    if segment.type == CCTP.TYPE_SYN_ACK then
        self:sendAck(conn, CCTP.TYPE_ACK)
        return true
    end

    if segment.type == CCTP.TYPE_DATA then
        if segment.seq == conn.recvNext then
            conn.recvNext = conn.recvNext + 1
            conn.lastActivity = Protocol.nowMs()
            self:sendAck(conn, CCTP.TYPE_ACK)
            self:deliverData(conn, segment.payload)
        elseif segment.seq < conn.recvNext then
            self:sendAck(conn, CCTP.TYPE_ACK)
        else
            self:sendAck(conn, CCTP.TYPE_ACK)
        end

        return true
    end

    if segment.type == CCTP.TYPE_FIN then
        if segment.seq == conn.recvNext then
            conn.recvNext = conn.recvNext + 1
            self:sendAck(conn, CCTP.TYPE_FIN_ACK)
            conn.state = "TIME_WAIT"
            conn.timeWaitUntil = Protocol.nowMs() + TIME_WAIT_MS
            self:emitClosed(conn, "remote_close")
        elseif segment.seq < conn.recvNext then
            self:sendAck(conn, CCTP.TYPE_FIN_ACK)
        else
            self:sendAck(conn, CCTP.TYPE_ACK)
        end

        return true
    end

    if segment.type == CCTP.TYPE_FIN_ACK then
        return true
    end

    return false
end

function StreamService:handleIPPacket(
    source,
    destination,
    protocolId,
    sourcePort,
    destinationPort,
    payload,
    ipPacketId
)
    if protocolId ~= CCIP.PROTOCOL_CCTP then
        return false
    end

    local valid, reason = CCTP.validate(payload)

    if not valid then
        self.lastError = tostring(reason)
        return false
    end

    local conn = self.connections[payload.connectionId]

    if not conn then
        if payload.type == CCTP.TYPE_SYN then
            return self:acceptSyn(
                source,
                sourcePort,
                destinationPort,
                payload
            )
        end

        if payload.type ~= CCTP.TYPE_RST then
            self:sendReset(
                source,
                destinationPort,
                sourcePort,
                payload.connectionId,
                payload.seq + 1
            )
        end

        return false
    end

    if conn.remoteAddress ~= source or
        conn.remotePort ~= sourcePort or
        conn.localPort ~= destinationPort
    then
        self.lastError = "cctp_connection_tuple_mismatch"
        return false
    end

    if payload.type == CCTP.TYPE_RST then
        self:failConnection(conn, "remote_reset")
        return true
    end

    conn.lastActivity = Protocol.nowMs()
    self.lastError = ""

    if conn.state == "SYN_SENT" then
        return self:handleClientHandshake(conn, payload)
    end

    if conn.state == "SYN_RECEIVED" then
        if payload.type == CCTP.TYPE_SYN then
            self:transmitPending(conn)
            return true
        end

        if payload.type == CCTP.TYPE_ACK and
            conn.pending and
            payload.ack >= conn.pending.expectedAck
        then
            self:completePending(conn, payload.ack)
            return true
        end

        return false
    end

    if conn.state == "TIME_WAIT" then
        if payload.type == CCTP.TYPE_FIN and
            payload.seq < conn.recvNext
        then
            self:sendAck(conn, CCTP.TYPE_FIN_ACK)
            return true
        end

        return false
    end

    if conn.state == "ESTABLISHED" or conn.state == "FIN_WAIT" then
        return self:handleEstablishedSegment(conn, payload)
    end

    return false
end

function StreamService:handleIPSendResult(requestId, ok, detail)
    local pending = self.pendingIP[requestId]

    if not pending then
        return false
    end

    self.pendingIP[requestId] = nil

    if ok then
        return true
    end

    local conn = pending.connectionId and
        self.connections[pending.connectionId] or nil

    if conn and conn.pending then
        conn.pending.lastSentAt = 0
        self.lastError = tostring(detail or "ip_send_failed")
    end

    return true
end

function StreamService:registerListener(port, listenerId, requestId)
    if not validPort(port) then
        os.queueEvent(
            "ccbase_cctp_listen_result",
            requestId,
            false,
            "bad_port",
            port or 0
        )
        return false
    end

    if port == CCTP.DIAGNOSTIC_PORT then
        os.queueEvent(
            "ccbase_cctp_listen_result",
            requestId,
            false,
            "reserved_port",
            port
        )
        return false
    end

    if self.listeners[port] then
        os.queueEvent(
            "ccbase_cctp_listen_result",
            requestId,
            false,
            "port_in_use",
            port
        )
        return false
    end

    self.listeners[port] = tostring(listenerId or "app")

    os.queueEvent(
        "ccbase_cctp_listen_result",
        requestId,
        true,
        self.listeners[port],
        port
    )

    return true
end

function StreamService:unregisterListener(port, listenerId, requestId)
    local current = self.listeners[port]

    if not current then
        os.queueEvent(
            "ccbase_cctp_listen_result",
            requestId,
            false,
            "not_listening",
            port or 0
        )
        return false
    end

    if listenerId ~= nil and tostring(listenerId) ~= current then
        os.queueEvent(
            "ccbase_cctp_listen_result",
            requestId,
            false,
            "listener_mismatch",
            port
        )
        return false
    end

    self.listeners[port] = nil

    os.queueEvent(
        "ccbase_cctp_listen_result",
        requestId,
        true,
        "closed",
        port
    )

    return true
end

function StreamService:ping(destination)
    local pingId = newInternalId("cctp-ping")
    local sentAt = Protocol.nowMs()
    local sourcePort = CCTP.nextEphemeralPort()

    local conn, err = self:startConnect(
        destination,
        sourcePort,
        CCTP.DIAGNOSTIC_PORT,
        nil,
        {
            pingId = pingId,
            sentAt = sentAt,
            destination = destination
        }
    )

    os.queueEvent(
        "ccbase_cctp_ping_started",
        destination,
        conn ~= nil,
        err or pingId
    )

    return conn ~= nil, err or pingId
end

function StreamService:checkTimers()
    local now = Protocol.nowMs()
    local failed = {}
    local expired = {}

    for id, conn in pairs(self.connections) do
        if conn.pending and
            now - (conn.pending.lastSentAt or 0) >= RETRANSMIT_MS
        then
            if conn.pending.retries >= MAX_RETRIES then
                table.insert(failed, {
                    conn = conn,
                    reason = "retransmit_timeout"
                })
            else
                conn.pending.retries = conn.pending.retries + 1
                self:transmitPending(conn)
            end
        elseif conn.state == "TIME_WAIT" and
            now >= (conn.timeWaitUntil or 0)
        then
            table.insert(expired, id)
        end
    end

    for _, item in ipairs(failed) do
        self:failConnection(item.conn, item.reason)
    end

    for _, id in ipairs(expired) do
        self.connections[id] = nil
    end
end

function StreamService:run()
    self.running = true
    local timer = os.startTimer(MAINTENANCE_SECONDS)

    while self.running do
        local event, a, b, c, d, e, f, g, h = os.pullEvent()

        if event == "ccbase_ip_packet" then
            self:handleIPPacket(a, b, c, d, e, f, g)

        elseif event == "ccbase_ip_send_result" then
            self:handleIPSendResult(a, b, c)

        elseif event == "ccbase_cctp_listen" then
            self:registerListener(a, b, c)

        elseif event == "ccbase_cctp_unlisten" then
            self:unregisterListener(a, b, c)

        elseif event == "ccbase_cctp_connect" then
            local conn, err = self:startConnect(a, b, c, d, nil)

            if not conn then
                os.queueEvent(
                    "ccbase_cctp_connect_result",
                    d,
                    false,
                    err or "connect_failed",
                    ""
                )
            end

        elseif event == "ccbase_cctp_send" then
            local conn = self.connections[a]

            if not conn then
                os.queueEvent(
                    "ccbase_cctp_send_result",
                    c,
                    false,
                    "unknown_connection",
                    tostring(a or "")
                )
            else
                self:queueData(conn, b, c)
            end

        elseif event == "ccbase_cctp_close" then
            self:requestClose(self.connections[a], b)

        elseif event == "ccbase_cctp_ping" then
            self:ping(a)

        elseif event == "timer" and a == timer then
            self:checkTimers()
            timer = os.startTimer(MAINTENANCE_SECONDS)
        end
    end
end

function StreamService:stop()
    self.running = false
end

return StreamService