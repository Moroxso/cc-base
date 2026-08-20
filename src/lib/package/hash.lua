local Hash = {}

local bit = bit32

local function requireBit32()
    if type(bit) ~= "table" then
        return nil, "bit32_unavailable"
    end

    return bit
end

local function add32(...)
    local total = 0

    for index = 1, select("#", ...) do
        total = (total + (select(index, ...))) % 4294967296
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

function Hash.sha1(content)
    if type(content) ~= "string" then
        return nil, "hash_content_not_string"
    end

    local available, err = requireBit32()

    if not available then
        return nil, err
    end

    bit = available

    local bitLength = #content * 8
    local highLength = math.floor(bitLength / 4294967296)
    local lowLength = bitLength % 4294967296

    local message = content .. string.char(0x80)
    local padding = (56 - (#message % 64)) % 64
    message = message .. string.rep("\0", padding)
    message = message .. wordToBytes(highLength) .. wordToBytes(lowLength)

    local h0 = 0x67452301
    local h1 = 0xefcdab89
    local h2 = 0x98badcfe
    local h3 = 0x10325476
    local h4 = 0xc3d2e1f0
    local words = {}

    for chunkStart = 1, #message, 64 do
        for index = 0, 15 do
            local offset = chunkStart + index * 4
            local a, b, c, d = string.byte(message, offset, offset + 3)

            words[index] = bit.bor(
                bit.lshift(a, 24),
                bit.lshift(b, 16),
                bit.lshift(c, 8),
                d
            )
        end

        for index = 16, 79 do
            words[index] = bit.lrotate(
                bit.bxor(
                    words[index - 3],
                    words[index - 8],
                    words[index - 14],
                    words[index - 16]
                ),
                1
            )
        end

        local a = h0
        local b = h1
        local c = h2
        local d = h3
        local e = h4

        for index = 0, 79 do
            local roundFunction
            local constant

            if index <= 19 then
                roundFunction = bit.bor(
                    bit.band(b, c),
                    bit.band(bit.bnot(b), d)
                )
                constant = 0x5a827999
            elseif index <= 39 then
                roundFunction = bit.bxor(b, c, d)
                constant = 0x6ed9eba1
            elseif index <= 59 then
                roundFunction = bit.bor(
                    bit.band(b, c),
                    bit.band(b, d),
                    bit.band(c, d)
                )
                constant = 0x8f1bbcdc
            else
                roundFunction = bit.bxor(b, c, d)
                constant = 0xca62c1d6
            end

            local temp = add32(
                bit.lrotate(a, 5),
                roundFunction,
                e,
                constant,
                words[index]
            )

            e = d
            d = c
            c = bit.lrotate(b, 30)
            b = a
            a = temp
        end

        h0 = add32(h0, a)
        h1 = add32(h1, b)
        h2 = add32(h2, c)
        h3 = add32(h3, d)
        h4 = add32(h4, e)
    end

    return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

function Hash.gitBlob(content)
    if type(content) ~= "string" then
        return nil, "hash_content_not_string"
    end

    return Hash.sha1("blob " .. tostring(#content) .. "\0" .. content)
end

return Hash
