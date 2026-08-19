local Address = require("lib.net.address")
local CCIP = require("lib.net.ccip")
local CCTP = require("lib.net.cctp")
local Protocol = require("lib.net.protocol")

local StreamService = {}
StreamService.__index = StreamService

local WINDOW_SIZE = 4
local INITIAL_RTO_MS = 700
local MIN_RTO_MS = 250
local MAX_RTO_MS = 3000
local MAX_RETRIES = 5
local TIME_WAIT_MS = 5000
local MAINTENANCE_SECONDS = 0.2
local DIAGNOSTIC_BURST = WINDOW_SIZE
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

local function clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    elseif value > maximum then
        return maximum
    end

    return value
end

local function sortedInflight(conn)
    local result = {}

    for _, entry in pairs(conn.inflight or {}) do
        table.insert(result, entry)
    end

    table.sort(result, function(a, b)
        return a.seq < b.seq
    end)

    return result
end

local function oldestInflight(conn)
    local oldest = nil

    for _, entry in pairs(conn.inflight or {}) do
        if not oldest or entry.seq < oldest.seq then
            oldest = entry
        end
    end

    return oldest
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

function StreamService:newConnection(options)
    options = options or {}

    return {
        id = options.id,
        role = options.role,
        state = options.state,
        localPort = options.localPort,
        remoteAddress = options.remoteAddress,
        remotePort = options.remotePort,
        sendNext = options.sendNext or 0,
        recvNext = options.recvNext or 0,
        controlPending = nil,
        inflight = {},
        inflightCount = 0,
        sendQueue = {},
        closeRequested = false,
        closeRequestId = nil,
        connectRequestId = options.connectRequestId,
        connectedAnnounced = false,
        closeNotified = false,
        createdAt = Protocol.nowMs(),
        lastActivity = Protocol.nowMs(),
        listenerId = options.listenerId,
        diagnosticServer = options.diagnosticServer == true,
        diagnosticClient = options.diagnosticClient,
        srtt = nil,
        rttvar = nil,
        rto = INITIAL_RTO_MS
    }
end

function StreamService:updateRtt(conn, sampleMs)
    sampleMs = tonumber(sampleMs)

    if not conn or not sampleMs or sampleMs <= 0 then
        return
    end

    if not conn.srtt then
        conn.srtt = sampleMs
        conn.rttvar = sampleMs / 2
    else
        local difference = math.abs(conn.srtt - sampleMs)
        conn.rttvar = 0.75 * conn.rttvar + 0.25 * difference
        conn.srtt = 0.875 * conn.srtt + 0.125 * sampleMs
    end

    conn.rto = clamp(
        conn.srtt + math.max(100, 4 * conn.rttvar),
        MIN_RTO_MS,
        MAX_RTO_MS
    )
end

