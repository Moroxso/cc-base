local Common = require("lib.fleet.common")

local VERSION = "0.23.0-alpha.4"
local CONFIG_PATH = "/data/fleet_operator.json"
local UNIT_STALE_MS = 20000
local RETRY_TIMER_SECONDS = 0.2
local RETRY_DELAYS_MS = {250, 600, 1200, 2200}
local PENDING_LIMIT = 6

local function ensureParent(path)
    local dir=fs.getDir(path); if dir~="" and not fs.exists(dir) then fs.makeDir(dir) end
end
local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f=fs.open(path,"r"); if not f then return nil end
    local raw=f.readAll(); f.close(); local ok,v=pcall(textutils.unserializeJSON,raw)
    return ok and type(v)=="table" and v or nil
end
local function writeJson(path,value)
    ensureParent(path); local ok,raw=pcall(textutils.serializeJSON,value); if not ok then return false end
    local tmp=path..".tmp"; if fs.exists(tmp) then pcall(fs.delete,tmp) end
    local f=fs.open(tmp,"w"); if not f then return false end; f.write(raw); f.close()
    if fs.exists(path) then pcall(fs.delete,path) end; fs.move(tmp,path); return true
end
local function ask(prompt,default)
    write(prompt..(default~=nil and (" ["..tostring(default).."]") or "")..": ")
    local v=read(); if v=="" and default~=nil then return tostring(default) end; return v
end
local function collectFleetKey()
    term.clear(); term.setCursorPos(1,1); print("Fleet key entropy setup"); print("Press varied keys 24 times.")
    local material=tostring(os.getComputerID())..":"..tostring(Common.nowMs())
    for _=1,24 do local _,code=os.pullEvent("key"); material=material..":"..tostring(code)..":"..tostring(Common.nowMs()); write(".") end
    print(""); local key,err=Common.sha1(material); if not key then error("Key generation failed: "..tostring(err),0) end; return key
end
local function firstRun()
    Common.openModems(); term.clear(); term.setCursorPos(1,1); print("BASE Fleet Pocket Setup"); print("Pocket ID: "..os.getComputerID())
    local fleetId=ask("Fleet ID","F"..os.getComputerID()); local key=collectFleetKey(); print("Generated fleet key:"); print(key); print("Enter this key on Fleet turtles."); print("Press ENTER when recorded."); read()
    local cfg={schema=3,fleetId=fleetId,key=key,relay=true}; writeJson(CONFIG_PATH,cfg); return cfg
end
local function normalize(cfg)
    if type(cfg)~="table" or type(cfg.fleetId)~="string" or type(cfg.key)~="string" or #cfg.key<16 then return nil end
    cfg.schema=3; cfg.relay=cfg.relay~=false; cfg.commandSeq=nil; return cfg
end

local config=normalize(readJson(CONFIG_PATH)) or firstRun()
local mesh={bootId=Common.randomHex(12),seq=0}
local seen=Common.newSeenCache()
local units={}; local selected=1; local groupMode=false; local message="Fleet control ready"; local commandSeq=0; local pending={}

