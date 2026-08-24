local Common = {}

Common.VERSION = 1
Common.MAGIC = "CCBASE-FLEET"
Common.REDNET_PROTOCOL = "ccbase.fleet.v1"
Common.DEFAULT_TTL = 4
Common.SEEN_TTL_MS = 30000
Common.SEEN_LIMIT = 256

local bit = bit32

local function nowMs()
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then return value end
    end
    return math.floor(os.clock() * 1000)
end
Common.nowMs = nowMs

local function add32(...)
    local total = 0
    for index = 1, select("#", ...) do
        total = (total + select(index, ...)) % 4294967296
    end
    return total
end

local function wordToBytes(value)
    return string.char(
        bit.band(bit.rshift(value, 24), 0xff),
        bit.band(bit.rshift(value, 16), 0xff),
        bit.band(bit.rshift(value, 8), 0xff),
        bit.band(value, 0xff)
    )
end

local function sha1Raw(content)
    if type(bit) ~= "table" then return nil, "bit32_unavailable" end
    if type(content) ~= "string" then return nil, "hash_content_not_string" end

    local bitLength = #content * 8
    local highLength = math.floor(bitLength / 4294967296)
    local lowLength = bitLength % 4294967296
    local message = content .. string.char(0x80)
    local padding = (56 - (#message % 64)) % 64
    message = message .. string.rep("\0", padding)
        .. wordToBytes(highLength) .. wordToBytes(lowLength)

    local h0, h1, h2, h3, h4 =
        0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
    local words = {}

    for chunkStart = 1, #message, 64 do
        for index = 0, 15 do
            local offset = chunkStart + index * 4
            local a, b, c, d = string.byte(message, offset, offset + 3)
            words[index] = bit.bor(
                bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d
            )
        end
        for index = 16, 79 do
            words[index] = bit.lrotate(bit.bxor(
                words[index - 3], words[index - 8], words[index - 14], words[index - 16]
            ), 1)
        end

        local a, b, c, d, e = h0, h1, h2, h3, h4
        for index = 0, 79 do
            local f, k
            if index <= 19 then
                f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d)); k = 0x5a827999
            elseif index <= 39 then
                f = bit.bxor(b, c, d); k = 0x6ed9eba1
            elseif index <= 59 then
                f = bit.bor(bit.band(b, c), bit.band(b, d), bit.band(c, d)); k = 0x8f1bbcdc
            else
                f = bit.bxor(b, c, d); k = 0xca62c1d6
            end
            local temp = add32(bit.lrotate(a, 5), f, e, k, words[index])
            e, d, c, b, a = d, c, bit.lrotate(b, 30), a, temp
        end

        h0, h1, h2, h3, h4 =
            add32(h0, a), add32(h1, b), add32(h2, c), add32(h3, d), add32(h4, e)
    end

    return wordToBytes(h0) .. wordToBytes(h1) .. wordToBytes(h2) .. wordToBytes(h3) .. wordToBytes(h4)
end

local function toHex(raw)
    return (raw:gsub(".", function(ch) return string.format("%02x", string.byte(ch)) end))
end

function Common.sha1(content)
    local raw, err = sha1Raw(content)
    if not raw then return nil, err end
    return toHex(raw)
end

local function xorPad(key, value)
    local out = {}
    for index = 1, 64 do
        out[index] = string.char(bit.bxor(string.byte(key, index), value))
    end
    return table.concat(out)
end

