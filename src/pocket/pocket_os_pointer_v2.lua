local VERSION = "0.23.0-alpha.5.4.1"
local RUNTIME_PATH = "/data/fleet_runtime.json"
local LEGACY_STARTUP = "/data/pocketbase_legacy_startup.lua"
local CONFIG_PATH = "/data/fleet_operator.json"
local LAUNCH_ERROR_PATH = "/data/pocket_launch_error.log"

local servicePaused=false
local appRunning=true
local selected=1
local rowHits={}

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f=fs.open(path,"r")
    if not f then return nil end
    local raw=f.readAll(); f.close()
    local ok,value=pcall(textutils.unserializeJSON,raw)
    return ok and type(value)=="table" and value or nil
end

local function line(y,text,color,bg)
    local w=term.getSize()
    term.setCursorPos(1,y)
    term.setBackgroundColor(bg or colors.black)
    term.setTextColor(color or colors.white)
    term.write(string.rep(" ",w))
    term.setCursorPos(1,y)
    term.write(tostring(text or ""):sub(1,w))
end

local function transportMode()
    local cfg=readJson(CONFIG_PATH)
    local mode=string.upper(tostring(cfg and cfg.transportMode or "AUTO"))
    if mode~="DIRECT" and mode~="MESH" then mode="AUTO" end
    return mode
end

local function waitPointerOrKey()
    while true do
        local e=os.pullEvent()
        if e=="key" or e=="mouse_click" or e=="monitor_touch" then return end
    end
end

local function writeLaunchError(path,err)
    pcall(function()
        local f=fs.open(LAUNCH_ERROR_PATH,"w")
        if not f then return end
        f.writeLine("BASE Pocket launch diagnostic")
        f.writeLine("version="..VERSION)
        f.writeLine("program="..tostring(path))
        f.writeLine("error="..tostring(err))
        f.writeLine("epoch="..tostring(os.epoch and os.epoch("utc") or 0))
        f.close()
    end)
end

local function showLaunchError(path,err)
    writeLaunchError(path,err)
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1)
    print("Application failed")
    print(tostring(path))
    print("")
    print(tostring(err or "unknown error"))
    print("")
    print("Log: "..LAUNCH_ERROR_PATH)
    print("Tap/click or press a key")
    waitPointerOrKey()
end

