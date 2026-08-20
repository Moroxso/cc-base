-- BASE Defense Turtle Agent v1
-- Self-contained by design: copy this single file to an Advanced Turtle.

local VERSION = "0.23.0-alpha.1.1"
local MAGIC = "CCBASE-DEFENSE"
local PROTOCOL_VERSION = 1
local REDNET_PROTOCOL = "ccbase.defense.v1"
local CONFIG_PATH = "/data/defense_agent.json"

local MODE_SAFE = "SAFE"
local MODE_ARMED = "ARMED"
local MODE_LOCKDOWN = "LOCKDOWN"

local HEARTBEAT_SECONDS = 1
local LINK_TIMEOUT_MS = 6500

-- Slots 1-4 are deliberately reserved for fuel by the defense agent.
-- The agent only consumes items from these slots and never scans the rest
-- of the inventory for burnable items.
local FUEL_SLOTS = {1, 2, 3, 4}
local FUEL_LOW = 256
local FUEL_CRITICAL = 32
local FUEL_TARGET = 1024

if type(turtle) ~= "table" then
    error("BASE Defense Agent must run on a turtle", 0)
end

local function nowMs()
    if os.epoch then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then return value end
    end
    return math.floor(os.clock() * 1000)
end

local function validMode(mode)
    return mode == MODE_SAFE or mode == MODE_ARMED or mode == MODE_LOCKDOWN
end

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local raw = file.readAll()
    file.close()
    local ok, value = pcall(textutils.unserializeJSON, raw)
    return ok and type(value) == "table" and value or nil
end

local function saveJson(path, value)
    ensureParent(path)

    local ok, raw = pcall(textutils.serializeJSON, value)
    if not ok or type(raw) ~= "string" then return false, "serialize_failed" end

    local temp = path .. ".tmp"
    local backup = path .. ".bak"
    if fs.exists(temp) then pcall(fs.delete, temp) end

    local file = fs.open(temp, "w")
    if not file then return false, "temp_open_failed" end

    local wrote, writeError = pcall(function() file.write(raw) end)
    pcall(function() file.close() end)
    if not wrote then
        pcall(fs.delete, temp)
        return false, "write_failed:" .. tostring(writeError)
    end

    if fs.exists(backup) then pcall(fs.delete, backup) end
    if fs.exists(path) then
        local moved, moveError = pcall(fs.move, path, backup)
        if not moved then
            pcall(fs.delete, temp)
            return false, "backup_failed:" .. tostring(moveError)
        end
    end

    local committed, commitError = pcall(fs.move, temp, path)
    if not committed then
        if fs.exists(backup) and not fs.exists(path) then pcall(fs.move, backup, path) end
        return false, "commit_failed:" .. tostring(commitError)
    end

    if fs.exists(backup) then pcall(fs.delete, backup) end
    return true
end

local function isModem(name)
    if peripheral.hasType then
        local ok, result = pcall(peripheral.hasType, name, "modem")
        if ok then return result == true end
    end
    local ok, value = pcall(peripheral.getType, name)
    return ok and value == "modem"
end

local function openModems()
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

local function makePacket(messageType, payload, session, seq)
    local packet = {
        magic = MAGIC,
        version = PROTOCOL_VERSION,
        type = tostring(messageType or "message"),
        sender = os.getComputerID(),
        createdAt = nowMs(),
        payload = type(payload) == "table" and payload or {}
    }
    if session ~= nil then packet.session = tostring(session) end
    if seq ~= nil then packet.seq = math.floor(tonumber(seq) or 0) end
    return packet
end

local function validPacket(packet, sender)
    return type(packet) == "table"
        and packet.magic == MAGIC
        and packet.version == PROTOCOL_VERSION
        and packet.sender == sender
        and type(packet.type) == "string"
        and type(packet.payload) == "table"
end

local function send(controllerId, messageType, payload, session, seq)
    local ok, result = pcall(
        rednet.send,
        controllerId,
        makePacket(messageType, payload, session, seq),
        REDNET_PROTOCOL
    )
    return ok and result == true
end

local function seedRandom()
    local seed = nowMs() + os.getComputerID() * 7919
    pcall(math.randomseed, seed)
    math.random(); math.random()
end

seedRandom()

local function randomNonce()
    return string.format(
        "%d:%d:%06d:%06d",
        os.getComputerID(), nowMs(), math.random(0, 999999), math.random(0, 999999)
    )
end

local function pairingCode()
    return string.format("%06d", math.random(0, 999999))
end

local function defaultName()
    return os.getComputerLabel() or ("Sentry-" .. tostring(os.getComputerID()))
end

local function fuelSnapshot()
    local ok, fuel = pcall(turtle.getFuelLevel)
    if not ok then return nil, nil end
    local limit = nil
    local limitOk, value = pcall(turtle.getFuelLimit)
    if limitOk then limit = value end
    return fuel, limit