function Common.hmacSha1(key, message)
    if type(bit) ~= "table" then return nil, "bit32_unavailable" end
    key = tostring(key or "")
    message = tostring(message or "")
    if #key > 64 then
        local hashed, err = sha1Raw(key)
        if not hashed then return nil, err end
        key = hashed
    end
    key = key .. string.rep("\0", 64 - #key)
    local inner, err = sha1Raw(xorPad(key, 0x36) .. message)
    if not inner then return nil, err end
    local outer, outerErr = sha1Raw(xorPad(key, 0x5c) .. inner)
    if not outer then return nil, outerErr end
    return toHex(outer)
end

function Common.constantTimeEqual(a, b)
    a, b = tostring(a or ""), tostring(b or "")
    if #a ~= #b then return false end
    local diff = 0
    for index = 1, #a do
        diff = bit.bor(diff, bit.bxor(string.byte(a, index), string.byte(b, index)))
    end
    return diff == 0
end

local function canonical(value)
    local kind = type(value)
    if kind == "nil" then return "n" end
    if kind == "boolean" then return value and "b1" or "b0" end
    if kind == "number" then return "d" .. string.format("%.17g", value) end
    if kind == "string" then return "s" .. tostring(#value) .. ":" .. value end
    if kind ~= "table" then return "s" .. #tostring(value) .. ":" .. tostring(value) end

    local count = 0
    local max = 0
    local array = true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then array = false break end
        if key > max then max = key end
    end
    if array and max == count then
        local parts = {"a", tostring(count), ":"}
        for index = 1, count do parts[#parts + 1] = canonical(value[index]) end
        return table.concat(parts)
    end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {"m", tostring(#keys), ":"}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = canonical(key)
        parts[#parts + 1] = canonical(value[key])
    end
    return table.concat(parts)
end
Common.canonical = canonical

local function macInput(packet)
    return canonical({
        magic = packet.magic,
        version = packet.version,
        fleetId = packet.fleetId,
        origin = packet.origin,
        originBoot = packet.originBoot,
        sender = packet.sender,
        seq = packet.seq,
        ttl = packet.ttl,
        type = packet.type,
        target = packet.target,
        payload = packet.payload
    })
end

function Common.sign(packet, key)
    local mac, err = Common.hmacSha1(key, macInput(packet))
    if not mac then return nil, err end
    packet.mac = mac
    return packet
end

function Common.verify(packet, key, fleetId)
    if type(packet) ~= "table" then return false, "packet_not_table" end
    if packet.magic ~= Common.MAGIC or packet.version ~= Common.VERSION then return false, "bad_protocol" end
    if tostring(packet.fleetId or "") ~= tostring(fleetId or "") then return false, "wrong_fleet" end
    if type(packet.origin) ~= "number" or type(packet.sender) ~= "number" then return false, "bad_sender" end
    if type(packet.originBoot) ~= "string" or packet.originBoot == "" then return false, "bad_boot" end
    if type(packet.seq) ~= "number" or packet.seq < 1 or packet.seq ~= math.floor(packet.seq) then return false, "bad_seq" end
    if type(packet.ttl) ~= "number" or packet.ttl < 0 or packet.ttl > 16 then return false, "bad_ttl" end
    if type(packet.type) ~= "string" or packet.type == "" then return false, "bad_type" end
    if type(packet.payload) ~= "table" then return false, "bad_payload" end
    if type(packet.mac) ~= "string" then return false, "missing_mac" end
    local expected, err = Common.hmacSha1(key, macInput(packet))
    if not expected then return false, err end
    if not Common.constantTimeEqual(expected, packet.mac) then return false, "bad_mac" end
    return true
end

function Common.packetId(packet)
    return string.format("%d:%s:%d", packet.origin, packet.originBoot, packet.seq)
end

function Common.newPacket(config, state, messageType, target, payload, ttl)
    state.seq = (tonumber(state.seq) or 0) + 1
    local packet = {
        magic = Common.MAGIC,
        version = Common.VERSION,
        fleetId = config.fleetId,
        origin = os.getComputerID(),
        originBoot = state.bootId,
        sender = os.getComputerID(),
        seq = state.seq,
        ttl = math.max(0, math.min(16, math.floor(tonumber(ttl) or Common.DEFAULT_TTL))),
        type = tostring(messageType or "message"),
        target = target,
        payload = type(payload) == "table" and payload or {}
    }
    return Common.sign(packet, config.key)
end

function Common.forwardPacket(packet, key)
    if tonumber(packet.ttl) == nil or packet.ttl <= 0 then return nil, "ttl_exhausted" end
    local forwarded = {}
    for k, v in pairs(packet) do forwarded[k] = v end
    forwarded.sender = os.getComputerID()
    forwarded.ttl = packet.ttl - 1
    forwarded.mac = nil
    return Common.sign(forwarded, key)
end

function Common.newSeenCache()
    return {items = {}, order = {}}
end

function Common.seen(cache, packetId)
    local stamp = cache.items[packetId]
    return stamp ~= nil and nowMs() - stamp <= Common.SEEN_TTL_MS
end

function Common.markSeen(cache, packetId)
    local stamp = nowMs()
    if not cache.items[packetId] then cache.order[#cache.order + 1] = packetId end
    cache.items[packetId] = stamp
    while #cache.order > Common.SEEN_LIMIT do
        local old = table.remove(cache.order, 1)
        cache.items[old] = nil
    end
    local index = 1
    while index <= #cache.order do
        local id = cache.order[index]
        if stamp - (cache.items[id] or 0) > Common.SEEN_TTL_MS then
            cache.items[id] = nil
            table.remove(cache.order, index)
        else
            index = index + 1
        end
    end
end

local function isModem(name)
    if peripheral.hasType then
        local ok, result = pcall(peripheral.hasType, name, "modem")
        if ok then return result == true end
    end
    local ok, value = pcall(peripheral.getType, name)
    return ok and value == "modem"
end

function Common.openModems()
    local opened = {}
    for _, name in ipairs(peripheral.getNames()) do
        if isModem(name) then
            local ok, isOpen = pcall(rednet.isOpen, name)
            if not ok or not isOpen then pcall(rednet.open, name) end
            local checked, open = pcall(rednet.isOpen, name)
            if checked and open then opened[#opened + 1] = name end
        end
    end
    return opened
end

function Common.broadcast(packet)
    local ok, result = pcall(rednet.broadcast, packet, Common.REDNET_PROTOCOL)
    return ok and result ~= false
end

function Common.randomHex(length)
    length = math.max(8, math.floor(tonumber(length) or 32))
    local seed = nowMs() + os.getComputerID() * 7919
    pcall(math.randomseed, seed)
    local out = {}
    for i = 1, length do out[i] = string.format("%x", math.random(0, 15)) end
    return table.concat(out)
end

function Common.distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return nil end
    local ax, ay, az = tonumber(a.x), tonumber(a.y), tonumber(a.z)
    local bx, by, bz = tonumber(b.x), tonumber(b.y), tonumber(b.z)
    if not ax or not ay or not az or not bx or not by or not bz then return nil end
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz), dx, dy, dz
end

function Common.manhattan(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return nil end
    local ax, ay, az = tonumber(a.x), tonumber(a.y), tonumber(a.z)
    local bx, by, bz = tonumber(b.x), tonumber(b.y), tonumber(b.z)
    if not ax or not ay or not az or not bx or not by or not bz then return nil end
    return math.abs(ax - bx) + math.abs(ay - by) + math.abs(az - bz)
end

return Common
