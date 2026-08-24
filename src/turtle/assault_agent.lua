local Common = require("lib.fleet.common")

local VERSION = "0.23.0-alpha.3"
local CONFIG_PATH = "/data/fleet_agent.json"
local FORCE_UPDATE_PATH = "/data/fleet_force_update"
local STATUS_SECONDS = 1
local GPS_PROBE_SECONDS = 15
local GPS_TIMEOUT = 0.25
local LINK_RECOVERY_SECONDS = 2
local LINK_REBOOT_MS = 180000
local COMMAND_MAX_AGE_MS = 12000
local COMMAND_FUTURE_SKEW_MS = 5000
local FUEL_SLOTS = {1, 2, 3, 4}
local FUEL_LOW = 256
local FUEL_TARGET = 1536
local RTB_RESERVE = 64

if type(turtle) ~= "table" then error("Fleet agent must run on a turtle", 0) end

local HEADINGS = {N=0, E=1, S=2, W=3}
local HEADING_NAMES = {[0]="N", [1]="E", [2]="S", [3]="W"}
local DIR = {
    [0] = {x=0, z=-1},
    [1] = {x=1, z=0},
    [2] = {x=0, z=1},
    [3] = {x=-1, z=0}
}

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
    local wrote, err = pcall(function() f.write(raw) end)
    pcall(function() f.close() end)
    if not wrote then pcall(fs.delete, tmp); return false, tostring(err) end
    if fs.exists(path) then
        local bak = path .. ".bak"
        if fs.exists(bak) then pcall(fs.delete, bak) end
        local okMove = pcall(fs.move, path, bak)
        if not okMove then pcall(fs.delete, tmp); return false, "backup_failed" end
        local committed = pcall(fs.move, tmp, path)
        if not committed then
            if fs.exists(bak) and not fs.exists(path) then pcall(fs.move, bak, path) end
            return false, "commit_failed"
        end
        if fs.exists(bak) then pcall(fs.delete, bak) end
    else
        local committed = pcall(fs.move, tmp, path)
        if not committed then return false, "commit_failed" end
    end
    return true
end

