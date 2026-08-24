local Common = require("lib.fleet.common")

local VERSION = "0.23.0-alpha.2"
local CONFIG_PATH = "/data/fleet_agent.json"
local STATUS_SECONDS = 2
local GPS_SECONDS = 3
local FUEL_SLOTS = {1, 2, 3, 4}
local FUEL_LOW = 256
local FUEL_TARGET = 1536
local RTB_RESERVE = 64

if type(turtle) ~= "table" then error("Fleet agent must run on a turtle", 0) end

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r"); if not f then return nil end
    local raw = f.readAll(); f.close()
    local ok, value = pcall(textutils.unserializeJSON, raw)
    return ok and type(value) == "table" and value or nil
end

local function writeJson(path, value)
    ensureParent(path)
    local ok, raw = pcall(textutils.serializeJSON, value)
    if not ok then return false, raw end
    local tmp = path .. ".tmp"
    if fs.exists(tmp) then pcall(fs.delete, tmp) end
    local f = fs.open(tmp, "w"); if not f then return false, "open_failed" end
    f.write(raw); f.close()
    if fs.exists(path) then pcall(fs.delete, path) end
    fs.move(tmp, path)
    return true
end

local function ask(prompt, default)
    write(prompt .. (default and (" [" .. tostring(default) .. "]") or "") .. ": ")
    local value = read()
    if value == "" and default ~= nil then return tostring(default) end
    return value
end

local function locate(timeout)
    if type(gps) ~= "table" or type(gps.locate) ~= "function" then return nil end
    local ok, x, y, z = pcall(gps.locate, timeout or 1.5, false)
    if ok and type(x) == "number" then return {x=x, y=y, z=z} end
    return nil
end

local HEADINGS = {N=0, E=1, S=2, W=3}
local HEADING_NAMES = {[0]="N", [1]="E", [2]="S", [3]="W"}

local function firstRun()
    Common.openModems()
    term.clear(); term.setCursorPos(1, 1)
    print("BASE Fleet Agent Setup")
    print("Computer ID: " .. os.getComputerID())
    local fleetId = ask("Fleet ID")
    if fleetId == "" then error("Fleet ID cannot be empty", 0) end
    local key = ask("Fleet key")
    if #key < 16 then error("Fleet key must be at least 16 characters", 0) end
    local name = ask("Unit name", os.getComputerLabel() or ("Unit-" .. os.getComputerID()))
    local role = string.upper(ask("Role ASSAULT/RELAY", "ASSAULT"))
    if role ~= "RELAY" then role = "ASSAULT" end
    local headingName = string.upper(ask("Facing N/E/S/W", "N"))
    local heading = HEADINGS[headingName] or 0
    local home = locate(2)
    if home then
        print(string.format("GPS home: %.1f %.1f %.1f", home.x, home.y, home.z))
    else
        print("GPS unavailable: home not set.")
    end
    local cfg = {
        schema=1, fleetId=fleetId, key=key, name=name, role=role,
        relay=true, heading=heading, home=home, operatorSeq={}
    }
    writeJson(CONFIG_PATH, cfg)
    sleep(0.5)
    return cfg
end

local function normalizeConfig(cfg)
    if type(cfg) ~= "table" or cfg.schema ~= 1 then return nil end
    if type(cfg.fleetId) ~= "string" or cfg.fleetId == "" then return nil end
    if type(cfg.key) ~= "string" or #cfg.key < 16 then return nil end
    cfg.name = tostring(cfg.name or ("Unit-" .. os.getComputerID())):sub(1, 32)
    cfg.role = cfg.role == "RELAY" and "RELAY" or "ASSAULT"
    cfg.relay = cfg.relay ~= false
    cfg.heading = math.floor(tonumber(cfg.heading) or 0) % 4
    cfg.operatorSeq = type(cfg.operatorSeq) == "table" and cfg.operatorSeq or {}
    return cfg
