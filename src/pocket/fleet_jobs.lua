local Common = require("lib.fleet.common")

local VERSION = "0.23.0-alpha.4"
local CONFIG_PATH = "/data/fleet_operator.json"
local UNIT_STALE_MS = 20000
local REPEAT_COUNT = 3
local REPEAT_DELAY = 0.22

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f=fs.open(path,"r"); if not f then return nil end
    local raw=f.readAll(); f.close()
    local ok,value=pcall(textutils.unserializeJSON,raw)
    return ok and type(value)=="table" and value or nil
end

local function ask(prompt, default)
    write(prompt .. (default ~= nil and (" ["..tostring(default).."]") or "") .. ": ")
    local value=read()
    if value=="" and default~=nil then return tostring(default) end
    return value
end

local config=readJson(CONFIG_PATH)
if type(config)~="table" or type(config.fleetId)~="string" or type(config.key)~="string" then
    error("Fleet operator config missing. Run fleet_control once first.",0)
end
config.relay=config.relay~=false

local mesh={bootId=Common.randomHex(12),seq=0}
local seen=Common.newSeenCache()
local units={}
local commandSeq=0
local message="Fleet Jobs ready"

local function sendPacket(messageType,target,payload,ttl)
    local packet,err=Common.newPacket(config,mesh,messageType,target,payload,ttl)
    if not packet then return false,err end
    Common.markSeen(seen,Common.packetId(packet))
    return Common.broadcast(packet)
end

local function relay(packet)
    if not config.relay or packet.ttl<=0 then return end
    local forwarded=Common.forwardPacket(packet,config.key)
    if forwarded then Common.broadcast(forwarded) end
end

local function handlePacket(packet,protocol)
    if protocol~=Common.REDNET_PROTOCOL then return end
    local valid=Common.verify(packet,config.key,config.fleetId)
    if not valid then return end
    local id=Common.packetId(packet)
    if Common.seen(seen,id) then return end
    Common.markSeen(seen,id)
    if packet.type=="status" then
        local p=packet.payload
        local unitId=tonumber(p.unit or packet.origin)
        if unitId then
            units[unitId]={
                id=unitId,name=tostring(p.name or ("Unit-"..unitId)),role=tostring(p.role or "?"),
                state=tostring(p.state or "?"),fuel=p.fuel,job=p.job,version=p.version,
                lastSeen=Common.nowMs(),hops=Common.DEFAULT_TTL-math.max(0,tonumber(packet.ttl) or 0)
            }
        end
    elseif packet.type=="job_event" then
        local p=packet.payload
        message=string.format("#%s JOB %s %s",tostring(p.unit or packet.origin),p.success and "DONE" or "FAIL",tostring(p.reason or ""))
    elseif packet.type=="result" then
        local p=packet.payload
        if p.command=="job_tunnel_roundtrip" or p.command=="job_cancel" then
            message=string.format("#%s %s %s",tostring(p.unit or packet.origin),p.ok and "ACK" or "FAIL",tostring(p.detail or ""))
        end
    end
    relay(packet)
end

local function onlineCounts()
    local now=Common.nowMs()
    local assault,relayCount,busy=0,0,0
    for _,u in pairs(units) do
        if now-(u.lastSeen or 0)<=UNIT_STALE_MS then
            if u.role=="ASSAULT" then assault=assault+1 else relayCount=relayCount+1 end
            if type(u.job)=="table" then busy=busy+1 end
        end
    end
    return assault,relayCount,busy
end

local function issue(command,args,target)
    commandSeq=commandSeq+1
    local payload={
        operator=os.getComputerID(),operatorBoot=mesh.bootId,commandSeq=commandSeq,
        issuedAt=Common.nowMs(),requestId=string.format("%d:%s:%d",os.getComputerID(),mesh.bootId,commandSeq),
        command=command,args=type(args)=="table" and args or {}
    }
    local ok=true
    for attempt=1,REPEAT_COUNT do
        local sent,err=sendPacket("command",target or "ASSAULT",payload)
        if not sent then ok=false; message="send failed: "..tostring(err) end
        if attempt<REPEAT_COUNT then sleep(REPEAT_DELAY) end
    end
    return ok,payload.requestId
end

local function confirm(text)
    term.clear(); term.setCursorPos(1,1)
    print(text)
    print("Y=CONFIRM  N/ESC=CANCEL")
    while true do
        local e,a=os.pullEvent()
        if e=="char" then if a:lower()=="y" then return true elseif a:lower()=="n" then return false end
        elseif e=="key" then if a==keys.y then return true elseif a==keys.n or a==keys.escape then return false end end
    end
