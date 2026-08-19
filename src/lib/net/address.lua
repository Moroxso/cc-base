local Address = {}

Address.VERSION = 1
Address.PREFIX = 10
Address.MAX_COMPUTER_ID = 16777214
Address.MAX_IPV4 = 4294967295

function Address.parse(address)
    if type(address) ~= "string" then
        return nil
    end

    local a, b, c, d = address:match(
        "^(%d+)%.(%d+)%.(%d+)%.(%d+)$"
    )

    a = tonumber(a)
    b = tonumber(b)
    c = tonumber(c)
    d = tonumber(d)

    if not a or not b or not c or not d then
        return nil
    end

    if a < 0 or a > 255 or
        b < 0 or b > 255 or
        c < 0 or c > 255 or
        d < 0 or d > 255
    then
        return nil
    end

    return a, b, c, d
end

function Address.isIPv4(address)
    return Address.parse(address) ~= nil
end

function Address.toInteger(address)
    local a, b, c, d = Address.parse(address)

    if not a then
        return nil, "invalid_address"
    end

    return ((a * 256 + b) * 256 + c) * 256 + d
end

function Address.fromInteger(value)
    value = tonumber(value)

    if not value or value ~= math.floor(value) or
        value < 0 or value > Address.MAX_IPV4
    then
        return nil, "invalid_address_integer"
    end

    local a = math.floor(value / 16777216) % 256
    local b = math.floor(value / 65536) % 256
    local c = math.floor(value / 256) % 256
    local d = value % 256

    return string.format("%d.%d.%d.%d", a, b, c, d)
end

function Address.isValid(address)
    local a, b, c, d = Address.parse(address)

    if not a or a ~= Address.PREFIX then
        return false
    end

    local node = b * 65536 + c * 256 + d
    return node >= 1 and node <= 16777215
end

function Address.forComputer(computerId)
    computerId = tonumber(computerId)

    if not computerId or computerId ~= math.floor(computerId) then
        return nil, "invalid_computer_id"
    end

    if computerId < 0 or computerId > Address.MAX_COMPUTER_ID then
        return nil, "computer_id_out_of_range"
    end

    local node = computerId + 1
    local b = math.floor(node / 65536) % 256
    local c = math.floor(node / 256) % 256
    local d = node % 256

    return string.format(
        "%d.%d.%d.%d",
        Address.PREFIX,
        b,
        c,
        d
    )
end

function Address.toComputerId(address)
    local a, b, c, d = Address.parse(address)

    if not a or a ~= Address.PREFIX then
        return nil, "invalid_address"
    end

    local node = b * 65536 + c * 256 + d

    if node < 1 or node > 16777215 then
        return nil, "invalid_node"
    end

    return node - 1
end

function Address.networkAddress(address, prefix)
    prefix = tonumber(prefix)

    if not prefix or prefix ~= math.floor(prefix) or
        prefix < 0 or prefix > 32
    then
        return nil, "invalid_prefix"
    end

    local value, err = Address.toInteger(address)

    if value == nil then
        return nil, err
    end

    if prefix == 0 then
        return "0.0.0.0"
    end

    local block = 2 ^ (32 - prefix)
    local network = math.floor(value / block) * block

    return Address.fromInteger(network)
end

function Address.matches(address, network, prefix)
    prefix = tonumber(prefix)

    if not prefix or prefix ~= math.floor(prefix) or
        prefix < 0 or prefix > 32
    then
        return false
    end

    local addressValue = Address.toInteger(address)
    local networkValue = Address.toInteger(network)

    if addressValue == nil or networkValue == nil then
        return false
    end

    if prefix == 0 then
        return true
    end

    local block = 2 ^ (32 - prefix)

    return math.floor(addressValue / block) ==
        math.floor(networkValue / block)
end

function Address.localAddress()
    return Address.forComputer(os.getComputerID())
end

return Address