end

local config = normalizeConfig(readJson(CONFIG_PATH)) or firstRun()
local mesh = {bootId=Common.randomHex(12), seq=0}
local seen = Common.newSeenCache()
local peers = {}
local state = "IDLE"
local position = locate(1.5)
local rtbActive = false
local rtbReason = ""

local function saveConfig()
    return writeJson(CONFIG_PATH, config)
end

local function fuelSnapshot()
    local ok, fuel = pcall(turtle.getFuelLevel)
    if not ok then return nil, nil end
    local limit
    local ok2, value = pcall(turtle.getFuelLimit)
    if ok2 then limit = value end
    return fuel, limit
end

local function autoRefuel()
    local fuel = select(1, fuelSnapshot())
    if fuel == "unlimited" then return true end
    fuel = tonumber(fuel); if not fuel then return false end
    if fuel >= FUEL_LOW then return true end
    local selected = 1
    local okSel, old = pcall(turtle.getSelectedSlot)
    if okSel and type(old) == "number" then selected = old end
    for _, slot in ipairs(FUEL_SLOTS) do
        if fuel >= FUEL_TARGET then break end
        pcall(turtle.select, slot)
        while fuel < FUEL_TARGET do
            local okCount, count = pcall(turtle.getItemCount, slot)
            if not okCount or not count or count <= 0 then break end
            local okProbe, usable = pcall(turtle.refuel, 0)
            if not okProbe or usable ~= true then break end
            local okBurn, burned = pcall(turtle.refuel, 1)
            if not okBurn or burned ~= true then break end
            local nextFuel = select(1, fuelSnapshot())
            if nextFuel == "unlimited" then fuel = FUEL_TARGET break end
            fuel = tonumber(nextFuel) or fuel
        end
    end
    pcall(turtle.select, selected)
    return true
end

local function capabilitySnapshot()
    local left, right
    if type(turtle.getEquippedLeft) == "function" then pcall(function() left = turtle.getEquippedLeft() end) end
    if type(turtle.getEquippedRight) == "function" then pcall(function() right = turtle.getEquippedRight() end) end
    local text = string.lower(textutils.serialize({left=left,right=right}) or "")
    return {
        move = true,
        modem = #Common.openModems() > 0,
        melee = text:find("sword", 1, true) ~= nil,
        dig = text:find("pickaxe", 1, true) ~= nil,
        gps = position ~= nil,
        relay = config.relay == true
    }
end

local function send(messageType, target, payload, ttl)
    local packet, err = Common.newPacket(config, mesh, messageType, target, payload, ttl)
    if not packet then return false, err end
    Common.markSeen(seen, Common.packetId(packet))
    return Common.broadcast(packet)
end

local function maybeRelay(packet)
    if not config.relay or packet.ttl <= 0 then return end
    local forwarded = Common.forwardPacket(packet, config.key)
    if forwarded then Common.broadcast(forwarded) end
end

local function updatePosition()
    local pos = locate(1.2)
    if pos then position = pos end
    return position
end

local function targetMatches(target)
    if target == nil or target == "*" then return true end
    if tonumber(target) == os.getComputerID() then return true end
    if tostring(target) == config.role then return true end
    return false
end

local function turnLeft()
    local ok, err = turtle.turnLeft()
    if ok then config.heading = (config.heading + 3) % 4; saveConfig() end
    return ok, err
end

local function turnRight()
    local ok, err = turtle.turnRight()
    if ok then config.heading = (config.heading + 1) % 4; saveConfig() end
    return ok, err
end

local function face(desired)
    desired = math.floor(desired) % 4
    local diff = (desired - config.heading) % 4
    if diff == 0 then return true end
    if diff == 1 then return turnRight() end
    if diff == 3 then return turnLeft() end
    local ok, err = turnRight(); if not ok then return false, err end
    return turnRight()
end

