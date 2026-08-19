local Protocol = require("lib.net.protocol")

local Transport = {}

local function isModem(name)
    if peripheral.hasType then
        local ok, result = pcall(
            peripheral.hasType,
            name,
            "modem"
        )

        if ok then
            return result == true
        end
    end

    local ok, peripheralType = pcall(
        peripheral.getType,
        name
    )

    return ok and peripheralType == "modem"
end

function Transport.getModems()
    local modems = {}

    for _, name in ipairs(peripheral.getNames()) do
        if isModem(name) then
            table.insert(modems, name)
        end
    end

    table.sort(modems)
    return modems
end

function Transport.openAll()
    local opened = {}
    local errors = {}

    for _, name in ipairs(Transport.getModems()) do
        local alreadyOpen = false
        local okOpenState, openState = pcall(
            rednet.isOpen,
            name
        )

        if okOpenState then
            alreadyOpen = openState == true
        end

        if not alreadyOpen then
            local ok, err = pcall(rednet.open, name)

            if not ok then
                errors[name] = tostring(err)
            end
        end

        local okCheck, isOpen = pcall(rednet.isOpen, name)

        if okCheck and isOpen then
            table.insert(opened, name)
        end
    end

    return opened, errors
end

function Transport.isOpen()
    local ok, result = pcall(rednet.isOpen)
    return ok and result == true
end

function Transport.send(recipient, packet)
    if type(recipient) ~= "number" then
        return false, "invalid_recipient"
    end

    if not Transport.isOpen() then
        return false, "rednet_not_open"
    end

    local ok, sent = pcall(
        rednet.send,
        recipient,
        packet,
        Protocol.REDNET_PROTOCOL
    )

    if not ok then
        return false, tostring(sent)
    end

    return sent == true
end

function Transport.broadcast(packet)
    if not Transport.isOpen() then
        return false, "rednet_not_open"
    end

    local ok, err = pcall(
        rednet.broadcast,
        packet,
        Protocol.REDNET_PROTOCOL
    )

    if not ok then
        return false, tostring(err)
    end

    return true
end

return Transport
