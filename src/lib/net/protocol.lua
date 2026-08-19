local Protocol = {}

Protocol.VERSION = 1
Protocol.MAGIC = "CCBASE"
Protocol.REDNET_PROTOCOL = "ccbase.net"
Protocol.MAX_SERIALIZED_SIZE = 4096

local sequence = 0

local function nowMs()
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")

        if ok and type(value) == "number" then
            return value
        end
    end

    return math.floor(os.clock() * 1000)
end

local function serializedSize(value)
    if not textutils or not textutils.serializeJSON then
        return nil
    end

    local ok, serialized = pcall(textutils.serializeJSON, value)

    if not ok or type(serialized) ~= "string" then
        return nil
    end

    return #serialized
end

local function newPacketId()
    sequence = sequence + 1

    return string.format(
        "%d:%d:%d:%d",
        os.getComputerID(),
        nowMs(),
        sequence,
        math.random(1000, 9999)
    )
end

function Protocol.new(service, messageType, payload, options)
    options = options or {}

    local packet = {
        magic = Protocol.MAGIC,
        version = Protocol.VERSION,
        service = tostring(service or "core"),
        type = tostring(messageType or "message"),
        sender = os.getComputerID(),
        packetId = options.packetId or newPacketId(),
        createdAt = options.createdAt or nowMs(),
        payload = type(payload) == "table" and payload or {}
    }

    if options.session ~= nil then
        packet.session = tostring(options.session)
    end

    if options.seq ~= nil then
        packet.seq = math.floor(tonumber(options.seq) or 0)
    end

    return packet
end

function Protocol.validate(packet, rednetSender)
    if type(packet) ~= "table" then
        return false, "packet_not_table"
    end

    if packet.magic ~= Protocol.MAGIC then
        return false, "bad_magic"
    end

    if packet.version ~= Protocol.VERSION then
        return false, "unsupported_version"
    end

    if type(packet.sender) ~= "number" then
        return false, "bad_sender"
    end

    if rednetSender ~= nil and packet.sender ~= rednetSender then
        return false, "sender_mismatch"
    end

    if type(packet.service) ~= "string" or
        packet.service == "" or
        #packet.service > 64
    then
        return false, "bad_service"
    end

    if type(packet.type) ~= "string" or
        packet.type == "" or
        #packet.type > 64
    then
        return false, "bad_type"
    end

    if type(packet.packetId) ~= "string" or
        packet.packetId == "" or
        #packet.packetId > 128
    then
        return false, "bad_packet_id"
    end

    if type(packet.createdAt) ~= "number" then
        return false, "bad_created_at"
    end

    if packet.session ~= nil and
        (type(packet.session) ~= "string" or
         packet.session == "" or
         #packet.session > 128)
    then
        return false, "bad_session"
    end

    if packet.seq ~= nil and
        (type(packet.seq) ~= "number" or
         packet.seq < 1 or
         packet.seq ~= math.floor(packet.seq))
    then
        return false, "bad_sequence"
    end

    if type(packet.payload) ~= "table" then
        return false, "bad_payload"
    end

    local size = serializedSize(packet)

    if size and size > Protocol.MAX_SERIALIZED_SIZE then
        return false, "packet_too_large"
    end

    return true
end

function Protocol.nowMs()
    return nowMs()
end

return Protocol