function StreamService:queueIP(
    destination,
    sourcePort,
    destinationPort,
    segment,
    connectionId,
    transmitKind,
    sequence
)
    local requestId = newInternalId("cctp-ip")

    self.pendingIP[requestId] = {
        connectionId = connectionId,
        transmitKind = transmitKind,
        sequence = sequence
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

function StreamService:transmitControl(conn)
    local pending = conn and conn.controlPending

    if not pending then
        return false
    end

    local now = Protocol.nowMs()

    if not pending.firstSentAt then
        pending.firstSentAt = now
    end

    pending.lastSentAt = now

    self:queueIP(
        conn.remoteAddress,
        conn.localPort,
        conn.remotePort,
        pending.segment,
        conn.id,
        "control",
        pending.segment.seq
    )

    return true
end

function StreamService:armControl(
    conn,
    segment,
    kind,
    requestId,
    expectedAck
)
    conn.controlPending = {
        segment = segment,
        kind = kind,
        requestId = requestId,
        expectedAck = expectedAck,
        retries = 0,
        firstSentAt = nil,
        lastSentAt = 0
    }

    self:transmitControl(conn)
end

function StreamService:transmitData(conn, entry)
    if not conn or not entry then
        return false
    end

    local now = Protocol.nowMs()

    if not entry.firstSentAt then
        entry.firstSentAt = now
    end

    entry.lastSentAt = now

    self:queueIP(
        conn.remoteAddress,
        conn.localPort,
        conn.remotePort,
        entry.segment,
        conn.id,
        "data",
        entry.seq
    )

    return true
end

function StreamService:sendUntracked(conn, segment)
    self:queueIP(
        conn.remoteAddress,
        conn.localPort,
        conn.remotePort,
        segment,
        conn.id,
        "untracked",
        segment.seq
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
        nil,
        "reset",
        0
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

function StreamService:notifyDataFailure(conn, entry, reason)
    if entry and entry.requestId then
        os.queueEvent(
            "ccbase_cctp_send_result",
            entry.requestId,
            false,
            reason,
            conn.id
        )
    end
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

    if conn.controlPending and conn.controlPending.requestId and
        conn.controlPending.kind == "fin"
    then
        os.queueEvent(
            "ccbase_cctp_close_result",
            conn.controlPending.requestId,
            false,
            reason,
            conn.id
        )
    end

    for _, entry in pairs(conn.inflight or {}) do
        self:notifyDataFailure(conn, entry, reason)
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
        (not conn.controlPending or conn.controlPending.kind ~= "fin")
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
            conn.diagnosticClient.expectedReplies = DIAGNOSTIC_BURST
            conn.diagnosticClient.replies = 0
            conn.diagnosticClient.seen = {}

            for index = 1, DIAGNOSTIC_BURST do
                self:queueData(
                    conn,
                    {
                        kind = "echo_request",
                        pingId = conn.diagnosticClient.pingId,
                        sample = index,
                        sentAt = conn.diagnosticClient.sentAt
                    },
                    nil
                )
            end
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

function StreamService:startFin(conn)
    if not conn or
        conn.state ~= "ESTABLISHED" or
        conn.controlPending or
        conn.inflightCount > 0 or
        #conn.sendQueue > 0 or
        not conn.closeRequested
    then
        return false
    end

    local segment, err = CCTP.newSegment(
        CCTP.TYPE_FIN,
        conn.id,
        conn.sendNext,
        conn.recvNext,
        {}
    )

    if not segment then
        self:failConnection(conn, err or "fin_build_failed")
        return false
    end

    conn.state = "FIN_WAIT"

    self:armControl(
        conn,
        segment,
        "fin",
        conn.closeRequestId,
        conn.sendNext + 1
    )

    return true
end

function StreamService:fillWindow(conn)
    if not conn or conn.state ~= "ESTABLISHED" then
        return false
    end

    local sent = false

    while conn.inflightCount < WINDOW_SIZE and #conn.sendQueue > 0 do
        local job = table.remove(conn.sendQueue, 1)
        local seq = conn.sendNext
        local segment, err = CCTP.newSegment(
            CCTP.TYPE_DATA,
            conn.id,
            seq,
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
        else
            conn.sendNext = conn.sendNext + 1

            local entry = {
                seq = seq,
                expectedAck = seq + 1,
                segment = segment,
                requestId = job.requestId,
                retries = 0,
                firstSentAt = nil,
                lastSentAt = 0
            }

            conn.inflight[seq] = entry
            conn.inflightCount = conn.inflightCount + 1
            self:transmitData(conn, entry)
            sent = true
        end
    end

    if conn.closeRequested and
        conn.inflightCount == 0 and
        #conn.sendQueue == 0
    then
        self:startFin(conn)
    end

    return sent
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

    if conn.closeRequested then
        if requestId then
            os.queueEvent(
                "ccbase_cctp_send_result",
                requestId,
                false,
                "connection_closing",
                conn.id
            )
        end
        return false
    end

    table.insert(conn.sendQueue, {
        payload = payload,
        requestId = requestId
    })

    self:fillWindow(conn)
    return true
end

function StreamService:completeControl(conn, ack)
    local pending = conn and conn.controlPending

    if not pending or ack < pending.expectedAck then
        return false
    end

    if pending.retries == 0 and pending.firstSentAt then
        self:updateRtt(
            conn,
            Protocol.nowMs() - pending.firstSentAt
        )
    end

    conn.sendNext = math.max(conn.sendNext, pending.expectedAck)
    conn.controlPending = nil
    conn.lastActivity = Protocol.nowMs()

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

function StreamService:ackData(conn, ack)
    ack = tonumber(ack)

    if not conn or not ack then
        return false
    end

    local acknowledged = {}

    for seq, entry in pairs(conn.inflight or {}) do
        if entry.expectedAck <= ack then
            table.insert(acknowledged, {
                seq = seq,
                entry = entry
            })
        end
    end

    if #acknowledged == 0 then
        return false
    end

    table.sort(acknowledged, function(a, b)
        return a.seq < b.seq
    end)

    local now = Protocol.nowMs()

    for _, item in ipairs(acknowledged) do
        local entry = item.entry

        if entry.retries == 0 and entry.firstSentAt then
            self:updateRtt(conn, now - entry.firstSentAt)
        end

        conn.inflight[item.seq] = nil
        conn.inflightCount = math.max(0, conn.inflightCount - 1)

        if entry.requestId then
            os.queueEvent(
                "ccbase_cctp_send_result",
                entry.requestId,
                true,
                entry.segment.segmentId,
                conn.id
            )
        end
    end

    conn.lastActivity = now

    if conn.state == "ESTABLISHED" then
        self:fillWindow(conn)
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
    local conn = self:newConnection({
        id = connectionId,
        role = "client",
        state = "SYN_SENT",
        localPort = sourcePort,
        remoteAddress = destination,
        remotePort = destinationPort,
        sendNext = isn,
        recvNext = 0,
        connectRequestId = requestId,
        diagnosticClient = diagnostic
    })

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

    self:armControl(
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
    local conn = self:newConnection({
        id = segment.connectionId,
        role = "server",
        state = "SYN_RECEIVED",
        localPort = destinationPort,
        remoteAddress = source,
        remotePort = sourcePort,
        sendNext = isn,
        recvNext = segment.seq + 1,
        listenerId = listenerId,
        diagnosticServer = diagnostic
    })

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

    self:armControl(
        conn,
        response,
        "syn_ack",
        nil,
        conn.sendNext + 1
    )

    return true
end

function StreamService:handleClientHandshake(conn, segment)
    local pending = conn and conn.controlPending

    if segment.type ~= CCTP.TYPE_SYN_ACK or
        not pending or pending.kind ~= "syn"
    then
        return false
    end

    if segment.ack ~= pending.expectedAck then
        return false
    end

    if pending.retries == 0 and pending.firstSentAt then
        self:updateRtt(
            conn,
            Protocol.nowMs() - pending.firstSentAt
        )
    end

    conn.sendNext = segment.ack
    conn.recvNext = segment.seq + 1
    conn.controlPending = nil

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
                sample = payload.sample,
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
        local sample = tonumber(payload.sample) or 0

        if not conn.diagnosticClient.seen[sample] then
            conn.diagnosticClient.seen[sample] = true
            conn.diagnosticClient.replies = conn.diagnosticClient.replies + 1
        end

        if conn.diagnosticClient.replies >=
            conn.diagnosticClient.expectedReplies and
            not conn.diagnosticClient.completed
        then
            local latency = math.max(
                0,
                Protocol.nowMs() - conn.diagnosticClient.sentAt
            )

            conn.diagnosticClient.completed = true

            os.queueEvent(
                "ccbase_cctp_pong",
                conn.remoteAddress,
                latency,
                payload.pingId,
                conn.id,
                WINDOW_SIZE,
                math.floor(conn.rto)
            )

            self:requestClose(conn, nil)
        end

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
    self:fillWindow(conn)
    return true
end

function StreamService:handleEstablishedSegment(conn, segment)
    if segment.ack and segment.ack > 0 then
        if conn.controlPending and
            segment.ack >= conn.controlPending.expectedAck
        then
            local removingConnection = conn.controlPending.kind == "fin"
            self:completeControl(conn, segment.ack)

            if removingConnection and not self.connections[conn.id] then
                return true
            end
        else
            self:ackData(conn, segment.ack)
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
        else
            -- Go-Back-N receive side: retain only contiguous data.
            -- Duplicate or out-of-order data receives the latest
            -- cumulative ACK and is not delivered to the application.
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
            self:transmitControl(conn)
            return true
        end

        if payload.type == CCTP.TYPE_ACK and
            conn.controlPending and
            payload.ack >= conn.controlPending.expectedAck
        then
            self:completeControl(conn, payload.ack)
            return true
        end

        return false
    end

    if conn.state == "TIME_WAIT" then
        if payload.ack and payload.ack > 0 then
            self:ackData(conn, payload.ack)
        end

        if payload.type == CCTP.TYPE_FIN and
            payload.seq < conn.recvNext
        then
            self:sendAck(conn, CCTP.TYPE_FIN_ACK)
            return true
        end

        return payload.type == CCTP.TYPE_ACK or
            payload.type == CCTP.TYPE_FIN_ACK
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

    if not conn then
        return true
    end

    if pending.transmitKind == "control" and conn.controlPending then
        conn.controlPending.lastSentAt = 0
    elseif pending.transmitKind == "data" then
        local entry = conn.inflight[pending.sequence]

        if entry then
            entry.lastSentAt = 0
        end
    end

    self.lastError = tostring(detail or "ip_send_failed")
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

function StreamService:retransmitWindow(conn)
    local entries = sortedInflight(conn)

    if #entries == 0 then
        return false
    end

    for _, entry in ipairs(entries) do
        entry.retries = entry.retries + 1
        self:transmitData(conn, entry)
    end

    conn.rto = clamp(conn.rto * 2, MIN_RTO_MS, MAX_RTO_MS)
    return true
end

function StreamService:checkTimers()
    local now = Protocol.nowMs()
    local failed = {}
    local expired = {}

    for id, conn in pairs(self.connections) do
        if conn.state == "TIME_WAIT" and
            now >= (conn.timeWaitUntil or 0)
        then
            table.insert(expired, id)
        elseif conn.controlPending and
            now - (conn.controlPending.lastSentAt or 0) >= conn.rto
        then
            if conn.controlPending.retries >= MAX_RETRIES then
                table.insert(failed, {
                    conn = conn,
                    reason = "retransmit_timeout"
                })
            else
                conn.controlPending.retries = conn.controlPending.retries + 1
                conn.rto = clamp(conn.rto * 2, MIN_RTO_MS, MAX_RTO_MS)
                self:transmitControl(conn)
            end
        elseif conn.inflightCount > 0 then
            local oldest = oldestInflight(conn)

            if oldest and now - (oldest.lastSentAt or 0) >= conn.rto then
                if oldest.retries >= MAX_RETRIES then
                    table.insert(failed, {
                        conn = conn,
                        reason = "retransmit_timeout"
                    })
                else
                    self:retransmitWindow(conn)
                end
            end
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