end

local function fuelState(fuel)
    if fuel == "unlimited" then return "UNLIMITED" end
    fuel = tonumber(fuel)
    if not fuel then return "UNKNOWN" end
    if fuel <= FUEL_CRITICAL then return "CRITICAL" end
    if fuel < FUEL_LOW then return "LOW" end
    return "OK"
end

local function autoRefuel()
    local fuel = select(1, fuelSnapshot())
    if fuel == "unlimited" then return true, "unlimited" end
    fuel = tonumber(fuel)
    if not fuel then return false, "fuel_unknown" end
    if fuel >= FUEL_LOW then return true, "not_needed" end

    local oldSlot = 1
    local selectedOk, selected = pcall(turtle.getSelectedSlot)
    if selectedOk and type(selected) == "number" then oldSlot = selected end

    local consumed = 0
    for _, slot in ipairs(FUEL_SLOTS) do
        if fuel >= FUEL_TARGET then break end
        pcall(turtle.select, slot)

        while fuel < FUEL_TARGET do
            local countOk, count = pcall(turtle.getItemCount, slot)
            if not countOk or tonumber(count) == nil or count <= 0 then break end

            local probeOk, isFuel = pcall(turtle.refuel, 0)
            if not probeOk or isFuel ~= true then break end

            local burnOk, burned = pcall(turtle.refuel, 1)
            if not burnOk or burned ~= true then break end
            consumed = consumed + 1

            local newFuel = select(1, fuelSnapshot())
            if newFuel == "unlimited" then
                fuel = FUEL_TARGET
                break
            end
            fuel = tonumber(newFuel) or fuel
        end
    end

    pcall(turtle.select, oldSlot)
    local after = select(1, fuelSnapshot())
    if after == "unlimited" then return true, "unlimited" end
    after = tonumber(after)
    if after and after > 0 then
        return true, consumed > 0 and ("refueled:" .. tostring(consumed)) or "fuel_present"
    end
    return false, "no_fuel_in_slots_1_4"
end

local function terminalColor()
    local ok, result = pcall(term.isColor)
    return ok and result == true
end

local function equippedItem(side)
    local fn
    if side == "left" then fn = turtle.getEquippedLeft else fn = turtle.getEquippedRight end
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn)
    if not ok or type(value) ~= "table" then return nil end
    return tostring(value.name or "")
end

local function hasDigTool()
    for _, side in ipairs({"left", "right"}) do
        local name = equippedItem(side) or ""
        if name:find("pickaxe", 1, true)
            or name:find("axe", 1, true)
            or name:find("shovel", 1, true)
            or name:find("hoe", 1, true)
        then
            return true
        end
    end
    return false
end

local function capabilitySnapshot(modemOpen)
    return {
        move = type(turtle.forward) == "function" and "available" or "unavailable",
        modem = modemOpen and "available" or "unavailable",
        melee = "unavailable",
        meleeReason = "polymania_runtime_no_target",
        dig = hasDigTool() and "tool_present_unverified" or "no_dig_tool",
        gps = "not_configured"
    }
end

local function capShort(cap)
    local move = cap.move == "available" and "+" or "-"
    local modem = cap.modem == "available" and "+" or "-"
    local melee = cap.melee == "available" and "+" or "-"
    local dig = cap.dig == "tool_present_unverified" and "?" or "-"
    return "M" .. move .. " R" .. modem .. " A" .. melee .. " D" .. dig
end