local function unitList()
    local now=Common.nowMs(); local list={}
    for _,u in pairs(units) do u.online=now-(u.lastSeen or 0)<=UNIT_STALE_MS; list[#list+1]=u end
    table.sort(list,function(a,b) return a.id<b.id end)
    if #list==0 then selected=1 else selected=math.max(1,math.min(selected,#list)) end
    return list
end
local function selectedUnit() local list=unitList(); return list[selected] end
local function sendPacket(kind,target,payload,ttl)
    local packet,err=Common.newPacket(config,mesh,kind,target,payload,ttl); if not packet then return false,err end
    Common.markSeen(seen,Common.packetId(packet)); return Common.broadcast(packet)
end
local function relay(packet)
    if not config.relay or packet.ttl<=0 then return end
    local f=Common.forwardPacket(packet,config.key); if f then Common.broadcast(f) end
end
local function pendingCount() local n=0; for _ in pairs(pending) do n=n+1 end; return n end
local function handlePacket(packet,protocol)
    if protocol~=Common.REDNET_PROTOCOL then return end
    local valid=Common.verify(packet,config.key,config.fleetId); if not valid then return end
    local pid=Common.packetId(packet); if Common.seen(seen,pid) then return end; Common.markSeen(seen,pid)
    if packet.type=="status" then
        local p=packet.payload; local id=tonumber(p.unit or packet.origin)
        if id then units[id]={id=id,name=tostring(p.name or ("Unit-"..id)),role=tostring(p.role or "?"),state=tostring(p.state or "?"),linkState=tostring(p.linkState or "?"),fuel=p.fuel,navPos=p.navPos,navFrame=p.navFrame,heading=p.heading,homeNav=p.homeNav,capabilities=p.capabilities or {},job=p.job,version=p.version,lastSeen=Common.nowMs(),hops=Common.DEFAULT_TTL-math.max(0,tonumber(packet.ttl) or 0)} end
    elseif packet.type=="result" then
        local p=packet.payload; local rid=tostring(p.requestId or ""); local item=pending[rid]
        if item then item.expected[tostring(p.unit or packet.origin)]=nil; local any=false; for _ in pairs(item.expected) do any=true break end; if not any then pending[rid]=nil end end
        message=string.format("#%s %s %s",tostring(p.unit or packet.origin),p.ok and "OK" or "FAIL",tostring(p.detail or ""))
    elseif packet.type=="job_event" then
        local p=packet.payload; message=string.format("#%s JOB %s",tostring(p.unit or packet.origin),p.success and "DONE" or "FAIL")
    end
    relay(packet)
end
local function transmit(item)
    local ok,err=sendPacket("command",item.target,item.payload); item.attempts=item.attempts+1; item.nextRetry=Common.nowMs()+RETRY_DELAYS_MS[math.min(item.attempts,#RETRY_DELAYS_MS)]; if not ok then message="send failed: "..tostring(err) end
end
local function command(name,args)
    local u=selectedUnit(); if not u then message="No unit selected"; return end
    if not u.online then message="Selected unit offline"; return end
    if groupMode and (name=="forward" or name=="back" or name=="turn_left" or name=="turn_right" or name=="up" or name=="down" or name=="breach" or name=="set_pose") then message="Group movement locked; use Fleet Jobs"; return end
    if pendingCount()>=PENDING_LIMIT then message="Command window full"; return end
    local target=groupMode and (name=="update" and "*" or "ASSAULT") or u.id
    commandSeq=commandSeq+1
    local rid=string.format("%d:%s:%d",os.getComputerID(),mesh.bootId,commandSeq)
    local payload={operator=os.getComputerID(),operatorBoot=mesh.bootId,commandSeq=commandSeq,issuedAt=Common.nowMs(),requestId=rid,command=name,args=type(args)=="table" and args or {}}
    local expected={}
    if groupMode then for _,candidate in ipairs(unitList()) do if candidate.online and (name=="update" or candidate.role=="ASSAULT") then expected[tostring(candidate.id)]=true end end else expected[tostring(u.id)]=true end
    local item={target=target,payload=payload,expected=expected,attempts=0,nextRetry=0,expires=Common.nowMs()+5000}; pending[rid]=item; transmit(item); message=name.." -> "..tostring(target)
end
local function retryPending()
    local now=Common.nowMs(); for rid,item in pairs(pending) do if now>=item.expires then pending[rid]=nil; message="TIMEOUT "..tostring(item.payload.command) elseif now>=item.nextRetry and item.attempts<#RETRY_DELAYS_MS then transmit(item) end end
end
local function textAt(y,text,color)
    local w=term.getSize(); term.setCursorPos(1,y); term.setBackgroundColor(colors.black); term.setTextColor(color or colors.white); term.write(string.rep(" ",w)); term.setCursorPos(1,y); term.write(tostring(text):sub(1,w))
end
local function draw()
    local w,h=term.getSize(); term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1); term.setBackgroundColor(colors.red); term.write(string.rep(" ",w)); term.setCursorPos(1,1); term.setTextColor(colors.white); term.write("BASE FLEET "..config.fleetId); term.setBackgroundColor(colors.black)
    local list=unitList(); textAt(2,string.format("Units:%d %s TX:%d",#list,groupMode and "GROUP" or "SINGLE",pendingCount()),colors.lightGray)
    local first=4; local visible=math.max(3,math.min(7,h-11)); local start=math.max(1,math.min(selected-math.floor(visible/2),math.max(1,#list-visible+1)))
    for row=0,visible-1 do local idx=start+row; local u=list[idx]; if u then local mark=idx==selected and ">" or " "; local on=u.online and "+" or "-"; textAt(first+row,string.format("%s%s#%s %-7s F:%s h:%s",mark,on,u.id,u.role:sub(1,7),tostring(u.fuel or "?"),tostring(u.hops or "?")),idx==selected and colors.cyan or colors.white) else textAt(first+row,"") end end
    local u=selectedUnit(); local y=first+visible+1
    if u then textAt(y,string.format("#%s %s %s/%s",u.id,u.name:sub(1,9),u.state:sub(1,9),u.linkState:sub(1,8)),colors.yellow); if u.navPos then textAt(y+1,string.format("NAV %.0f %.0f %.0f H:%s",u.navPos.x,u.navPos.y,u.navPos.z,tostring(u.heading or "?"))) else textAt(y+1,"NAV unavailable") end; local c=u.capabilities or {}; textAt(y+2,string.format("A%s D%s JOB%s R%s",c.melee and "+" or "-",c.dig and "+" or "-",c.jobs and "+" or "-",c.relay and "+" or "-")); if type(u.job)=="table" then textAt(y+3,string.format("JOB %s %s %s/%s",tostring(u.job.type or "?"),tostring(u.job.phase or "?"),tostring(u.job.phase=="OUT" and u.job.outbound or u.job.returned),tostring(u.job.phase=="OUT" and u.job.distance or u.job.outbound)),colors.orange) else textAt(y+3,"JOB none") end end
    textAt(h-3,message,colors.orange); textAt(h-2,"ARROWS move A attack D dig B breach",colors.lightGray); textAt(h-1,"TAB/G H home R RTB U update J jobs Q back",colors.lightGray)
end
local function selfUpdate()
    if not fs.exists("/fleet_update.lua") then message="fleet_update.lua missing"; return end
    term.clear(); term.setCursorPos(1,1); print("Updating BASE Pocket..."); local ok=shell.run("/fleet_update.lua","update","pocket"); if ok~=false then os.reboot() end; message="Update failed"
end
if #Common.openModems()==0 then error("No wireless modem found on pocket computer",0) end
draw(); local retryTimer=os.startTimer(RETRY_TIMER_SECONDS); local recovery=os.startTimer(2); local beacon=os.startTimer(1)
while true do
    local e,a,b,c=os.pullEvent()
    if e=="rednet_message" then handlePacket(b,c); draw()
    elseif e=="timer" and a==retryTimer then retryPending(); retryTimer=os.startTimer(RETRY_TIMER_SECONDS); draw()
    elseif e=="timer" and a==recovery then Common.openModems(); recovery=os.startTimer(2)
    elseif e=="timer" and a==beacon then sendPacket("operator_status","*",{operator=os.getComputerID(),version=VERSION}); beacon=os.startTimer(4+math.random()); draw()
    elseif e=="key" then
        if a==keys.up then command("forward") elseif a==keys.down then command("back") elseif a==keys.left then command("turn_left") elseif a==keys.right then command("turn_right") elseif a==keys.a then command("attack") elseif a==keys.d then command("dig") elseif a==keys.b then command("breach") elseif a==keys.r then command("rtb") elseif a==keys.h then command("set_home") elseif a==keys.space then command("hold") elseif a==keys.u then command("update") elseif a==keys.f5 then selfUpdate() elseif a==keys.j then if fs.exists("/fleet_jobs.lua") then shell.run("/fleet_jobs.lua") else message="fleet_jobs.lua missing" end elseif a==keys.tab then local list=unitList(); if #list>0 then selected=(selected%#list)+1 end elseif a==keys.g then groupMode=not groupMode elseif a==keys.q or a==keys.escape or a==keys.leftShift then return end; draw()
    elseif e=="peripheral" or e=="peripheral_detach" then Common.openModems(); draw() elseif e=="term_resize" then draw() end
end
