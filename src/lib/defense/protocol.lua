local DefenseProtocol = {}

DefenseProtocol.VERSION = 1
DefenseProtocol.MAGIC = "CCBASE-DEFENSE"
DefenseProtocol.REDNET_PROTOCOL = "ccbase.defense.v1"

DefenseProtocol.MODE_SAFE = "SAFE"
DefenseProtocol.MODE_ARMED = "ARMED"
DefenseProtocol.MODE_LOCKDOWN = "LOCKDOWN"

DefenseProtocol.HEARTBEAT_SECONDS = 1
DefenseProtocol.CONTROLLER_BEACON_SECONDS = 2
DefenseProtocol.LINK_TIMEOUT_MS = 6500
DefenseProtocol.UNIT_OFFLINE_MS = 6500
DefenseProtocol.PENDING_TTL_MS = 120000
DefenseProtocol.MAX_PENDING = 16

local VALID_MODES = {
    [DefenseProtocol.MODE_SAFE] = true,
    [DefenseProtocol.MODE_ARMED] = true,
    [DefenseProtocol.MODE_LOCKDOWN] = true
}

local function nowMs()
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then
            return value
        end
    end

    return math.floor(os.clock() * 1000)
end

function DefenseProtocol.nowMs()
    return nowMs()
end

function DefenseProtocol.validMode(mode)
    return VALID_MODES[tostring(mode or "")] == true
end

function DefenseProtocol.packet(messageType, payload, options)
    options = type(options) == "table" and options or {}

    local packet = {
        magic = DefenseProtocol.MAGIC,
        version = DefenseProtocol.VERSION,
        type = tostring(messageType or "message"),
        sender = os.getComputerID(),
        createdAt = tonumber(options.createdAt) or nowMs(),
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

function DefenseProtocol.validate(packet, rednetSender)
    if type(packet) ~= "table" then
        return false, "packet_not_table"
    end

    if packet.magic ~= DefenseProtocol.MAGIC then
        return false, "bad_magic"
    end

    if packet.version ~= DefenseProtocol.VERSION then
        return false, "unsupported_version"
    end

    if type(packet.sender) ~= "number" then
        return false, "bad_sender"
    end

    if rednetSender ~= nil and packet.sender ~= rednetSender then
        return false, "sender_mismatch"
    end

    if type(packet.type) ~= "string" or packet.type == "" or #packet.type > 48 then
        return false, "bad_type"
    end

    if type(packet.createdAt) ~= "number" then
        return false, "bad_created_at"
    end

    if type(packet.payload) ~= "table" then
        return false, "bad_payload"
    end

    if packet.session ~= nil and
        (type(packet.session) ~= "string" or packet.session == "" or #packet.session > 128)
    then
        return false, "bad_session"
    end

    if packet.seq ~= nil and
        (type(packet.seq) ~= "number" or packet.seq < 1 or packet.seq ~= math.floor(packet.seq))
    then
        return false, "bad_sequence"
    end

    return true
end

function DefenseProtocol.isCombatCommand(command)
    command = tostring(command or "")
    return command == "attack"
        or command == "attack_up"
        or command == "attack_down"
end

function DefenseProtocol.isRemoteCommand(command)
    command = tostring(command or "")

    return DefenseProtocol.isCombatCommand(command)
        or command == "turn_left"
        or command == "turn_right"
        or command == "forward"
        or command == "back"
        or command == "up"
        or command == "down"
end

return DefenseProtocol