local function drawAgent(mode, state, controllerId, detail, capabilities)
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    term.setCursorPos(1, 1)
    term.setBackgroundColor(
        mode == MODE_SAFE and colors.green
        or mode == MODE_ARMED and colors.orange
        or colors.red
    )
    term.setTextColor(mode == MODE_SAFE and colors.black or colors.white)
    term.write(string.rep(" ", width))
    local title = " BASE DEFENSE AGENT "
    term.setCursorPos(math.max(1, math.floor((width - #title) / 2) + 1), 1)
    term.write(title)

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)

    local fuel, fuelLimit = fuelSnapshot()
    local fuelText = tostring(fuel or "?")
    if fuelLimit and fuelLimit ~= "unlimited" then fuelText = fuelText .. "/" .. tostring(fuelLimit) end
    fuelText = fuelText .. " " .. fuelState(fuel)

    local lines = {
        "Unit: " .. defaultName() .. " (#" .. tostring(os.getComputerID()) .. ")",
        "Controller: #" .. tostring(controllerId or "?"),
        "Mode: " .. tostring(mode),
        "State: " .. tostring(state),
        "Fuel: " .. fuelText,
        "Caps: " .. capShort(capabilities or {}),
        "Version: " .. VERSION,
        tostring(detail or "")
    }

    for index, text in ipairs(lines) do
        if index + 2 <= height then
            term.setCursorPos(2, index + 2)
            term.write(tostring(text):sub(1, math.max(1, width - 2)))
        end
    end
end

local function firstRun()
    local opened = openModems()
    if #opened == 0 then error("No modem found. Equip a wireless modem and retry.", 0) end

    term.clear(); term.setCursorPos(1, 1)
    print("BASE Defense Turtle Enrollment")
    print("Turtle ID: " .. tostring(os.getComputerID()))
    write("Controller computer ID: ")
    local controllerId = math.floor(tonumber(read()) or -1)
    if controllerId < 0 or controllerId == os.getComputerID() then
        error("Invalid controller computer ID", 0)
    end

    write("Unit name [" .. defaultName() .. "]: ")
    local name = read()
    if not name or name == "" then name = defaultName() end
    name = tostring(name):sub(1, 48)

    local code = pairingCode()
    local nonce = randomNonce()
    print("")
    print("PAIRING CODE: " .. code)
    print("Open BASE > Defense on controller.")
    print("Compare the code and press C to confirm.")
    print("This request expires on the controller if ignored.")

    local requestTimer = os.startTimer(0.1)
    while true do
        local event, a, b, c = os.pullEvent()
        if event == "timer" and a == requestTimer then
            openModems()
            send(controllerId, "enroll_request", {
                code = code,
                nonce = nonce,
                name = name,
                label = os.getComputerLabel() or "",
                agentVersion = VERSION,
                color = terminalColor()
            })
            requestTimer = os.startTimer(2)
        elseif event == "rednet_message" and c == REDNET_PROTOCOL then
            if a == controllerId and validPacket(b, a) and b.type == "enroll_accept" then
                local payload = b.payload
                if payload.nonce == nonce
                    and type(payload.session) == "string"
                    and payload.session ~= ""
                    and tonumber(payload.controllerId) == controllerId
                then
                    local config = {
                        schema = 1,
                        controllerId = controllerId,
                        name = name,
                        session = payload.session,
                        lastCommandSeq = 0,
                        lastModeRevision = math.max(0, math.floor(tonumber(payload.modeRevision) or 0))
                    }
                    local saved, saveError = saveJson(CONFIG_PATH, config)
                    if not saved then error("Enrollment save failed: " .. tostring(saveError), 0) end
                    print("Enrollment accepted.")
                    sleep(0.5)
                    return config
                end
            end
        elseif event == "key" and (a == keys.escape or a == keys.leftShift) then
            error("Enrollment cancelled", 0)
        end
    end
end

local function loadConfig()
    local value = readJson(CONFIG_PATH)
    if type(value) ~= "table"
        or value.schema ~= 1
        or type(value.controllerId) ~= "number"
        or type(value.session) ~= "string"
        or value.session == ""
    then
        return nil
    end
    value.controllerId = math.floor(value.controllerId)
    value.name = tostring(value.name or defaultName()):sub(1, 48)
    value.lastCommandSeq = math.max(0, math.floor(tonumber(value.lastCommandSeq) or 0))
    value.lastModeRevision = math.max(0, math.floor(tonumber(value.lastModeRevision) or 0))
    return value
end

local function persistRuntime(config)
    return saveJson(CONFIG_PATH, {
        schema = 1,
        controllerId = config.controllerId,
        name = config.name,
        session = config.session,
        lastCommandSeq = config.lastCommandSeq,
        lastModeRevision = config.lastModeRevision
    })
end

local function commandAllowed(mode, command, capabilities)
    local combat = command == "attack" or command == "attack_up" or command == "attack_down"
    if combat and capabilities.melee ~= "available" then
        return false, "melee_unavailable:" .. tostring(capabilities.meleeReason or "runtime")
    end
    if combat and mode == MODE_SAFE then return false, "safe_mode_combat_blocked" end

    return command == "attack"
        or command == "attack_up"
        or command == "attack_down"
        or command == "turn_left"
        or command == "turn_right"
        or command == "forward"
        or command == "back"
        or command == "up"
        or command == "down",
        "command_not_allowed"
end

local function performCommand(mode, command, capabilities)
    local allowed, reason = commandAllowed(mode, command, capabilities)
    if not allowed then return false, reason end

    if command == "forward" or command == "back" or command == "up" or command == "down" then
        autoRefuel()
    end

    local fn = ({
        attack = turtle.attack,
        attack_up = turtle.attackUp,
        attack_down = turtle.attackDown,
        turn_left = turtle.turnLeft,
        turn_right = turtle.turnRight,
        forward = turtle.forward,
        back = turtle.back,
        up = turtle.up,
        down = turtle.down
    })[command]

    if type(fn) ~= "function" then return false, "command_unavailable" end
    local called, result, detail = pcall(fn)
    if not called then return false, "runtime:" .. tostring(result) end
    if result == false then return false, tostring(detail or "operation_failed") end
    return true, tostring(detail or "ok")
end

local config = loadConfig() or firstRun()
local opened = openModems()
if #opened == 0 then error("No modem found. Equip a wireless modem and retry.", 0) end

autoRefuel()
local capabilities = capabilitySnapshot(#opened > 0)
local mode = MODE_SAFE
local state = "WAITING_CONTROLLER"
local lastControllerSeen = 0
local bootId = randomNonce()
local heartbeatTimer = os.startTimer(0.1)
local safetyTimer = os.startTimer(0.5)
local fuelTimer = os.startTimer(2)

drawAgent(mode, state, config.controllerId, "Fail-safe is active.", capabilities)

while true do
    local event, a, b, c = os.pullEvent()

    if event == "rednet_message" and c == REDNET_PROTOCOL then
        if a == config.controllerId and validPacket(b, a) and b.session == config.session then
            local payload = b.payload

            if b.type == "controller_heartbeat" then
                lastControllerSeen = nowMs()
                local revision = math.max(0, math.floor(tonumber(payload.modeRevision) or 0))
                local incomingMode = tostring(payload.mode or MODE_SAFE)

                if validMode(incomingMode) and revision >= config.lastModeRevision then
                    if revision > config.lastModeRevision then
                        config.lastModeRevision = revision
                        persistRuntime(config)
                    end
                    mode = incomingMode
                    state = "IDLE"
                end
                drawAgent(mode, state, config.controllerId, "Controller link OK.", capabilities)

            elseif b.type == "command" then
                lastControllerSeen = nowMs()
                local seq = math.max(0, math.floor(tonumber(payload.commandSeq) or 0))
                local requestId = tostring(payload.requestId or "")
                local command = tostring(payload.command or "")

                if seq <= config.lastCommandSeq then
                    send(config.controllerId, "command_result", {
                        requestId = requestId,
                        command = command,
                        ok = false,
                        detail = "stale_command"
                    }, config.session)
                else
                    config.lastCommandSeq = seq
                    persistRuntime(config)
                    state = "EXECUTING"
                    drawAgent(mode, state, config.controllerId, command, capabilities)

                    local ok, detail = performCommand(mode, command, capabilities)
                    state = ok and "IDLE" or "COMMAND_FAILED"
                    send(config.controllerId, "command_result", {
                        requestId = requestId,
                        command = command,
                        ok = ok,
                        detail = detail
                    }, config.session)
                    drawAgent(mode, state, config.controllerId, command .. ": " .. tostring(detail), capabilities)
                end

            elseif b.type == "revoke" then
                lastControllerSeen = nowMs()
                mode = MODE_SAFE
                state = "REVOKED"
                drawAgent(mode, state, config.controllerId, "Enrollment revoked by controller.", capabilities)
                pcall(fs.delete, CONFIG_PATH)
                sleep(1)
                return
            end
        end

    elseif event == "timer" and a == heartbeatTimer then
        opened = openModems()
        capabilities = capabilitySnapshot(#opened > 0)
        local fuel, fuelLimit = fuelSnapshot()
        send(config.controllerId, "heartbeat", {
            bootId = bootId,
            name = config.name,
            label = os.getComputerLabel() or "",
            mode = mode,
            state = state,
            fuel = fuel,
            fuelLimit = fuelLimit,
            fuelState = fuelState(fuel),
            fuelSlots = FUEL_SLOTS,
            capabilities = capabilities,
            agentVersion = VERSION,
            color = terminalColor()
        }, config.session)
        heartbeatTimer = os.startTimer(HEARTBEAT_SECONDS)

    elseif event == "timer" and a == fuelTimer then
        local fuel = select(1, fuelSnapshot())
        if fuelState(fuel) == "LOW" or fuelState(fuel) == "CRITICAL" then autoRefuel() end
        fuelTimer = os.startTimer(2)

    elseif event == "timer" and a == safetyTimer then
        if lastControllerSeen == 0 or nowMs() - lastControllerSeen > LINK_TIMEOUT_MS then
            if mode ~= MODE_SAFE or state ~= "LINK_LOST_SAFE" then
                mode = MODE_SAFE
                state = "LINK_LOST_SAFE"
                drawAgent(mode, state, config.controllerId, "No controller beacon. Combat disabled.", capabilities)
            end
        end
        safetyTimer = os.startTimer(0.5)

    elseif event == "peripheral" or event == "peripheral_detach" then
        opened = openModems()
        capabilities = capabilitySnapshot(#opened > 0)

    elseif event == "key" and a == keys.leftShift then
        mode = MODE_SAFE
        state = "STOPPED"
        drawAgent(mode, state, config.controllerId, "Agent stopped locally.", capabilities)
        return
    end
end
