local Common = require("lib.fleet.common")

local VERSION = "0.23.0-alpha.3"
local CONFIG_PATH = "/data/fleet_operator.json"
local UNIT_STALE_MS = 8000
local RETRY_TIMER_SECONDS = 0.15
local RETRY_DELAYS_MS = {180, 420, 850, 1500, 2400}
local PENDING_LIMIT = 8

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
    if not ok then return false end
    local tmp = path .. ".tmp"
    if fs.exists(tmp) then pcall(fs.delete, tmp) end
    local f = fs.open(tmp, "w"); if not f then return false end
    f.write(raw); f.close()
    if fs.exists(path) then pcall(fs.delete, path) end
    fs.move(tmp, path)
    return true
end

local function ask(prompt, default)
    write(prompt .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
    local value = read()
    if value == "" and default ~= nil then return tostring(default) end
    return value
end

local function collectFleetKey()
    term.clear(); term.setCursorPos(1,1)
    print("Fleet key entropy setup")
    print("Press varied keys 24 times.")
    local material = tostring(os.getComputerID()) .. ":" .. tostring(Common.nowMs())
    for _ = 1, 24 do
        local _, code = os.pullEvent("key")
        material = material .. ":" .. tostring(code) .. ":" .. tostring(Common.nowMs())
        write(".")
    end
    print("")
    local key, err = Common.sha1(material)
    if not key then error("Key generation failed: " .. tostring(err), 0) end
    return key
end

local function firstRun()
    Common.openModems()
    term.clear(); term.setCursorPos(1,1)
    print("BASE Fleet Pocket Setup")
    print("Pocket ID: " .. os.getComputerID())
    local fleetId = ask("Fleet ID", "F" .. tostring(os.getComputerID()))
    local key = collectFleetKey()
    print("Generated fleet key:")
    print(key)
    print("Enter this exact key on each fleet turtle.")
    print("Press ENTER when recorded.")
    read()
    local cfg = {schema=2, fleetId=fleetId, key=key, relay=true}
    writeJson(CONFIG_PATH, cfg)
    return cfg
end

local function normalize(cfg)
    if type(cfg) ~= "table" or (cfg.schema ~= 1 and cfg.schema ~= 2) then return nil end
    if type(cfg.fleetId) ~= "string" or cfg.fleetId == "" then return nil end
    if type(cfg.key) ~= "string" or #cfg.key < 16 then return nil end
    cfg.schema = 2
    cfg.relay = cfg.relay ~= false
    cfg.commandSeq = nil
    return cfg
end

local config = normalize(readJson(CONFIG_PATH)) or firstRun()
local mesh = {bootId=Common.randomHex(12), seq=0}
local seen = Common.newSeenCache()
local units = {}
local selected = 1
local groupMode = false
local message = "Fleet control ready"
local commandSeq = 0
local pending = {}

local function unitList()
    local now = Common.nowMs()
    local list = {}
    for _, unit in pairs(units) do
        unit.online = now - (unit.lastSeen or 0) <= UNIT_STALE_MS
        list[#list+1] = unit
    end
    table.sort(list, function(a,b) return a.id < b.id end)
    if #list == 0 then selected = 1 else selected = math.max(1, math.min(selected, #list)) end
    return list
end

local function selectedUnit()
    local list = unitList()
    return list[selected]
end

local function sendPacket(messageType, target, payload, ttl)
    local packet, err = Common.newPacket(config, mesh, messageType, target, payload, ttl)
    if not packet then return false, err end
    Common.markSeen(seen, Common.packetId(packet))
    return Common.broadcast(packet)
end

local function relay(packet)
    if not config.relay or packet.ttl <= 0 then return end
    local forwarded = Common.forwardPacket(packet, config.key)
    if forwarded then Common.broadcast(forwarded) end
end

local function pendingCount()
    local n = 0; for _ in pairs(pending) do n = n + 1 end; return n
end

local function handlePacket(packet, protocol)
    if protocol ~= Common.REDNET_PROTOCOL then return end
    local valid = Common.verify(packet, config.key, config.fleetId)
    if not valid then return end
    local pid = Common.packetId(packet)
    if Common.seen(seen, pid) then return end
    Common.markSeen(seen, pid)
    if packet.type == "status" then
        local p = packet.payload
        local id = tonumber(p.unit or packet.origin)
        if id then
            units[id] = {
                id=id, name=tostring(p.name or ("Unit-"..id)), role=tostring(p.role or "?"),
                state=tostring(p.state or "?"), linkState=tostring(p.linkState or "?"),
                fuel=p.fuel, fuelLimit=p.fuelLimit,
                navPos=p.navPos, navFrame=p.navFrame, gpsPos=p.gpsPos,
                heading=p.heading, homeNav=p.homeNav, capabilities=p.capabilities or {},
                rtb=p.rtb == true, rtbReason=p.rtbReason, version=p.version,
                lastSeen=Common.nowMs(), hops=Common.DEFAULT_TTL - math.max(0, tonumber(packet.ttl) or 0)
            }
        end
    elseif packet.type == "result" then
        local p = packet.payload
        local requestId = tostring(p.requestId or "")
        local item = pending[requestId]
        if item then
            item.expected[tostring(p.unit or packet.origin)] = nil
            local remaining = false
            for _ in pairs(item.expected) do remaining = true break end
            if not remaining then pending[requestId] = nil end
        end
        message = string.format("#%s %s %s", tostring(p.unit or packet.origin), p.ok and "OK" or "FAIL", tostring(p.detail or ""))
    end
    relay(packet)
end

local function transmitPending(item)
    local ok, err = sendPacket("command", item.target, item.payload)
    item.attempts = item.attempts + 1
    local idx = math.min(item.attempts, #RETRY_DELAYS_MS)
    item.nextRetry = Common.nowMs() + RETRY_DELAYS_MS[idx]
    if not ok then message = "send failed: " .. tostring(err) end
end

local function command(commandName, args)
    local unit = selectedUnit()
    if not unit then message = "No unit selected"; return end
    if not unit.online then message = "Selected unit offline"; return end
    if groupMode and (commandName == "forward" or commandName == "back"
        or commandName == "turn_left" or commandName == "turn_right"
        or commandName == "up" or commandName == "down" or commandName == "breach")
    then
        message = "Group movement/breach locked"
        return
    end
    if groupMode and commandName == "set_pose" then message = "Pose is single-unit only"; return end
    if pendingCount() >= PENDING_LIMIT then message = "Command window full"; return end

    local target = unit.id
    if groupMode then target = commandName == "update" and "*" or "ASSAULT" end
    commandSeq = commandSeq + 1
    local requestId = string.format("%d:%s:%d", os.getComputerID(), mesh.bootId, commandSeq)
    local payload = {
        operator=os.getComputerID(), operatorBoot=mesh.bootId,
        commandSeq=commandSeq, issuedAt=Common.nowMs(),
        requestId=requestId, command=commandName, args=type(args)=="table" and args or {}
    }
    local expected = {}
    if groupMode then
        for _, candidate in ipairs(unitList()) do
            if candidate.online and (commandName == "update" or candidate.role == "ASSAULT") then
                expected[tostring(candidate.id)] = true
            end
        end
    else
        expected[tostring(unit.id)] = true
    end
    local item = {target=target, payload=payload, expected=expected, attempts=0, nextRetry=0, expires=Common.nowMs()+4200}
    pending[requestId] = item
    transmitPending(item)
    message = commandName .. " -> " .. tostring(target)
end

local function retryPending()
    local now = Common.nowMs()
    for requestId, item in pairs(pending) do
        if now >= item.expires then
            pending[requestId] = nil
            message = "TIMEOUT " .. tostring(item.payload.command)
        elseif now >= item.nextRetry and item.attempts < #RETRY_DELAYS_MS then
            transmitPending(item)
        end
    end
end

local function textAt(y, text, color)
    local w = term.getSize()
    term.setCursorPos(1,y); term.setBackgroundColor(colors.black); term.setTextColor(color or colors.white)
    term.write(string.rep(" ", w)); term.setCursorPos(1,y); term.write(tostring(text):sub(1,w))
end

local function draw()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
    term.setCursorPos(1,1); term.setBackgroundColor(colors.red); term.write(string.rep(" ",w))
    term.setCursorPos(1,1); term.setTextColor(colors.white); term.write("BASE FLEET " .. config.fleetId)
    term.setBackgroundColor(colors.black)

    local list = unitList()
    textAt(2, string.format("Units:%d %s TX:%d", #list, groupMode and "GROUP" or "SINGLE", pendingCount()), colors.lightGray)
    local first = 4
    local visible = math.max(3, math.min(7, h - 11))
    local start = math.max(1, math.min(selected - math.floor(visible/2), math.max(1, #list-visible+1)))
    for row=0,visible-1 do
        local idx = start + row
        local u = list[idx]
        if u then
            local mark = idx == selected and ">" or " "
            local on = u.online and "+" or "-"
            textAt(first+row, string.format("%s%s#%s %-7s F:%s h:%s", mark,on,u.id,u.role:sub(1,7),tostring(u.fuel or "?"),tostring(u.hops or "?")), idx==selected and colors.cyan or colors.white)
        else textAt(first+row, "") end
    end

    local u = selectedUnit()
    local y = first + visible + 1
    if u then
        textAt(y, string.format("#%s %s %s/%s", u.id, u.name:sub(1,9), u.state:sub(1,8), u.linkState:sub(1,8)), colors.yellow)
        if u.navPos then
            textAt(y+1, string.format("NAV %.0f %.0f %.0f H:%s",u.navPos.x,u.navPos.y,u.navPos.z,tostring(u.heading or "?")))
        else textAt(y+1, "NAV unavailable") end
        if u.homeNav and u.navPos and u.navFrame == u.homeNav.frame then
            local dist = Common.distance(u.navPos, u.homeNav)
            textAt(y+2, string.format("Home %.0fm frame:%s", dist or 0, tostring(u.navFrame or "?"):sub(1,8)))
        else textAt(y+2, "Home/frame not set") end
        local c = u.capabilities or {}
        textAt(y+3, string.format("A%s D%s NAV%s R%s U%s",c.melee and "+" or "-",c.dig and "+" or "-",c.nav and "+" or "-",c.relay and "+" or "-",c.autoUpdate and "+" or "-"))
    end
    textAt(h-3, message, colors.orange)
    textAt(h-2, "ARROWS move A attack D dig B breach", colors.lightGray)
    textAt(h-1, "TAB/G H home P pose R RTB U update F5 self", colors.lightGray)
end

local function promptPose()
    local u = selectedUnit(); if not u then message="No unit selected"; return end
    term.clear(); term.setCursorPos(1,1)
    print("Set shared local pose for #" .. tostring(u.id))
    local x = tonumber(ask("X", u.navPos and u.navPos.x or 0))
    local y = tonumber(ask("Y", u.navPos and u.navPos.y or 0))
    local z = tonumber(ask("Z", u.navPos and u.navPos.z or 0))
    local heading = string.upper(ask("Heading N/E/S/W", u.heading or "N"))
    if not x or not y or not z or not heading:match("^[NESW]$") then message="Invalid pose"; return end
    command("set_pose", {x=x,y=y,z=z,heading=heading,frame=config.fleetId})
end

local function selfUpdate()
    if not fs.exists("/fleet_update.lua") then message = "fleet_update.lua not installed"; return end
    term.clear(); term.setCursorPos(1,1); print("Updating pocket runtime...")
    local ok = shell.run("/fleet_update.lua", "update", "pocket")
    if ok ~= false then os.reboot() end
    message = "Local update failed"
end

if #Common.openModems() == 0 then error("No wireless modem found on pocket computer",0) end
draw()
local retryTimer = os.startTimer(RETRY_TIMER_SECONDS)
local recoveryTimer = os.startTimer(2)
local beaconTimer = os.startTimer(0.5)

while true do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" then
        handlePacket(b,c); draw()
    elseif event == "timer" and a == retryTimer then
        retryPending(); retryTimer=os.startTimer(RETRY_TIMER_SECONDS); draw()
    elseif event == "timer" and a == recoveryTimer then
        Common.openModems(); recoveryTimer=os.startTimer(2)
    elseif event == "timer" and a == beaconTimer then
        sendPacket("operator_status", "*", {operator=os.getComputerID(), version=VERSION})
        beaconTimer=os.startTimer(1.5 + math.random() * 0.5)
    elseif event == "key" then
        if a == keys.up then command("forward")
        elseif a == keys.down then command("back")
        elseif a == keys.left then command("turn_left")
        elseif a == keys.right then command("turn_right")
        elseif a == keys.a then command("attack")
        elseif a == keys.d then command("dig")
        elseif a == keys.b then command("breach")
        elseif a == keys.r then command("rtb")
        elseif a == keys.h then command("set_home")
        elseif a == keys.space then command("hold")
        elseif a == keys.p then promptPose()
        elseif a == keys.u then command("update")
        elseif a == keys.f5 then selfUpdate()
        elseif a == keys.tab then
            local list=unitList(); if #list>0 then selected=(selected % #list)+1 end
        elseif a == keys.g then groupMode = not groupMode
        elseif a == keys.q or a == keys.leftShift or a == keys.escape then return end
        draw()
    elseif event == "peripheral" or event == "peripheral_detach" then
        Common.openModems(); draw()
    elseif event == "term_resize" then draw() end
end