local function systemInfo()
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1)
    print("BASE Pocket System")
    print("Version: "..VERSION)
    print("Computer: #"..os.getComputerID())
    print("Label: "..tostring(os.getComputerLabel() or "-"))
    print("Free: "..tostring(fs.getFreeSpace("/")))
    local runtime=readJson(RUNTIME_PATH)
    print("Fleet runtime: "..tostring(runtime and runtime.version or "unknown"))
    print("Transport: "..transportMode())
    local names={}
    for _,name in ipairs(peripheral.getNames()) do
        local ok,t=pcall(peripheral.getType,name)
        if ok and t=="modem" then names[#names+1]=name end
    end
    print("Modem: "..(#names>0 and table.concat(names,",") or "none"))
    if fs.exists("/data/pointer_ui_error.log") then print("Pointer log: present") end
    if fs.exists(LAUNCH_ERROR_PATH) then print("Launch log: present") end
    print("")
    print("Tap/click or press a key")
    waitPointerOrKey()
end

local function updateSelf()
    servicePaused=true
    term.clear(); term.setCursorPos(1,1)
    print("Updating BASE Pocket...")
    if not fs.exists("/fleet_update.lua") then
        print("fleet_update.lua missing"); sleep(2); servicePaused=false; return false,"fleet_update.lua missing"
    end
    local ok=shell.run("/fleet_update.lua","update","pocket")
    if ok~=false then print("Updated. Rebooting..."); sleep(0.5); os.reboot() end
    print("Update failed"); sleep(2); servicePaused=false
    return false,"fleet update failed"
end

local function runProgram(path,...)
    servicePaused=true
    local ok=shell.run(path,...)
    servicePaused=false
    os.queueEvent("pocket_service_wake")
    if ok==false then return false,"shell.run returned false" end
    return true
end

local items={
    {name="Fleet Control",path="/fleet_control.lua",run=function() return runProgram("/fleet_control.lua") end},
    {name="Fleet Jobs",path="/fleet_jobs.lua",run=function() return runProgram("/fleet_jobs.lua") end},
    {name="Fleet Scheduler",path="/fleet_scheduler.lua",run=function() return runProgram("/fleet_scheduler.lua") end},
    {name="Fleet Performance",path="/fleet_performance.lua",run=function() return runProgram("/fleet_performance.lua") end},
    {name="Fleet Update",path="/fleet_update.lua",run=updateSelf},
    {name="System Info",path="system_info",run=function() systemInfo(); return true end},
    {name="Shell",path="shell",run=function() return runProgram("shell") end},
}
if fs.exists(LEGACY_STARTUP) then items[#items+1]={name="Legacy BASE",path=LEGACY_STARTUP,run=function() return runProgram(LEGACY_STARTUP) end} end
items[#items+1]={name="Reboot",path="reboot",run=function() os.reboot() end}
items[#items+1]={name="Shutdown",path="shutdown",run=function() os.shutdown() end}

local function draw()
    local w,h=term.getSize()
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
    term.setCursorPos(1,1); term.setBackgroundColor(colors.blue); term.write(string.rep(" ",w))
    term.setCursorPos(2,1); term.setTextColor(colors.white); term.write("BASE POCKET")
    line(2,"v"..VERSION.."  #"..os.getComputerID().." "..transportMode(),colors.lightGray)
    line(3,"Click/tap item; arrows are fallback",colors.cyan)

    rowHits={}
    local first=5
    local visible=math.max(1,h-7)
    local start=math.max(1,math.min(selected-math.floor(visible/2),math.max(1,#items-visible+1)))
    for row=0,visible-1 do
        local idx=start+row
        if items[idx] then
            local active=idx==selected
            local text=(active and "> " or "  ")..items[idx].name
            line(first+row,text,active and colors.black or colors.white,active and colors.cyan or colors.black)
            rowHits[first+row]=idx
        end
    end
    line(h-1,"[ UPDATE ]   click an item to open",colors.lightGray)
end

local function activate(index)
    local item=items[index]
    if not item then return end
    selected=index
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1)
    local callOk,runOk,runErr=pcall(item.run)
    servicePaused=false
    if not callOk then showLaunchError(item.path,runOk)
    elseif runOk==false then showLaunchError(item.path,runErr or "program returned false") end
end

local function uiLoop()
    draw()
    while true do
        local e,a,b,c=os.pullEvent()
        if e=="key" then
            if a==keys.up then selected=selected==1 and #items or selected-1
            elseif a==keys.down then selected=selected==#items and 1 or selected+1
            elseif a==keys.enter then activate(selected)
            elseif a==keys.u or a==keys.f5 then activate(5)
            end
            draw()
        elseif e=="mouse_click" then
            local x,y=b,c
            local _,h=term.getSize()
            if y==h-1 then activate(5)
            elseif rowHits[y] then activate(rowHits[y]) end
            draw()
        elseif e=="monitor_touch" then
            local x,y=b,c
            local _,h=term.getSize()
            if y==h-1 then activate(5)
            elseif rowHits[y] then activate(rowHits[y]) end
            draw()
        elseif e=="term_resize" then draw() end
    end
end

local function fleetServiceLoop()
    local okCommon,Common=pcall(require,"lib.fleet.common")
    local config=readJson(CONFIG_PATH)
    if not okCommon or type(Common)~="table" or type(config)~="table" or type(config.fleetId)~="string" or type(config.key)~="string" then
        while true do os.pullEvent("pocket_service_wake") end
    end
    config.relay=config.relay~=false
    local mesh={bootId=Common.randomHex(12),seq=0}
    local seen=Common.newSeenCache()

    local function refreshMode()
        local latest=readJson(CONFIG_PATH)
        local mode=string.upper(tostring(latest and latest.transportMode or config.transportMode or "AUTO"))
        if mode~="DIRECT" and mode~="MESH" then mode="AUTO" end
        config.transportMode=mode
        return mode
    end

    local function sendPacket(kind,target,payload,ttl)
        local packet,err=Common.newPacket(config,mesh,kind,target,payload,ttl)
        if not packet then return false,err end
        Common.markSeen(seen,Common.packetId(packet))
        return Common.broadcast(packet)
    end

    local function handlePacket(packet,protocol)
        if servicePaused or protocol~=Common.REDNET_PROTOCOL then return end
        local valid=Common.verify(packet,config.key,config.fleetId)
        if not valid then return end
        local id=Common.packetId(packet)
        if Common.seen(seen,id) then return end
        Common.markSeen(seen,id)
        if config.transportMode=="MESH" and config.relay and tonumber(packet.ttl) and packet.ttl>0 then
            local forwarded=Common.forwardPacket(packet,config.key)
            if forwarded then Common.broadcast(forwarded) end
        end
    end

    Common.openModems(); refreshMode()
    local beacon=os.startTimer(0.2)
    local discover=os.startTimer(0.1)
    local recovery=os.startTimer(2)
    while appRunning do
        local e,a,b,c=os.pullEvent()
        if e=="rednet_message" then handlePacket(b,c)
        elseif e=="timer" and a==beacon then
            if not servicePaused then local mode=refreshMode(); local ttl=mode=="MESH" and Common.DEFAULT_TTL or 0; sendPacket("operator_status","*",{operator=os.getComputerID(),app="pocket_os",version=VERSION,transport=mode},ttl) end
            beacon=os.startTimer(4)
        elseif e=="timer" and a==discover then
            if not servicePaused then local mode=refreshMode(); local ttl=mode=="MESH" and Common.DEFAULT_TTL or 0; sendPacket("discover","*",{operator=os.getComputerID(),app="pocket_os",version=VERSION,transport=mode},ttl) end
            discover=os.startTimer(12)
        elseif e=="timer" and a==recovery then Common.openModems(); recovery=os.startTimer(2)
        elseif e=="peripheral" or e=="peripheral_detach" then Common.openModems()
        elseif e=="pocket_service_wake" and not servicePaused then
            local mode=refreshMode(); local ttl=mode=="MESH" and Common.DEFAULT_TTL or 0
            sendPacket("discover","*",{operator=os.getComputerID(),app="pocket_os",version=VERSION,transport=mode},ttl)
        end
    end
end

parallel.waitForAny(uiLoop,fleetServiceLoop)
