local Common=require("lib.fleet.common")
local Box=require("lib.fleet.industrial_box")

local VERSION="0.23.0-alpha.6.2"
local INNER_PATH="/assault_agent_guarded.lua"
local CONFIG_PATH="/data/fleet_agent.json"
local LAST_JOB_PATH="/data/fleet_last_job.json"
local CHECKPOINT_PATH="/data/fleet_industrial_job.json"
local BOX_COMMAND="job_excavate_box"
local BOX_BUSY="__box_busy__"
local BOX_CANCEL="__box_cancel__"
local BOX_REPEAT="__box_repeat__"
local BOX_TARGET="__box_target__"

local function readJson(path)
 if not fs.exists(path) or fs.isDir(path) then return nil end; local f=fs.open(path,"r"); if not f then return nil end
 local raw=f.readAll(); f.close(); local ok,v=pcall(textutils.unserializeJSON,raw); return ok and type(v)=="table" and v or nil
end
local function writeJson(path,v)
 local d=fs.getDir(path); if d~="" and not fs.exists(d) then fs.makeDir(d) end; local ok,raw=pcall(textutils.serializeJSON,v); if not ok then return false end
 local n=path..".tmp"; if fs.exists(n) then pcall(fs.delete,n) end; local f=fs.open(n,"w"); if not f then return false end; f.write(raw); f.close(); if fs.exists(path) then pcall(fs.delete,path) end; fs.move(n,path); return true
end
local function copy(t) local o={}; if type(t)=="table" then for k,v in pairs(t) do o[k]=type(v)=="table" and copy(v) or v end end; return o end
local function targeted(packet,role)
 local t=packet and packet.target; return t==nil or t=="*" or tonumber(t)==os.getComputerID() or tostring(t)==tostring(role)
end
local function currentPose(cfg)
 local n=type(cfg.nav)=="table" and cfg.nav or {}; return {x=tonumber(n.x) or 0,y=tonumber(n.y) or 0,z=tonumber(n.z) or 0,heading=math.floor(tonumber(cfg.heading) or 0)%4,frame=tostring(n.frame or cfg.fleetId or "")}
end

local config=readJson(CONFIG_PATH) or {}
if type(config.fleetId)~="string" or type(config.key)~="string" then error("Fleet agent config missing",0) end
local role=tostring(config.role or "ASSAULT")
local latestPose=currentPose(config)
local rawFuel=turtle.getFuelLevel
local rawLimit=turtle.getFuelLimit
local box=Box.new({checkpointPath=CHECKPOINT_PATH,nowMs=Common.nowMs,getFuelLevel=rawFuel,getFuelLimit=rawLimit})
local baseVerify=Common.verify
local baseNewPacket=Common.newPacket
local baseWaitForAny=parallel.waitForAny
local mesh={bootId=Common.randomHex(12),seq=0}
local requests={}
local results={}
local boxLastJob=nil

turtle.getFuelLevel=function(...)
 if box:isActive() or box:isLocked() then return "unlimited" end
 return rawFuel(...)
end

local function send(kind,target,payload)
 local packet,err=baseNewPacket(config,mesh,kind,target,payload)
 if not packet then return false,err end
 return Common.broadcast(packet)
end
local function event(name,success,reason)
 local job=box:job(); if not job then return end; local p=copy(job); p.unit=os.getComputerID(); p.event=name; p.success=success; p.reason=reason or p.reason; p.industrial=box:summary(); send("job_event","*",p)
 if name=="DONE" or name=="FAIL" then
  boxLastJob={schema=1,id=tostring(job.id or ""),type=tostring(job.type or BOX_COMMAND),success=name=="DONE" and success~=false,reason=tostring(reason or job.reason or ""),finishedAt=Common.nowMs(),outbound=math.floor(tonumber(job.completed or job.outbound) or 0),returned=math.floor(tonumber(job.returned) or 0),distance=math.floor(tonumber(job.volume or job.distance) or 0),recoveries=math.floor(tonumber(job.recoveries) or 0)}
  writeJson(LAST_JOB_PATH,boxLastJob)
 end
end

Common.verify=function(packet,key,fleetId)
 local valid,err=baseVerify(packet,key,fleetId); if not valid then return valid,err end
 if role~="ASSAULT" or packet.type~="command" or not targeted(packet,role) then return valid,err end
 local p=type(packet.payload)=="table" and packet.payload or {}; local command=tostring(p.command or ""); local rid=tostring(p.requestId or "")
 if results[rid] then p.command=BOX_REPEAT; requests[rid]={kind="repeat",original=results[rid].command}; return valid,err end
 if box:isActive() or box:isLocked() then
  if command=="job_cancel" and box:isActive() then p.command=BOX_CANCEL; requests[rid]={kind="cancel",original=command,origin=packet.origin}
  else p.command=BOX_BUSY; requests[rid]={kind="busy",original=command,origin=packet.origin} end
  return valid,err
 end
 if command==BOX_COMMAND then
  requests[rid]={kind=tonumber(packet.target)==os.getComputerID() and "start" or "target",original=command,args=copy(p.args),origin=packet.origin}
  if tonumber(packet.target)~=os.getComputerID() then p.command=BOX_TARGET end
 end
 return valid,err