local function checkLowFuel()
    if config.role == "RELAY" or not config.home or not position then return false end
    local fuel = select(1, fuelSnapshot())
    if fuel == "unlimited" then return false end
    fuel = tonumber(fuel); if not fuel then return false end
    local need = Common.manhattan(position, config.home)
    if not need then return false end
    if fuel <= need + RTB_RESERVE then
        rtbActive = true
        rtbReason = "LOW_FUEL"
        state = "RTB"
        return true
    end
    return false
end

local function rtbStep()
    if not rtbActive then return end
    if not config.home then state = "RTB_NO_HOME"; rtbActive = false; return end
    updatePosition()
    if not position then state = "RTB_NO_GPS"; rtbActive = false; return end
    local hx, hy, hz = math.floor(config.home.x + 0.5), math.floor(config.home.y + 0.5), math.floor(config.home.z + 0.5)
    local x, y, z = math.floor(position.x + 0.5), math.floor(position.y + 0.5), math.floor(position.z + 0.5)
    if x == hx and y == hy and z == hz then state = "HOME"; rtbActive = false; return end
    local ok, err
    if x < hx then ok, err = face(1); if ok then ok, err = turtle.forward() end
    elseif x > hx then ok, err = face(3); if ok then ok, err = turtle.forward() end
    elseif z < hz then ok, err = face(2); if ok then ok, err = turtle.forward() end
    elseif z > hz then ok, err = face(0); if ok then ok, err = turtle.forward() end
    elseif y < hy then ok, err = turtle.up()
    else ok, err = turtle.down() end
    if not ok then state = "RTB_BLOCKED:" .. tostring(err or "blocked"); rtbActive = false end
    updatePosition()
end

local function perform(command)
    if rtbActive and command ~= "hold" and command ~= "set_home" then return false, "rtb_active" end
    autoRefuel()
    local ok, err
    if command == "forward" then ok, err = turtle.forward()
    elseif command == "back" then ok, err = turtle.back()
    elseif command == "up" then ok, err = turtle.up()
    elseif command == "down" then ok, err = turtle.down()
    elseif command == "turn_left" then return turnLeft()
    elseif command == "turn_right" then return turnRight()
    elseif command == "attack" then ok, err = turtle.attack()
    elseif command == "attack_up" then ok, err = turtle.attackUp()
    elseif command == "attack_down" then ok, err = turtle.attackDown()
    elseif command == "rtb" then
        if not config.home then return false, "home_not_set" end
        rtbActive = true; rtbReason = "OPERATOR"; state = "RTB"; return true, "rtb_started"
    elseif command == "hold" then rtbActive = false; state = "HOLD"; return true, "hold"
    elseif command == "set_home" then
        local pos = updatePosition(); if not pos then return false, "gps_unavailable" end
        config.home = {x=pos.x, y=pos.y, z=pos.z}; saveConfig(); return true, "home_set"
    else return false, "unknown_command" end
    if ok then updatePosition(); checkLowFuel() end
    return ok == true, tostring(err or (ok and "ok" or "failed"))
end

local function acceptCommand(packet)
    if not targetMatches(packet.target) then return end
    local payload = packet.payload
    local operator = tostring(payload.operator or packet.origin)
    local commandSeq = math.floor(tonumber(payload.commandSeq) or 0)
    local last = math.floor(tonumber(config.operatorSeq[operator]) or 0)
    if commandSeq <= last then return end
    config.operatorSeq[operator] = commandSeq
    saveConfig()
    local command = tostring(payload.command or "")
    state = "EXEC:" .. command
    local ok, detail = perform(command)
    state = ok and (rtbActive and "RTB" or "IDLE") or ("FAILED:" .. tostring(detail))
    send("result", packet.origin, {
        requestId=payload.requestId, command=command, ok=ok, detail=detail,
        unit=os.getComputerID(), state=state
    })
end

