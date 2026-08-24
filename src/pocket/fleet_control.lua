local Common = require("lib.fleet.common")

local VERSION = "0.23.0-alpha.2"
local CONFIG_PATH = "/data/fleet_operator.json"
local UNIT_STALE_MS = 10000

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
    write(prompt .. (default and (" [" .. tostring(default) .. "]") or "") .. ": ")
    local value = read()
    if value == "" and default ~= nil then return tostring(default) end
    return value
end

local function collectFleetKey()
    term.clear(); term.setCursorPos(1,1)
    print("Fleet key entropy setup")
    print("Press varied keys 24 times.")
    local material = tostring(os.getComputerID()) .. ":" .. tostring(Common.nowMs())
    for index = 1, 24 do
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
    local cfg = {schema=1, fleetId=fleetId, key=key, commandSeq=0, relay=true}
    writeJson(CONFIG_PATH, cfg)
    return cfg
end

local function normalize(cfg)
    if type(cfg) ~= "table" or cfg.schema ~= 1 then return nil end
    if type(cfg.fleetId) ~= "string" or cfg.fleetId == "" then return nil end
    if type(cfg.key) ~= "string" or #cfg.key < 16 then return nil end
    cfg.commandSeq = math.max(0, math.floor(tonumber(cfg.commandSeq) or 0))
    cfg.relay = cfg.relay ~= false
    return cfg
end

local config = normalize(readJson(CONFIG_PATH)) or firstRun()
local mesh = {bootId=Common.randomHex(12), seq=0}
local seen = Common.newSeenCache()
local units = {}
local selected = 1
local groupMode = false
local message = "Fleet control ready"
local operatorPos = nil

local function saveConfig() writeJson(CONFIG_PATH, config) end

local function locate()
    if type(gps) ~= "table" or type(gps.locate) ~= "function" then return nil end
    local ok, x, y, z = pcall(gps.locate, 1.2, false)
    if ok and type(x) == "number" then return {x=x,y=y,z=z} end
    return nil
end

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
                state=tostring(p.state or "?"), fuel=p.fuel, fuelLimit=p.fuelLimit,
                pos=p.pos, heading=p.heading, home=p.home, capabilities=p.capabilities or {},
                rtb=p.rtb == true, rtbReason=p.rtbReason, version=p.version,
                lastSeen=Common.nowMs(), hops=Common.DEFAULT_TTL - math.max(0, tonumber(packet.ttl) or 0)
            }
        end
    elseif packet.type == "result" then
        local p = packet.payload
        message = string.format("#%s %s %s", tostring(p.unit or packet.origin), p.ok and "OK" or "FAIL", tostring(p.detail or ""))
    end
    relay(packet)
end

local function command(command)
    local unit = selectedUnit()
    if not unit then message = "No unit selected"; return end
    local target = groupMode and "ASSAULT" or unit.id
    config.commandSeq = config.commandSeq + 1
    saveConfig()
    local requestId = string.format("%d:%d:%d", os.getComputerID(), config.commandSeq, Common.nowMs())
    local ok, err = sendPacket("command", target, {
        operator=os.getComputerID(), commandSeq=config.commandSeq,
        requestId=requestId, command=command
    })
    message = ok and (command .. " -> " .. tostring(target)) or ("send failed: " .. tostring(err))
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
    textAt(2, string.format("Units:%d  %s", #list, groupMode and "GROUP" or "SINGLE"), colors.lightGray)
    local first = 4
    local visible = math.max(3, math.min(7, h - 11))
    local start = math.max(1, math.min(selected - math.floor(visible/2), math.max(1, #list-visible+1)))
    for row=0,visible-1 do
        local idx = start + row
        local u = list[idx]
        if u then
            local mark = idx == selected and ">" or " "
            local on = u.online and "+" or "-"
            textAt(first+row, string.format("%s%s#%s %-7s F:%s", mark,on,u.id,u.role:sub(1,7),tostring(u.fuel or "?")), idx==selected and colors.cyan or colors.white)
        else textAt(first+row, "") end
    end

    local u = selectedUnit()
    local y = first + visible + 1
    if u then
        textAt(y, string.format("#%s %s %s", u.id, u.name:sub(1,10), u.state:sub(1,10)), colors.yellow)
        local pos = u.pos and string.format("%.0f %.0f %.0f",u.pos.x,u.pos.y,u.pos.z) or "NO GPS"
        textAt(y+1, "Pos " .. pos .. " H:" .. tostring(u.heading or "?"))
        if operatorPos and u.pos then
            local dist, dx, dy, dz = Common.distance(u.pos, operatorPos)
            textAt(y+2, string.format("Rel %.0fm d%.0f/%.0f/%.0f",dist or 0,dx or 0,dy or 0,dz or 0))
        else textAt(y+2, "Rel: GPS unavailable") end
        local c = u.capabilities or {}
        textAt(y+3, string.format("A%s D%s GPS%s R%s hop:%s",c.melee and "+" or "-",c.dig and "+" or "-",c.gps and "+" or "-",c.relay and "+" or "-",tostring(u.hops or "?")))
    end
    textAt(h-3, message, colors.orange)
    textAt(h-2, "ARROWS move  A attack  R RTB", colors.lightGray)
    textAt(h-1, "TAB unit G group H home Q exit", colors.lightGray)
end

if #Common.openModems() == 0 then error("No wireless modem found on pocket computer",0) end
operatorPos = locate(); draw()
local gpsTimer = os.startTimer(2)

while true do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" then handlePacket(b,c); draw()
    elseif event == "timer" and a == gpsTimer then operatorPos=locate(); gpsTimer=os.startTimer(2); draw()
    elseif event == "key" then
        if a == keys.up then command("forward")
        elseif a == keys.down then command("back")
        elseif a == keys.left then command("turn_left")
        elseif a == keys.right then command("turn_right")
        elseif a == keys.a then command("attack")
        elseif a == keys.r then command("rtb")
        elseif a == keys.h then command("set_home")
        elseif a == keys.space then command("hold")
        elseif a == keys.tab then
            local list=unitList(); if #list>0 then selected=(selected % #list)+1 end
        elseif a == keys.g then groupMode = not groupMode
        elseif a == keys.q or a == keys.leftShift or a == keys.escape then return end
        draw()
    elseif event == "peripheral" or event == "peripheral_detach" then Common.openModems(); draw()
    elseif event == "term_resize" then draw() end
end