end

local function startTunnel()
    term.clear(); term.setCursorPos(1,1)
    print("Tunnel roundtrip job")
    local distance=math.floor(tonumber(ask("Distance blocks",100)) or 0)
    local delay=tonumber(ask("Step delay seconds",0.15)) or 0.15
    if distance<1 or distance>4096 then message="Distance must be 1..4096"; return end
    if delay<0.05 or delay>2 then message="Delay must be 0.05..2.0"; return end
    local assault=select(1,onlineCounts())
    if assault==0 then message="No online ASSAULT units"; return end
    if not confirm(string.format("Start %d-block tunnel on %d ASSAULT units?",distance,assault)) then message="Job cancelled"; return end
    local jobId=string.format("TUN-%d-%d",os.getComputerID(),Common.nowMs())
    issue("job_tunnel_roundtrip",{jobId=jobId,distance=distance,stepDelay=delay},"ASSAULT")
    message=string.format("Tunnel %d dispatched to %d units",distance,assault)
end

local function cancelJobs()
    local _,_,busy=onlineCounts()
    if busy==0 then message="No reported active jobs"; return end
    if not confirm("Abort active jobs and return along tunnel?") then message="Abort cancelled"; return end
    issue("job_cancel",{},"ASSAULT")
    message="Abort/return dispatched"
end

local function updateFleet()
    if not confirm("Update all Fleet nodes? Units may reboot.") then message="Update cancelled"; return end
    issue("update",{},"*")
    message="Fleet update dispatched"
end

local function textAt(y,text,color)
    local w=term.getSize()
    term.setCursorPos(1,y); term.setBackgroundColor(colors.black); term.setTextColor(color or colors.white)
    term.write(string.rep(" ",w)); term.setCursorPos(1,y); term.write(tostring(text):sub(1,w))
end

local function draw()
    local w,h=term.getSize()
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
    term.setCursorPos(1,1); term.setBackgroundColor(colors.orange); term.write(string.rep(" ",w)); term.setCursorPos(1,1); term.setTextColor(colors.black); term.write("BASE POCKET / FLEET JOBS")
    term.setBackgroundColor(colors.black)
    local assault,relays,busy=onlineCounts()
    textAt(3,string.format("Fleet %s",config.fleetId),colors.lightGray)
    textAt(4,string.format("ASSAULT online: %d",assault))
    textAt(5,string.format("RELAY online:   %d",relays))
    textAt(6,string.format("Active jobs:    %d",busy),busy>0 and colors.yellow or colors.lightGray)
    local row=8
    local now=Common.nowMs()
    local list={}; for _,u in pairs(units) do if now-(u.lastSeen or 0)<=UNIT_STALE_MS and u.role=="ASSAULT" then list[#list+1]=u end end
    table.sort(list,function(a,b) return a.id<b.id end)
    local visible=math.max(1,h-13)
    for i=1,math.min(#list,visible) do
        local u=list[i]
        local job="IDLE"
        if type(u.job)=="table" then job=string.format("%s %d/%d",tostring(u.job.phase or "?"),tonumber(u.job.phase=="OUT" and u.job.outbound or u.job.returned) or 0,tonumber(u.job.phase=="OUT" and u.job.distance or u.job.outbound) or 0) end
        textAt(row+i-1,string.format("#%s F:%s %s",u.id,tostring(u.fuel or "?"),job))
    end
    textAt(h-3,message,colors.orange)
    textAt(h-2,"T tunnel roundtrip   C cancel/return",colors.lightGray)
    textAt(h-1,"U update fleet       Q back",colors.lightGray)
end

if #Common.openModems()==0 then error("No wireless modem found",0) end
draw()
local recovery=os.startTimer(2)
local beacon=os.startTimer(1)
while true do
    local e,a,b,c=os.pullEvent()
    if e=="rednet_message" then handlePacket(b,c); draw()
    elseif e=="timer" and a==recovery then Common.openModems(); recovery=os.startTimer(2)
    elseif e=="timer" and a==beacon then sendPacket("operator_status","*",{operator=os.getComputerID(),app="jobs",version=VERSION}); beacon=os.startTimer(4+math.random()); draw()
    elseif e=="key" then
        if a==keys.t then startTunnel()
        elseif a==keys.c then cancelJobs()
        elseif a==keys.u then updateFleet()
        elseif a==keys.q or a==keys.escape or a==keys.leftShift then return end
        draw()
    elseif e=="peripheral" or e=="peripheral_detach" then Common.openModems(); draw()
    elseif e=="term_resize" then draw() end
end