end

local function headingNumber(v,fallback)
 if type(v)=="number" then return math.floor(v)%4 end; local m={N=0,E=1,S=2,W=3}; return m[string.upper(tostring(v or ""))] or math.floor(tonumber(fallback) or 0)%4
end
local function handleCoreResult(payload)
 local rid=tostring(payload.requestId or ""); local req=requests[rid]; if not req then return false end
 if req.kind=="repeat" then local old=results[rid]; if old then payload.command=old.command; payload.ok=old.ok; payload.detail=old.detail end; requests[rid]=nil; return true end
 if req.kind=="busy" then payload.command=req.original; payload.ok=false; payload.detail=box:isLocked() and "industrial_recovery_required" or "job_active"; requests[rid]=nil; return true end
 if req.kind=="target" then payload.command=req.original; payload.ok=false; payload.detail="box_requires_single_unit_target"; results[rid]={command=req.original,ok=false,detail=payload.detail,target=req.origin}; requests[rid]=nil; return true end
 if req.kind=="cancel" then local ok,detail=box:cancel("OPERATOR_ABORT"); payload.command=req.original; payload.ok=ok; payload.detail=detail; results[rid]={command=req.original,ok=ok,detail=detail,target=req.origin}; requests[rid]=nil; if ok then event("RETURN",nil,"OPERATOR_ABORT"); os.queueEvent("fleet_box_wake") end; return true end
 if req.kind=="start" then
  if tostring(payload.detail or "")~="unknown_command" then requests[rid]=nil; return false end
  local ok,detail=box:start(req.args,rid,latestPose); payload.command=req.original; payload.ok=ok; payload.detail=detail; payload.job=box:job(); payload.industrial=box:summary(); results[rid]={command=req.original,ok=ok,detail=detail,target=req.origin}; requests[rid]=nil
  if ok then event("START"); os.queueEvent("fleet_box_wake") end; return true
 end
 return false
end

Common.newPacket=function(cfg,state,kind,target,payload,ttl)
 payload=type(payload)=="table" and payload or {}
 if kind=="result" then handleCoreResult(payload) end
 if kind=="status" then
  if not box:isActive() and not box:isLocked() and type(payload.navPos)=="table" then latestPose={x=tonumber(payload.navPos.x) or latestPose.x,y=tonumber(payload.navPos.y) or latestPose.y,z=tonumber(payload.navPos.z) or latestPose.z,heading=headingNumber(payload.heading,latestPose.heading),frame=tostring(payload.navFrame or latestPose.frame)} end
  payload.version=VERSION; payload.capabilities=type(payload.capabilities)=="table" and payload.capabilities or {}; payload.capabilities.industrialJobs=true; payload.capabilities.industrialBox=true; payload.capabilities.industrialBoxSingleUnit=true; payload.capabilities.industrialBoxResume=true
  if box:isActive() or box:isLocked() then
   local p=box:pose(); payload.state=box:state(); payload.job=box:job(); payload.industrial=box:summary(); payload.fuel=box:fuel(); payload.fuelLimit=box:limit()
   if p then payload.navPos={x=p.x,y=p.y,z=p.z}; payload.navFrame=p.frame; payload.heading=Box.headingName(p.heading) end
  end
  if boxLastJob then payload.lastJob=boxLastJob end
 end
 return baseNewPacket(cfg,state,kind,target,payload,ttl)
end

local function worker()
 local resumed=false
 while true do
  if not box:isActive() then os.pullEvent("fleet_box_wake") else
   if box:consumeResume() and not resumed then resumed=true; event("RESUME") end
   local timer=os.startTimer(math.max(0.05,tonumber(box:delay()) or 0.15)); while true do local e,a=os.pullEvent(); if e=="timer" and a==timer then break elseif e=="fleet_box_wake" then break end end
   if box:isActive() then local r=box:step(); if r then if r.event=="RETURN" then event("RETURN",nil,r.reason) elseif r.event=="DONE" then event("DONE",true,r.reason) elseif r.event=="FAIL" then event("FAIL",false,r.reason) end end end
  end
 end
end

parallel.waitForAny=function(...)
 local f={...}; f[#f+1]=worker; return baseWaitForAny((table.unpack or unpack)(f))
end

local loader,e=loadfile(INNER_PATH,"t",_ENV); if not loader then error("Fleet guarded wrapper missing: "..tostring(e),0) end
local ok,runErr=pcall(loader)
parallel.waitForAny=baseWaitForAny; turtle.getFuelLevel=rawFuel
if not ok then error(runErr,0) end