local function handlePacket(sender, packet, protocol)
    if protocol ~= Common.REDNET_PROTOCOL then return end
    local valid = Common.verify(packet, config.key, config.fleetId)
    if not valid then return end
    local id = Common.packetId(packet)
    if Common.seen(seen, id) then return end
    Common.markSeen(seen, id)
    if packet.type == "command" then
        acceptCommand(packet)
    elseif packet.type == "status" and packet.origin ~= os.getComputerID() then
        peers[packet.origin] = {seen=Common.nowMs(), pos=packet.payload.pos, role=packet.payload.role}
    end
    maybeRelay(packet)
end

local function nearestPeer()
    if not position then return nil end
    local bestId, bestDist
    for id, peer in pairs(peers) do
        if Common.nowMs() - (peer.seen or 0) < 10000 and peer.pos then
            local dist = Common.distance(position, peer.pos)
            if dist and (not bestDist or dist < bestDist) then bestId, bestDist = id, dist end
        end
    end
    return bestId, bestDist
end

local function draw()
    local w = term.getSize()
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
    term.setCursorPos(1,1); term.setBackgroundColor(config.role == "RELAY" and colors.blue or colors.red)
    term.write(string.rep(" ", w)); term.setCursorPos(2,1); term.write("BASE FLEET " .. config.role)
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
    local fuel = select(1, fuelSnapshot())
    local caps = capabilitySnapshot()
    local pos = position and string.format("%.0f %.0f %.0f", position.x, position.y, position.z) or "NO GPS"
    local nearId, nearDist = nearestPeer()
    local lines = {
        config.name .. " #" .. os.getComputerID(),
        "State: " .. state,
        "Pos: " .. pos .. " H:" .. HEADING_NAMES[config.heading],
        "Fuel: " .. tostring(fuel or "?"),
        string.format("M%s A%s D%s GPS%s RELAY%s", caps.move and "+" or "-", caps.melee and "+" or "-", caps.dig and "+" or "-", caps.gps and "+" or "-", caps.relay and "+" or "-"),
        nearId and string.format("Nearest #%s %.1fm", nearId, nearDist) or "Nearest: none",
        config.home and string.format("Home: %.0f %.0f %.0f", config.home.x, config.home.y, config.home.z) or "Home: not set",
        "Fleet: " .. config.fleetId,
        "v" .. VERSION .. "  SHIFT stop"
    }
    for i, text in ipairs(lines) do term.setCursorPos(1, i+2); term.write(tostring(text):sub(1,w)) end
end

if #Common.openModems() == 0 then error("No wireless modem found", 0) end
autoRefuel(); updatePosition(); checkLowFuel(); draw()
local statusTimer = os.startTimer(0.2)
local gpsTimer = os.startTimer(GPS_SECONDS)
local rtbTimer = os.startTimer(0.5)

while true do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" then handlePacket(a, b, c)
    elseif event == "timer" and a == statusTimer then
        autoRefuel(); checkLowFuel()
        local fuel, fuelLimit = fuelSnapshot()
        send("status", "*", {
            unit=os.getComputerID(), name=config.name, role=config.role, state=state,
            fuel=fuel, fuelLimit=fuelLimit, pos=position, heading=HEADING_NAMES[config.heading],
            home=config.home, capabilities=capabilitySnapshot(), rtb=rtbActive, rtbReason=rtbReason,
            version=VERSION
        })
        statusTimer = os.startTimer(STATUS_SECONDS); draw()
    elseif event == "timer" and a == gpsTimer then
        updatePosition(); checkLowFuel(); gpsTimer = os.startTimer(GPS_SECONDS); draw()
    elseif event == "timer" and a == rtbTimer then
        rtbStep(); rtbTimer = os.startTimer(0.5); draw()
    elseif event == "peripheral" or event == "peripheral_detach" then Common.openModems(); draw()
    elseif event == "key" and a == keys.leftShift then state = "STOPPED"; draw(); return end
end
