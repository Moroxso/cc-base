local Common=require("lib.fleet.common")
local Industrial=require("lib.fleet.industrial")

local VERSION="0.23.0-alpha.6.2"
local CONFIG_PATH="/data/fleet_operator.json"
local CACHE_PATH="/data/fleet_units_cache.json"
local STALE_MS=30000

local function readJson(path)
 if not fs.exists(path) or fs.isDir(path) then return nil end; local f=fs.open(path,"r"); if not f then return nil end; local raw=f.readAll(); f.close(); local ok,v=pcall(textutils.unserializeJSON,raw); return ok and type(v)=="table" and v or nil
end
local function ask(prompt,default) write(prompt..(default~=nil and (" ["..tostring(default).."]") or "")..": "); local v=read(); if v=="" and default~=nil then return tostring(default) end; return v end
local function confirm(text)
 term.clear(); term.setCursorPos(1,1); print(text); print("Y=CONFIRM  N/ESC=CANCEL")
 while true do local e,a=os.pullEvent(); if e=="char" then a=a:lower(); if a=="y" then return true elseif a=="n" then return false end elseif e=="key" then if a==keys.y then return true elseif a==keys.n or a==keys.escape then return false end end end
end
local cfg=readJson(CONFIG_PATH); if type(cfg)~="table" or type(cfg.fleetId)~="string" or type(cfg.key)~="string" then error("Fleet operator config missing. Run Fleet Control first.",0) end
local mesh={bootId=Common.randomHex(12),seq=0}; local seen=Common.newSeenCache(); local commandSeq=0
local units={}; local cache=readJson(CACHE_PATH) or {}; for k,v in pairs(cache) do local id=tonumber(type(v)=="table" and v.id or k); if id and type(v)=="table" then v.id=id; units[id]=v end end
local function send(kind,target,payload)
 local p,e=Common.newPacket(cfg,mesh,kind,target,payload); if not p then return false,e end; Common.markSeen(seen,Common.packetId(p)); return Common.broadcast(p)
end
local function onlineAssaults()
 local now=Common.nowMs(); local out={}; for _,u in pairs(units) do if tostring(u.role or "")=="ASSAULT" and now-(tonumber(u.lastSeen) or 0)<=STALE_MS then out[#out+1]=u end end; table.sort(out,function(a,b) return a.id<b.id end); return out
end
local function selectedDefault()
 local list=onlineAssaults(); for _,u in ipairs(list) do if type(u.capabilities)=="table" and u.capabilities.industrialBox then return u.id end end; return list[1] and list[1].id or nil
end
local function collectDiscovery(seconds)
 send("discover","*",{operator=os.getComputerID(),app="box",version=VERSION}); local timer=os.startTimer(seconds or 0.8)
 while true do local e,a,b,c=os.pullEvent(); if e=="timer" and a==timer then return elseif e=="rednet_message" and c==Common.REDNET_PROTOCOL then
  local ok=Common.verify(b,cfg.key,cfg.fleetId); if ok and b.type=="status" then local p=b.payload or {}; local id=tonumber(p.unit or b.origin); if id then local u=units[id] or {id=id}; u.id=id; u.name=p.name or u.name; u.role=p.role or u.role; u.version=p.version or u.version; u.capabilities=p.capabilities or u.capabilities or {}; u.lastSeen=Common.nowMs(); units[id]=u end end
 end end
end
collectDiscovery(0.8)
term.clear(); term.setCursorPos(1,1); print("Excavate Box / single unit")
local defaultId=selectedDefault(); if not defaultId then error("No online ASSAULT unit found",0) end
local unitId=math.floor(tonumber(ask("Unit ID",defaultId)) or 0)
local width=math.floor(tonumber(ask("Width blocks",3)) or 0)
local length=math.floor(tonumber(ask("Length blocks",3)) or 0)
local height=math.floor(tonumber(ask("Height blocks",2)) or 0)
local delay=tonumber(ask("Step delay seconds",0.15)) or 0.15
local plan,planErr=Industrial.plan({type="excavate_box",width=width,length=length,height=height,stepDelay=delay}); if not plan then error("Invalid Box: "..tostring(planErr),0) end
local unit=units[unitId]; if not unit or Common.nowMs()-(tonumber(unit.lastSeen) or 0)>STALE_MS then error("Selected unit is offline/stale",0) end
if type(unit.capabilities)=="table" and unit.capabilities.industrialBox==false then error("Selected unit does not support Excavate Box",0) end
local safeFuel=plan.volume*2+plan.fuelReserve
if not confirm(string.format("Start Box %dx%dx%d (%d cells) on #%d?",width,length,height,plan.volume,unitId)) then print("Box cancelled"); return end

local jobId=string.format("BOX-%d-%d",os.getComputerID(),Common.nowMs())
local function issue(command,args)
 commandSeq=commandSeq+1; local rid=string.format("%d:%s:%d",os.getComputerID(),mesh.bootId,commandSeq)
 local payload={operator=os.getComputerID(),operatorBoot=mesh.bootId,commandSeq=commandSeq,issuedAt=Common.nowMs(),requestId=rid,command=command,args=args or {}}
 send("command",unitId,payload); return rid,payload
end
local startRid,startPayload=issue("job_excavate_box",{jobId=jobId,width=width,length=length,height=height,stepDelay=delay})
local pending={rid=startRid,payload=startPayload,attempts=1,next=Common.nowMs()+500}
local job={id=jobId,type="excavate_box",phase="QUEUED",completed=0,returned=0,volume=plan.volume}
local message=string.format("Queued #%d  fuel need >=%d",unitId,safeFuel)
local done=false

local function draw()
 local w,h=term.getSize(); term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1); term.setBackgroundColor(colors.orange); term.setTextColor(colors.black); term.write(string.rep(" ",w)); term.setCursorPos(1,1); term.write("EXCAVATE BOX alpha6.2"); term.setBackgroundColor(colors.black)
 term.setTextColor(colors.white); term.setCursorPos(1,3); print(string.format("Unit #%d  %dx%dx%d  cells:%d",unitId,width,length,height,plan.volume)); print("Job: "..jobId); print("Phase: "..tostring(job.phase or "?")); print(string.format("Work: %d/%d",tonumber(job.completed or job.outbound) or 0,tonumber(job.volume or job.distance) or plan.volume)); print(string.format("Return: %d/%d",tonumber(job.returned) or 0,tonumber(job.completed or job.outbound) or 0)); print("Fuel reserve plan: "..safeFuel); print(""); print(message); if not done then print("C cancel+return   Q back (job continues)") else print("Q back") end
