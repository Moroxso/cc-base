local Protocol = require("lib.net.protocol")

local Pairing = {}

Pairing.TTL_MS = 120000

local function rollingHash(text)
    local hash = 2166136261
    local modulus = 2147483647

    for i = 1, #text do
        hash = (hash * 131 + text:byte(i)) % modulus
    end

    return hash
end

local function makeNonce(peerId)
    return string.format(
        "%d:%d:%d:%06d",
        os.getComputerID(),
        tonumber(peerId) or 0,
        Protocol.nowMs(),
        math.random(0, 999999)
    )
end

local function makeRequestId(peerId, nonce)
    return string.format(
        "pair:%d:%d:%08x",
        os.getComputerID(),
        tonumber(peerId) or 0,
        rollingHash(nonce)
    )
end

local function material(initiatorId, responderId, nonceA, nonceB)
    return table.concat({
        tostring(initiatorId),
        tostring(responderId),
        tostring(nonceA),
        tostring(nonceB)
    }, "|")
end

function Pairing.code(initiatorId, responderId, nonceA, nonceB)
    local value = rollingHash(
        "code|" .. material(
            initiatorId,
            responderId,
            nonceA,
            nonceB
        )
    ) % 1000000

    return string.format("%06d", value)
end

function Pairing.sessionId(initiatorId, responderId, nonceA, nonceB)
    local valueA = rollingHash(
        "session-a|" .. material(
            initiatorId,
            responderId,
            nonceA,
            nonceB
        )
    )

    local valueB = rollingHash(
        "session-b|" .. material(
            initiatorId,
            responderId,
            nonceA,
            nonceB
        )
    )

    return string.format("%08x%08x", valueA, valueB)
end

function Pairing.createOutgoing(peerId)
    peerId = math.floor(tonumber(peerId) or -1)

    if peerId < 0 or peerId == os.getComputerID() then
        return nil, "invalid_peer"
    end

    local nonceA = makeNonce(peerId)
    local now = Protocol.nowMs()

    return {
        peerId = peerId,
        role = "initiator",
        requestId = makeRequestId(peerId, nonceA),
        initiatorId = os.getComputerID(),
        responderId = peerId,
        nonceA = nonceA,
        nonceB = nil,
        code = nil,
        sessionId = nil,
        localConfirmed = false,
        remoteConfirmed = false,
        createdAt = now,
        expiresAt = now + Pairing.TTL_MS
    }
end

function Pairing.createIncoming(sender, payload)
    payload = type(payload) == "table" and payload or {}
    sender = math.floor(tonumber(sender) or -1)

    if sender < 0 or
        type(payload.requestId) ~= "string" or
        payload.requestId == "" or
        type(payload.nonceA) ~= "string" or
        payload.nonceA == ""
    then
        return nil, "bad_pair_request"
    end

    local nonceB = makeNonce(sender)
    local now = Protocol.nowMs()
    local code = Pairing.code(
        sender,
        os.getComputerID(),
        payload.nonceA,
        nonceB
    )

    return {
        peerId = sender,
        role = "responder",
        requestId = payload.requestId,
        initiatorId = sender,
        responderId = os.getComputerID(),
        nonceA = payload.nonceA,
        nonceB = nonceB,
        code = code,
        sessionId = Pairing.sessionId(
            sender,
            os.getComputerID(),
            payload.nonceA,
            nonceB
        ),
        localConfirmed = false,
        remoteConfirmed = false,
        createdAt = now,
        expiresAt = now + Pairing.TTL_MS
    }
end

function Pairing.applyChallenge(pending, sender, payload)
    payload = type(payload) == "table" and payload or {}

    if type(pending) ~= "table" or
        pending.role ~= "initiator" or
        pending.peerId ~= sender or
        payload.requestId ~= pending.requestId or
        type(payload.nonceB) ~= "string" or
        payload.nonceB == ""
    then
        return false, "bad_pair_challenge"
    end

    pending.nonceB = payload.nonceB
    pending.code = Pairing.code(
        pending.initiatorId,
        pending.responderId,
        pending.nonceA,
        pending.nonceB
    )
    pending.sessionId = Pairing.sessionId(
        pending.initiatorId,
        pending.responderId,
        pending.nonceA,
        pending.nonceB
    )

    return true
end

function Pairing.isExpired(pending, now)
    if type(pending) ~= "table" then
        return true
    end

    now = tonumber(now) or Protocol.nowMs()
    return now > (tonumber(pending.expiresAt) or 0)
end

function Pairing.publicState(pending)
    if type(pending) ~= "table" then
        return nil
    end

    return {
        peerId = pending.peerId,
        role = pending.role,
        requestId = pending.requestId,
        code = pending.code,
        localConfirmed = pending.localConfirmed == true,
        remoteConfirmed = pending.remoteConfirmed == true,
        expiresAt = pending.expiresAt
    }
end

return Pairing
