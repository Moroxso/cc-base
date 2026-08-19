local Address = require("lib.net.address")
local Protocol = require("lib.net.protocol")

local CCTP = {}

CCTP.VERSION = 1
CCTP.PROTOCOL_ID = 6
CCTP.MAX_SERIALIZED_SIZE = 2048
CCTP.EPHEMERAL_MIN = 49152
CCTP.EPHEMERAL_MAX = 65535
CCTP.DIAGNOSTIC_PORT = 7

CCTP.TYPE_SYN = "SYN"
CCTP.TYPE_SYN_ACK = "SYN_ACK"
CCTP.TYPE_ACK = "ACK"
CCTP.TYPE_DATA = "DATA"
CCTP.TYPE_FIN = "FIN"
CCTP.TYPE_FIN_ACK = "FIN_ACK"
CCTP.TYPE_RST = "RST"

local VALID_TYPES = {
    SYN = true,
    SYN_ACK = true,
    ACK = true,
    DATA = true,
    FIN = true,
    FIN_ACK = true,
    RST = true
}

local sequence = 0
local ephemeralSequence = 0

local function serializedSize(value)
    local ok, serialized = pcall(
        textutils.serializeJSON,
        value
    )

    if not ok or type(serialized) ~= "string" then
        return nil
    end

    return #serialized
end

local function integer(value, minimum, maximum)
    if type(value) ~= "number" or value ~= math.floor(value) then
        return false
    end

    if minimum ~= nil and value < minimum then
        return false
    end

    if maximum ~= nil and value > maximum then
        return false
    end

    return true
end

local function newRequestId(prefix)
    sequence = sequence + 1

    return string.format(
        "%s:%d:%d:%d",
        prefix,
        os.getComputerID(),
        Protocol.nowMs(),
        sequence
    )
end

function CCTP.nextEphemeralPort()
    ephemeralSequence = ephemeralSequence + 1

    local range = CCTP.EPHEMERAL_MAX - CCTP.EPHEMERAL_MIN + 1
    local offset = (
        os.getComputerID() * 521 + ephemeralSequence
    ) % range

    return CCTP.EPHEMERAL_MIN + offset
end

function CCTP.newConnectionId()
    return string.format(
        "tcp:%d:%d:%d:%06d",
        os.getComputerID(),
        Protocol.nowMs(),
        sequence + 1,
        math.random(0, 999999)
    )
end

function CCTP.newSegment(segmentType, connectionId, seq, ack, payload, options)
    options = options or {}

    local segment = {
        version = CCTP.VERSION,
        type = tostring(segmentType or ""),
        connectionId = tostring(connectionId or ""),
        segmentId = options.segmentId or newRequestId("seg"),
        seq = math.floor(tonumber(seq) or -1),
        ack = math.floor(tonumber(ack) or 0),
        createdAt = options.createdAt or Protocol.nowMs(),
        payload = type(payload) == "table" and payload or {}
    }

    local ok, err = CCTP.validate(segment)

    if not ok then
        return nil, err
    end

    return segment
end

function CCTP.validate(segment)
    if type(segment) ~= "table" then
        return false, "cctp_not_table"
    end

    if segment.version ~= CCTP.VERSION then
        return false, "cctp_version_unsupported"
    end

    if not VALID_TYPES[segment.type] then
        return false, "cctp_bad_type"
    end

    if type(segment.connectionId) ~= "string" or
        segment.connectionId == "" or
        #segment.connectionId > 128
    then
        return false, "cctp_bad_connection_id"
    end

    if type(segment.segmentId) ~= "string" or
        segment.segmentId == "" or
        #segment.segmentId > 128
    then
        return false, "cctp_bad_segment_id"
    end

    if not integer(segment.seq, 0, 2147483647) then
        return false, "cctp_bad_sequence"
    end

    if not integer(segment.ack, 0, 2147483647) then
        return false, "cctp_bad_ack"
    end

    if type(segment.createdAt) ~= "number" then
        return false, "cctp_bad_created_at"
    end

    if type(segment.payload) ~= "table" then
        return false, "cctp_bad_payload"
    end

    local size = serializedSize(segment)

    if not size then
        return false, "cctp_not_serializable"
    end

    if size > CCTP.MAX_SERIALIZED_SIZE then
        return false, "cctp_too_large"
    end

    return true
end

function CCTP.listen(port, listenerId, requestId)
    port = tonumber(port)

    if not port or port ~= math.floor(port) or port < 1 or port > 65535 then
        return nil, "cctp_bad_listen_port"
    end

    if port == CCTP.DIAGNOSTIC_PORT then
        return nil, "cctp_reserved_port"
    end

    listenerId = tostring(listenerId or "app")
    requestId = requestId or newRequestId("listen")

    os.queueEvent(
        "ccbase_cctp_listen",
        math.floor(port),
        listenerId,
        requestId
    )

    return requestId
end

function CCTP.unlisten(port, listenerId, requestId)
    port = tonumber(port)

    if not port or port ~= math.floor(port) or port < 1 or port > 65535 then
        return nil, "cctp_bad_listen_port"
    end

    requestId = requestId or newRequestId("unlisten")

    os.queueEvent(
        "ccbase_cctp_unlisten",
        math.floor(port),
        listenerId,
        requestId
    )

    return requestId
end

function CCTP.connect(destination, destinationPort, options)
    options = options or {}

    if not Address.isValid(destination) then
        return nil, "cctp_bad_destination"
    end

    destinationPort = tonumber(destinationPort)

    if not destinationPort or
        destinationPort ~= math.floor(destinationPort) or
        destinationPort < 1 or
        destinationPort > 65535
    then
        return nil, "cctp_bad_destination_port"
    end

    local sourcePort = tonumber(options.sourcePort)

    if sourcePort == nil then
        sourcePort = CCTP.nextEphemeralPort()
    end

    if sourcePort ~= math.floor(sourcePort) or
        sourcePort < 1 or sourcePort > 65535
    then
        return nil, "cctp_bad_source_port"
    end

    local requestId = options.requestId or newRequestId("connect")

    os.queueEvent(
        "ccbase_cctp_connect",
        destination,
        math.floor(sourcePort),
        math.floor(destinationPort),
        requestId
    )

    return requestId
end

function CCTP.send(connectionId, payload, requestId)
    if type(connectionId) ~= "string" or connectionId == "" then
        return nil, "cctp_bad_connection_id"
    end

    if type(payload) ~= "table" then
        return nil, "cctp_bad_payload"
    end

    requestId = requestId or newRequestId("send")

    os.queueEvent(
        "ccbase_cctp_send",
        connectionId,
        payload,
        requestId
    )

    return requestId
end

function CCTP.close(connectionId, requestId)
    if type(connectionId) ~= "string" or connectionId == "" then
        return nil, "cctp_bad_connection_id"
    end

    requestId = requestId or newRequestId("close")

    os.queueEvent(
        "ccbase_cctp_close",
        connectionId,
        requestId
    )

    return requestId
end

return CCTP