end
local function applyJob(p)
 if type(p)~="table" then return end; job.id=p.id or job.id; job.type=p.type or job.type; job.phase=p.phase or job.phase; job.completed=tonumber(p.completed or p.outbound) or job.completed; job.returned=tonumber(p.returned) or job.returned; job.volume=tonumber(p.volume or p.distance) or job.volume
end
local function handle(packet,protocol)
 if protocol~=Common.REDNET_PROTOCOL then return end; local ok=Common.verify(packet,cfg.key,cfg.fleetId); if not ok then return end; local id=Common.packetId(packet); if Common.seen(seen,id) then return end; Common.markSeen(seen,id)
 local p=packet.payload or {}; local from=tonumber(p.unit or packet.origin); if from~=unitId then return end
 if packet.type=="status" then units[unitId]=units[unitId] or {id=unitId}; units[unitId].lastSeen=Common.nowMs(); applyJob(p.job)
 elseif packet.type=="result" then
  if tostring(p.requestId or "")==tostring(pending and pending.rid or "") then pending=nil end; applyJob(p.job); message=(p.ok and "ACK " or "FAIL ")..tostring(p.detail or ""); if p.command=="job_excavate_box" and p.ok~=true then done=true end
 elseif packet.type=="job_event" and tostring(p.id or "")==jobId then
  applyJob(p); local ev=tostring(p.event or "?"); message="JOB "..ev.." "..tostring(p.reason or ""); if ev=="DONE" or ev=="FAIL" then done=true end
 end
end

draw(); local retry=os.startTimer(0.2); local discover=os.startTimer(4)
while true do
 local e,a,b,c=os.pullEvent()
 if e=="rednet_message" then handle(b,c); draw()
 elseif e=="timer" and a==retry then
  if pending and Common.nowMs()>=pending.next and pending.attempts<3 then send("command",unitId,pending.payload); pending.attempts=pending.attempts+1; pending.next=Common.nowMs()+700 end; retry=os.startTimer(0.2)
 elseif e=="timer" and a==discover then send("discover","*",{operator=os.getComputerID(),app="box",version=VERSION}); discover=os.startTimer(4)
 elseif e=="key" then
  if a==keys.c and not done then
   if confirm("Abort Box and return to origin?") then local rid,p=issue("job_cancel",{}); pending={rid=rid,payload=p,attempts=1,next=Common.nowMs()+500}; message="Cancel/return queued" else message="Cancel aborted" end; draw()
  elseif a==keys.q or a==keys.escape or a==keys.leftShift then return end
 elseif e=="term_resize" then draw() end
end
