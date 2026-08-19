local Address = require("lib.net.address")
local Protocol = require("lib.net.protocol")

local CCIP = {}

CCIP.VERSION = 1
CCIP.DEFAULT_TTL = 16
CCIP.MAX_TTL = 64

CCIP.PROTOCOL_CONTROL = 1
CCIP.PROTOCOL_CCTP = 6
CCIP.PROTOCOL_CCDP = 17
CCIP.PROTOCOL_RAW = 255

local packetSequence = 0

local function isInteger(value, minimum, maximum)
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

local function newPacketId()
    packetSequence = packetSequence + 1

    return string.format(
        "ip:%d:%d:%d",
        os.getComputerID(),
        Protocol.nowMs(),
        packetSequence
    )
end

function CCIP.new(destination, protocolId, sourcePort, destinationPort, payload, options)
    options = options or {}

    local source = options.source or Address.localAddress()
    local ttl = tonumber(options.ttl) or CCIP.DEFAULT_TTL

    local packet = {
        version = CCIP.VERSION,
        source = source,
        destination = destination,
        ttl = math.floor(ttl),
        protocol = math.floor(tonumber(protocolId) or -1),
        sourcePort = math.floor(tonumber(sourcePort) or 0),
        destinationPort = math.floor(tonumber(destinationPort) or 0),
        packetId = options.packetId or newPacketId(),
        createdAt = options.createdAt or Protocol.nowMs(),
        payload = type(payload) == "table" and payload or {}
    }

    local ok, err = CCIP.validate(packet)

    if not ok then
        return nil, err
    end

    return packet
end

function CCIP.validate(packet)
    if type(packet) ~= "table" then
        return false, "ip_packet_not_table"
    end

    if packet.version ~= CCIP.VERSION then
        return false, "ip_version_unsupported"
    end

    if not Address.isValid(packet.source) then
        return false, "ip_bad_source"
    end

    if not Address.isValid(packet.destination) then
        return false, "ip_bad_destination"
    end

    if not isInteger(packet.ttl, 1, CCIP.MAX_TTL) then
        return false, "ip_bad_ttl"
    end

    if not isInteger(packet.protocol, 0, 255) then
        return false, "ip_bad_protocol"
    end

    if not isInteger(packet.sourcePort, 0, 65535) then
        return false, "ip_bad_source_port"
    end

    if not isInteger(packet.destinationPort, 0, 65535) then
        return false, "ip_bad_destination_port"
    end

    if type(packet.packetId) ~= "string" or
        packet.packetId == "" or
        #packet.packetId > 128
    then
        return false, "ip_bad_packet_id"
    end

    if type(packet.createdAt) ~= "number" then
        return false, "ip_bad_created_at"
    end

    if type(packet.payload) ~= "table" then
        return false, "ip_bad_payload"
    end

    return true
end

function CCIP.decrementTTL(packet)
    if type(packet) ~= "table" or not isInteger(packet.ttl, 1, CCIP.MAX_TTL) then
        return false, "ip_bad_ttl"
    end

    if packet.ttl <= 1 then
        return false, "ip_ttl_expired"
    end

    packet.ttl = packet.ttl - 1
    return true
end

return CCIP