local function ask(prompt, default)
    write(prompt .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
    local value = read()
    if value == "" and default ~= nil then return tostring(default) end
    return value
end

local function locate(timeout)
    if type(gps) ~= "table" or type(gps.locate) ~= "function" then return nil end
    local ok, x, y, z = pcall(gps.locate, timeout or GPS_TIMEOUT, false)
    if ok and type(x) == "number" then return {x=x, y=y, z=z} end
    return nil
end

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
    local navX = tonumber(ask("Local X", "0")) or 0
    local navY = tonumber(ask("Local Y", "0")) or 0
    local navZ = tonumber(ask("Local Z", "0")) or 0
    local cfg = {
        schema=2, fleetId=fleetId, key=key, name=name, role=role,
        relay=true, heading=heading,
        nav={x=navX, y=navY, z=navZ, frame=fleetId},
        homeNav=nil
    }
    writeJson(CONFIG_PATH, cfg)
    sleep(0.25)
    return cfg
end

local function normalizeConfig(cfg)
    if type(cfg) ~= "table" or (cfg.schema ~= 1 and cfg.schema ~= 2) then return nil end
    if type(cfg.fleetId) ~= "string" or cfg.fleetId == "" then return nil end
    if type(cfg.key) ~= "string" or #cfg.key < 16 then return nil end
    cfg.schema = 2
    cfg.name = tostring(cfg.name or ("Unit-" .. os.getComputerID())):sub(1, 32)
    cfg.role = cfg.role == "RELAY" and "RELAY" or "ASSAULT"
    cfg.relay = cfg.relay ~= false
    cfg.heading = math.floor(tonumber(cfg.heading) or 0) % 4
    if type(cfg.nav) ~= "table" then
        cfg.nav = {x=0, y=0, z=0, frame=cfg.fleetId}
    end
    cfg.nav.x = tonumber(cfg.nav.x) or 0
    cfg.nav.y = tonumber(cfg.nav.y) or 0
    cfg.nav.z = tonumber(cfg.nav.z) or 0
    cfg.nav.frame = tostring(cfg.nav.frame or cfg.fleetId)
    if type(cfg.homeNav) == "table" then
        cfg.homeNav = {
            x=tonumber(cfg.homeNav.x) or 0,
            y=tonumber(cfg.homeNav.y) or 0,
            z=tonumber(cfg.homeNav.z) or 0,
            frame=tostring(cfg.homeNav.frame or cfg.nav.frame)
        }
    else
        cfg.homeNav = nil
    end
    cfg.operatorSeq = nil
    return cfg
end

local config = normalizeConfig(readJson(CONFIG_PATH)) or firstRun()
local mesh = {bootId=Common.randomHex(12), seq=0}
local seen = Common.newSeenCache()
local peers = {}
local operatorSeq = {}
local resultCache = {}
local state = "IDLE"
local linkState = "SEARCHING"
local gpsPosition = locate(GPS_TIMEOUT)
local navPosition = {x=config.nav.x, y=config.nav.y, z=config.nav.z, frame=config.nav.frame}
local rtbActive = false
local rtbReason = ""
local lastValidMesh = 0
local everLinked = false
local poseDirty = false

local function saveConfig()
    config.nav = {x=navPosition.x, y=navPosition.y, z=navPosition.z, frame=navPosition.frame}
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

local function equipped(side)
    local fn = side == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

local function itemName(item)
    return string.lower(tostring(type(item) == "table" and item.name or ""))
end

local function findToolSide()
    if peripheral.hasType then
        local okL, modemL = pcall(peripheral.hasType, "left", "modem")
        if okL and modemL then return "right" end
        local okR, modemR = pcall(peripheral.hasType, "right", "modem")
        if okR and modemR then return "left" end
    end
    local left, right = itemName(equipped("left")), itemName(equipped("right"))
    if left:find("modem", 1, true) then return "right" end
    if right:find("modem", 1, true) then return "left" end
    return "left"
end

local function matchesTool(name, kind)
    name = string.lower(tostring(name or ""))
    if kind == "sword" then return name:find("sword", 1, true) ~= nil end
    if kind == "pickaxe" then return name:find("pickaxe", 1, true) ~= nil end
    return false
end

local function inventoryHas(kind)
    if matchesTool(itemName(equipped("left")), kind) or matchesTool(itemName(equipped("right")), kind) then return true end
    for slot = 5, 16 do
        local ok, detail = pcall(turtle.getItemDetail, slot)
        if ok and type(detail) == "table" and matchesTool(detail.name, kind) then return true end
    end
    return false
end

local function ensureTool(kind)
    local side = findToolSide()
    if matchesTool(itemName(equipped(side)), kind) then return true end
    local oldSlot = 1
    local okSel, selected = pcall(turtle.getSelectedSlot)
    if okSel and type(selected) == "number" then oldSlot = selected end
    for slot = 5, 16 do
        local ok, detail = pcall(turtle.getItemDetail, slot)
        if ok and type(detail) == "table" and matchesTool(detail.name, kind) then
            turtle.select(slot)
            local equipFn = side == "left" and turtle.equipLeft or turtle.equipRight
            local equippedOk, err = equipFn()
            turtle.select(oldSlot)
            if equippedOk then return true end
            return false, tostring(err or "equip_failed")
        end
    end
    turtle.select(oldSlot)
    return false, kind .. "_missing"
end

local function capabilitySnapshot()
    return {
        move = type(turtle.forward) == "function",
        modem = #Common.openModems() > 0,
        melee = inventoryHas("sword"),
        dig = inventoryHas("pickaxe"),
        gps = gpsPosition ~= nil,
        nav = true,
        relay = config.relay == true,
        autoUpdate = fs.exists("/fleet_update.lua")
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

local function targetMatches(target)
    if target == nil or target == "*" then return true end
    if tonumber(target) == os.getComputerID() then return true end
    if tostring(target) == config.role then return true end
    return false
end

local function markMove(command)
    local d = DIR[config.heading]
    if command == "forward" then
        navPosition.x = navPosition.x + d.x; navPosition.z = navPosition.z + d.z
    elseif command == "back" then
        navPosition.x = navPosition.x - d.x; navPosition.z = navPosition.z - d.z
    elseif command == "up" then
        navPosition.y = navPosition.y + 1
    elseif command == "down" then
        navPosition.y = navPosition.y - 1
    end
    poseDirty = true
end

local function turnLeft()
    local ok, err = turtle.turnLeft()
    if ok then config.heading = (config.heading + 3) % 4; poseDirty = true end
    return ok, err
end

local function turnRight()
    local ok, err = turtle.turnRight()
    if ok then config.heading = (config.heading + 1) % 4; poseDirty = true end
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

local function move(command)
    local fn = command == "forward" and turtle.forward
        or command == "back" and turtle.back
        or command == "up" and turtle.up
        or command == "down" and turtle.down
    if not fn then return false, "bad_move" end
    local ok, err = fn()
    if ok then markMove(command) end
    return ok, err
end

local function distanceHome()
    if not config.homeNav or config.homeNav.frame ~= navPosition.frame then return nil end
    return math.abs(navPosition.x - config.homeNav.x)
        + math.abs(navPosition.y - config.homeNav.y)
        + math.abs(navPosition.z - config.homeNav.z)
end

local function checkLowFuel()
    if config.role == "RELAY" or not config.homeNav then return false end
    local fuel = select(1, fuelSnapshot())
    if fuel == "unlimited" then return false end
    fuel = tonumber(fuel); if not fuel then return false end
    local need = distanceHome(); if not need then return false end
    if fuel <= need + RTB_RESERVE then
        rtbActive = true; rtbReason = "LOW_FUEL"; state = "RTB"
        return true
    end
    return false
end

local function rtbStep()
    if not rtbActive then return end
    local h = config.homeNav
    if not h or h.frame ~= navPosition.frame then state = "RTB_NO_HOME"; rtbActive = false; return end
    local x, y, z = math.floor(navPosition.x + 0.5), math.floor(navPosition.y + 0.5), math.floor(navPosition.z + 0.5)
    local hx, hy, hz = math.floor(h.x + 0.5), math.floor(h.y + 0.5), math.floor(h.z + 0.5)
    if x == hx and y == hy and z == hz then state = "HOME"; rtbActive = false; return end
    local ok, err
    if x < hx then ok, err = face(1); if ok then ok, err = move("forward") end
    elseif x > hx then ok, err = face(3); if ok then ok, err = move("forward") end
    elseif z < hz then ok, err = face(2); if ok then ok, err = move("forward") end
    elseif z > hz then ok, err = face(0); if ok then ok, err = move("forward") end
    elseif y < hy then ok, err = move("up")
    else ok, err = move("down") end
    if not ok then state = "RTB_BLOCKED:" .. tostring(err or "blocked"); rtbActive = false end
end

local function perform(command, args)
    args = type(args) == "table" and args or {}
    if rtbActive and command ~= "hold" and command ~= "set_home" and command ~= "update" then
        return false, "rtb_active"
    end
    autoRefuel()
    local ok, err
    if command == "forward" or command == "back" or command == "up" or command == "down" then
        ok, err = move(command)
    elseif command == "turn_left" then return turnLeft()
    elseif command == "turn_right" then return turnRight()
    elseif command == "attack" or command == "attack_up" or command == "attack_down" then
        local toolOk, toolErr = ensureTool("sword"); if not toolOk then return false, toolErr end
        local fn = command == "attack" and turtle.attack or command == "attack_up" and turtle.attackUp or turtle.attackDown
        ok, err = fn()
    elseif command == "dig" or command == "dig_up" or command == "dig_down" then
        local toolOk, toolErr = ensureTool("pickaxe"); if not toolOk then return false, toolErr end
        local fn = command == "dig" and turtle.dig or command == "dig_up" and turtle.digUp or turtle.digDown
        ok, err = fn()
    elseif command == "breach" then
        local detected = false
        pcall(function() detected = turtle.detect() end)
        if detected then
            local toolOk, toolErr = ensureTool("pickaxe"); if not toolOk then return false, toolErr end
            local dug, digErr = turtle.dig(); if not dug then return false, tostring(digErr or "dig_failed") end
        else
            local toolOk = ensureTool("sword")
            if toolOk then pcall(turtle.attack) end
        end
        ok, err = move("forward")
    elseif command == "rtb" then
        if not config.homeNav then return false, "home_not_set" end
        rtbActive = true; rtbReason = "OPERATOR"; state = "RTB"; return true, "rtb_started"
    elseif command == "hold" then
        rtbActive = false; state = "HOLD"; return true, "hold"
    elseif command == "set_home" then
        config.homeNav = {x=navPosition.x, y=navPosition.y, z=navPosition.z, frame=navPosition.frame}
        saveConfig(); poseDirty = false
        return true, "home_set"
    elseif command == "set_pose" then
        local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
        local heading = HEADINGS[string.upper(tostring(args.heading or ""))]
        if not x or not y or not z or heading == nil then return false, "bad_pose" end
        navPosition = {x=x, y=y, z=z, frame=tostring(args.frame or config.fleetId)}
        config.heading = heading; poseDirty = true; saveConfig(); poseDirty = false
        return true, "pose_set"
    elseif command == "update" then
        local f = fs.open(FORCE_UPDATE_PATH, "w")
        if f then f.write(VERSION); f.close() end
        return true, "update_reboot_scheduled"
    else
        return false, "unknown_command"
    end
    if ok then checkLowFuel() end
    return ok == true, tostring(err or (ok and "ok" or "failed"))
end

local function sendResult(packet, payload, ok, detail)
    send("result", packet.origin, {
        requestId=payload.requestId, command=payload.command, ok=ok, detail=detail,
        unit=os.getComputerID(), state=state
    })
end

local function acceptCommand(packet)
    if not targetMatches(packet.target) then return end
    local payload = packet.payload
    local issuedAt = tonumber(payload.issuedAt) or 0
    local now = Common.nowMs()
    if issuedAt <= 0 or now - issuedAt > COMMAND_MAX_AGE_MS or issuedAt - now > COMMAND_FUTURE_SKEW_MS then return end
    local operator = tostring(payload.operator or packet.origin)
    local operatorBoot = tostring(payload.operatorBoot or packet.originBoot)
    local key = operator .. ":" .. operatorBoot
    local commandSeq = math.floor(tonumber(payload.commandSeq) or 0)
    if commandSeq < 1 then return end
    local last = math.floor(tonumber(operatorSeq[key]) or 0)
    if commandSeq < last then return end
    if commandSeq == last then
        local cached = resultCache[key]
        if cached and cached.seq == commandSeq and cached.requestId == payload.requestId then
            sendResult(packet, payload, cached.ok, cached.detail)
        end
        return
    end
    operatorSeq[key] = commandSeq
    local command = tostring(payload.command or "")
    state = "EXEC:" .. command
    local ok, detail = perform(command, payload.args)
    state = ok and (rtbActive and "RTB" or "IDLE") or ("FAILED:" .. tostring(detail))
    resultCache[key] = {seq=commandSeq, requestId=payload.requestId, ok=ok, detail=detail}
    sendResult(packet, payload, ok, detail)
    if command == "update" and ok then
        sleep(0.25)
        os.reboot()
    end
end

local function handlePacket(sender, packet, protocol)
    if protocol ~= Common.REDNET_PROTOCOL then return end
    local valid = Common.verify(packet, config.key, config.fleetId)
    if not valid then return end
    lastValidMesh = Common.nowMs(); everLinked = true; linkState = "ONLINE"
    local id = Common.packetId(packet)
    if Common.seen(seen, id) then return end
    Common.markSeen(seen, id)
    if packet.type == "command" then
        acceptCommand(packet)
    elseif packet.type == "status" and packet.origin ~= os.getComputerID() then
        peers[packet.origin] = {
            seen=Common.nowMs(), navPos=packet.payload.navPos, navFrame=packet.payload.navFrame,
            gpsPos=packet.payload.gpsPos, role=packet.payload.role
        }
    end
    maybeRelay(packet)
end

local function nearestPeer()
    local bestId, bestDist
    for id, peer in pairs(peers) do
        if Common.nowMs() - (peer.seen or 0) < 10000 and peer.navPos and peer.navFrame == navPosition.frame then
            local dist = Common.distance(navPosition, peer.navPos)
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
    local nearId, nearDist = nearestPeer()
    local lines = {
        config.name .. " #" .. os.getComputerID(),
        "State: " .. state .. " Link:" .. linkState,
        string.format("NAV %.0f %.0f %.0f H:%s", navPosition.x, navPosition.y, navPosition.z, HEADING_NAMES[config.heading]),
        gpsPosition and string.format("GPS %.0f %.0f %.0f", gpsPosition.x, gpsPosition.y, gpsPosition.z) or "GPS: no anchor",
        "Fuel: " .. tostring(fuel or "?"),
        string.format("A%s D%s NAV+ R%s U%s", caps.melee and "+" or "-", caps.dig and "+" or "-", caps.relay and "+" or "-", caps.autoUpdate and "+" or "-"),
        nearId and string.format("Nearest #%s %.1fm", nearId, nearDist) or "Nearest: none/shared frame",
        config.homeNav and string.format("Home %.0f %.0f %.0f", config.homeNav.x, config.homeNav.y, config.homeNav.z) or "Home: not set",
        "v" .. VERSION .. "  Fleet:" .. config.fleetId
    }
    for i, text in ipairs(lines) do
        if i + 2 <= select(2, term.getSize()) then term.setCursorPos(1, i+2); term.write(tostring(text):sub(1,w)) end
    end
end

if #Common.openModems() == 0 then error("No wireless modem found", 0) end
autoRefuel(); checkLowFuel(); draw()
local statusTimer = os.startTimer(0.1 + math.random() * 0.4)
local gpsTimer = os.startTimer(GPS_PROBE_SECONDS)
local rtbTimer = os.startTimer(0.35)
local recoveryTimer = os.startTimer(LINK_RECOVERY_SECONDS)
local checkpointTimer = os.startTimer(2)

while true do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" then
        handlePacket(a, b, c)
    elseif event == "timer" and a == statusTimer then
        autoRefuel(); checkLowFuel()
        local fuel, fuelLimit = fuelSnapshot()
        send("status", "*", {
            unit=os.getComputerID(), name=config.name, role=config.role, state=state,
            linkState=linkState, fuel=fuel, fuelLimit=fuelLimit,
            navPos={x=navPosition.x,y=navPosition.y,z=navPosition.z}, navFrame=navPosition.frame,
            gpsPos=gpsPosition, heading=HEADING_NAMES[config.heading], homeNav=config.homeNav,
            capabilities=capabilitySnapshot(), rtb=rtbActive, rtbReason=rtbReason,
            version=VERSION
        })
        statusTimer = os.startTimer(STATUS_SECONDS + math.random() * 0.35); draw()
    elseif event == "timer" and a == gpsTimer then
        local pos = locate(GPS_TIMEOUT); if pos then gpsPosition = pos end
        gpsTimer = os.startTimer(GPS_PROBE_SECONDS); draw()
    elseif event == "timer" and a == rtbTimer then
        rtbStep(); rtbTimer = os.startTimer(0.35); draw()
    elseif event == "timer" and a == recoveryTimer then
        Common.openModems()
        if everLinked and Common.nowMs() - lastValidMesh > LINK_REBOOT_MS then
            linkState = "REBOOT_RECOVERY"; draw(); sleep(0.2); os.reboot()
        elseif lastValidMesh == 0 or Common.nowMs() - lastValidMesh > 10000 then
            linkState = "SEARCHING"
        else
            linkState = "ONLINE"
        end
        recoveryTimer = os.startTimer(LINK_RECOVERY_SECONDS)
    elseif event == "timer" and a == checkpointTimer then
        if poseDirty then saveConfig(); poseDirty = false end
        checkpointTimer = os.startTimer(2)
    elseif event == "peripheral" or event == "peripheral_detach" then
        Common.openModems(); draw()
    elseif event == "key" and a == keys.leftShift then
        state = "STOPPED"; if poseDirty then saveConfig() end; draw(); return
    end
end
