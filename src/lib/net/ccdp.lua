local Protocol = require("lib.net.protocol")

local CCDP = {}

CCDP.VERSION = 1
CCDP.PROTOCOL_ID = 17
CCDP.MAX_SERIALIZED_SIZE = 2048
CCDP.EPHEMERAL_MIN = 49152
CCDP.EPHEMERAL_MAX = 65535
CCDP.DIAGNOSTIC_PORT = 7

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

local function newDatagramId()
    sequence = sequence + 1

    return string.format(
        "udp:%d:%d:%d",
        os.getComputerID(),
        Protocol.nowMs(),
        sequence
    )
end

function CCDP.nextEphemeralPort()
    ephemeralSequence = ephemeralSequence + 1

    local range = CCDP.EPHEMERAL_MAX - CCDP.EPHEMERAL_MIN + 1
    local offset = (
        os.getComputerID() * 257 + ephemeralSequence
    ) % range

    return CCDP.EPHEMERAL_MIN + offset
end

function CCDP.new(payload, options)
    options = options or {}

    local datagram = {
        version = CCDP.VERSION,
        datagramId = options.datagramId or newDatagramId(),
        createdAt = options.createdAt or Protocol.nowMs(),
        payload = type(payload) == "table" and payload or {}
    }

    local ok, err = CCDP.validate(datagram)

    if not ok then
        return nil, err
    end

    return datagram
end

function CCDP.validate(datagram)
    if type(datagram) ~= "table" then
        return false, "ccdp_not_table"
    end

    if datagram.version ~= CCDP.VERSION then
        return false, "ccdp_version_unsupported"
    end

    if type(datagram.datagramId) ~= "string" or
        datagram.datagramId == "" or
        #datagram.datagramId > 128
    then
        return false, "ccdp_bad_datagram_id"
    end

    if type(datagram.createdAt) ~= "number" then
        return false, "ccdp_bad_created_at"
    end

    if type(datagram.payload) ~= "table" then
        return false, "ccdp_bad_payload"
    end

    local size = serializedSize(datagram)

    if not size then
        return false, "ccdp_not_serializable"
    end

    if size > CCDP.MAX_SERIALIZED_SIZE then
        return false, "ccdp_too_large"
    end

    return true
end

function CCDP.queueSend(destination, destinationPort, payload, options)
    options = options or {}

    destinationPort = tonumber(destinationPort)

    if not destinationPort or
        destinationPort ~= math.floor(destinationPort) or
        destinationPort < 1 or
        destinationPort > 65535
    then
        return nil, "ccdp_bad_destination_port"
    end

    local sourcePort = tonumber(options.sourcePort)

    if sourcePort == nil then
        sourcePort = CCDP.nextEphemeralPort()
    end

    if sourcePort ~= math.floor(sourcePort) or
        sourcePort < 1 or
        sourcePort > 65535
    then
        return nil, "ccdp_bad_source_port"
    end

    local datagram, err = CCDP.new(payload)

    if not datagram then
        return nil, err
    end

    local requestId = options.requestId or string.format(
        "ccdp-send:%d:%d:%d",
        os.getComputerID(),
        Protocol.nowMs(),
        sequence
    )

    os.queueEvent(
        "ccbase_ccdp_send",
        destination,
        sourcePort,
        math.floor(destinationPort),
        datagram,
        requestId
    )

    return requestId, datagram.datagramId
end

return CCDP
