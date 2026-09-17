local Industrial=require("lib.fleet.industrial")
local Box={}; Box.__index=Box
Box.VERSION="0.23.0-alpha.6.2"; Box.TYPE=Industrial.TYPE_EXCAVATE; Box.DEFAULT_PATH="/data/fleet_industrial_job.json"
local DIR={[0]={x=0,z=-1},[1]={x=1,z=0},[2]={x=0,z=1},[3]={x=-1,z=0}}
local H={[0]="N",[1]="E",[2]="S",[3]="W"}

local function parent(path) local d=fs.getDir(path); if d~="" and not fs.exists(d) then fs.makeDir(d) end end
local function readJson(path)
 if not fs.exists(path) or fs.isDir(path) then return nil end; local f=fs.open(path,"r"); if not f then return nil end
 local raw=f.readAll(); f.close(); local ok,v=pcall(textutils.unserializeJSON,raw); return ok and type(v)=="table" and v or nil
end
local function writeJson(path,v)
 parent(path); local ok,raw=pcall(textutils.serializeJSON,v); if not ok then return false,"serialize" end
 local n,b=path..".tmp",path..".bak"; if fs.exists(n) then pcall(fs.delete,n) end; local f=fs.open(n,"w"); if not f then return false,"open" end
 local wrote,e=pcall(function() f.write(raw) end); pcall(function() f.close() end); if not wrote then pcall(fs.delete,n); return false,tostring(e) end
 if fs.exists(b) then pcall(fs.delete,b) end; if fs.exists(path) and not pcall(fs.move,path,b) then pcall(fs.delete,n); return false,"backup" end
 if not pcall(fs.move,n,path) then if fs.exists(b) and not fs.exists(path) then pcall(fs.move,b,path) end; return false,"commit" end
 if fs.exists(b) then pcall(fs.delete,b) end; return true
end
local function pose(p) p=type(p)=="table" and p or {}; return {x=tonumber(p.x) or 0,y=tonumber(p.y) or 0,z=tonumber(p.z) or 0,heading=math.floor(tonumber(p.heading) or 0)%4,frame=tostring(p.frame or "")} end
local function name(v) return string.lower(tostring(type(v)=="table" and v.name or "")) end
local function pickaxe(v) return string.lower(tostring(v or "")):find("pickaxe",1,true)~=nil end

function Box.new(o)
 o=type(o)=="table" and o or {}; local s=setmetatable({},Box); s.path=tostring(o.checkpointPath or Box.DEFAULT_PATH)
 s.now=type(o.nowMs)=="function" and o.nowMs or function() return os.epoch and os.epoch("utc") or math.floor(os.clock()*1000) end
 s.rawFuel=o.getFuelLevel or turtle.getFuelLevel; s.rawLimit=o.getFuelLimit or turtle.getFuelLimit; s.active=false; s.locked=false; s.resume=false
 local v=readJson(s.path); if type(v)=="table" and tostring(v.type or "")==Box.TYPE then local cp=Industrial.normalizeCheckpoint(v); if cp then
  s.cp=cp; cp.runtime=type(cp.runtime)=="table" and cp.runtime or {}
  if cp.phase=="WORK" or cp.phase=="RETURN" then
   if type(cp.runtime.intent)=="table" then s.locked=true; cp.runtime.recoveryRequired=true; writeJson(s.path,cp)
   else s.active=true; s.resume=true; cp.stats.recoveries=(tonumber(cp.stats.recoveries) or 0)+1; cp.runtime.recoveryRequired=false; writeJson(s.path,cp) end
  end
 end end; return s
end
function Box:isActive() return self.active end; function Box:isLocked() return self.locked end
function Box:delay() return self.cp and self.cp.spec and tonumber(self.cp.spec.stepDelay) or Industrial.DEFAULT_DELAY end
function Box:consumeResume() local v=self.resume; self.resume=false; return v end
function Box:pose() return self.cp and pose(self.cp.pose) or nil end
function Box:fuel() local ok,v=pcall(self.rawFuel); return ok and v or nil end
function Box:limit() if type(self.rawLimit)~="function" then return nil end; local ok,v=pcall(self.rawLimit); return ok and v or nil end
function Box:save()
 if not self.cp then return false,"missing" end; self.cp.savedAt=self.now(); local cp,e=Industrial.normalizeCheckpoint(self.cp); if not cp then return false,e end
 self.cp=cp; return writeJson(self.path,cp)
end
function Box:inventory() return Industrial.inventorySummary(function(i) local ok,n=pcall(turtle.getItemCount,i); return ok and n or 0 end) end
function Box:equipped(side) local f=side=="left" and turtle.getEquippedLeft or turtle.getEquippedRight; if type(f)~="function" then return nil end; local ok,v=pcall(f); return ok and type(v)=="table" and v or nil end
function Box:toolSide()
 if peripheral and type(peripheral.hasType)=="function" then local a,b=pcall(peripheral.hasType,"left","modem"); if a and b then return "right" end; a,b=pcall(peripheral.hasType,"right","modem"); if a and b then return "left" end end
 if name(self:equipped("left")):find("modem",1,true) then return "right" end; if name(self:equipped("right")):find("modem",1,true) then return "left" end; return "left"
end
function Box:ensurePickaxe()
 local side=self:toolSide(); if pickaxe(name(self:equipped(side))) then return true end; local old=1; local ok,sel=pcall(turtle.getSelectedSlot); if ok and type(sel)=="number" then old=sel end
 for i=5,16 do local a,d=pcall(turtle.getItemDetail,i); if a and type(d)=="table" and pickaxe(d.name) then turtle.select(i); local f=side=="left" and turtle.equipLeft or turtle.equipRight; local good,e=f(); turtle.select(old); return good==true,good and nil or tostring(e or "equip") end end
 turtle.select(old); return false,"pickaxe_missing"
end
function Box:workSlot() for i=5,16 do local ok,n=pcall(turtle.getItemCount,i); if ok and tonumber(n)==0 then turtle.select(i); return true end end; return false end
function Box:refuel(target)
 local fuel=self:fuel(); if fuel=="unlimited" then return true,fuel end; fuel=tonumber(fuel); if not fuel then return false end; target=math.floor(tonumber(target) or 0); if fuel>=target then return true,fuel end
 local old=1; local ok,sel=pcall(turtle.getSelectedSlot); if ok and type(sel)=="number" then old=sel end
 for i=1,4 do if fuel>=target then break end; turtle.select(i); while fuel<target do local a,n=pcall(turtle.getItemCount,i); if not a or not n or n<=0 then break end; local b,u=pcall(turtle.refuel,0); if not b or u~=true then break end; b,u=pcall(turtle.refuel,1); if not b or u~=true then break end; local nf=self:fuel(); if nf=="unlimited" then fuel=target; break end; fuel=tonumber(nf) or fuel end end
 turtle.select(old); local after=self:fuel(); if after=="unlimited" then return true,after end; return tonumber(after) and tonumber(after)>=target,tonumber(after)
end
function Box:turnTo(want)
 want=math.floor(tonumber(want) or 0)%4; while self.cp.pose.heading~=want do local d=(want-self.cp.pose.heading)%4; local left=d==3; local ok,e=(left and turtle.turnLeft or turtle.turnRight)(); if not ok then return false,tostring(e or "turn") end; self.cp.pose.heading=(self.cp.pose.heading+(left and 3 or 1))%4; local s,se=self:save(); if not s then return false,"turn_checkpoint:"..tostring(se) end end; return true
end
function Box:dig(kind)
 local detect,dig=turtle.detect,turtle.dig; if kind=="up" then detect,dig=turtle.detectUp,turtle.digUp elseif kind=="down" then detect,dig=turtle.detectDown,turtle.digDown end
 local ok,b=pcall(detect); if not ok or b~=true then return true end; local t,e=self:ensurePickaxe(); if not t then return false,e end; if not self:workSlot() then return false,"inventory_full" end
 local a,d,de=pcall(dig); if not a or d~=true then return false,"dig_failed:"..tostring(de or d or "blocked") end; self.cp.stats.digs=(tonumber(self.cp.stats.digs) or 0)+1; return true
end
function Box:intent(kind,detail) self.cp.runtime.intent={kind=kind,detail=detail,savedAt=self.now()}; return self:save() end
function Box:move(kind,dig,detail)
 if dig then local ok,e=self:dig(kind); if not ok then return false,e end end; local s,se=self:intent(kind,detail); if not s then return false,"intent:"..tostring(se) end
 local f=kind=="forward" and turtle.forward or kind=="up" and turtle.up or turtle.down; local ok,e=f(); if not ok then self.cp.runtime.intent=nil; self:save(); return false,tostring(e or "move") end
 if kind=="forward" then local d=DIR[self.cp.pose.heading]; self.cp.pose.x=self.cp.pose.x+d.x; self.cp.pose.z=self.cp.pose.z+d.z elseif kind=="up" then self.cp.pose.y=self.cp.pose.y+1 else self.cp.pose.y=self.cp.pose.y-1 end
 self.cp.stats.moves=(tonumber(self.cp.stats.moves) or 0)+1; self.cp.runtime.intent=nil; return true
end
function Box:localMove(dx,dy,dz,dig,detail)
 dx,dy,dz=tonumber(dx) or 0,tonumber(dy) or 0,tonumber(dz) or 0; if (dx~=0 and 1 or 0)+(dy~=0 and 1 or 0)+(dz~=0 and 1 or 0)~=1 or math.abs(dx+dy+dz)~=1 then return false,"non_adjacent" end
 if dy~=0 then return self:move(dy>0 and "up" or "down",dig,detail) end; local start=math.floor(tonumber(self.cp.runtime.startHeading) or self.cp.origin.heading or 0)%4; local want=dz==1 and start or dz==-1 and (start+2)%4 or dx==1 and (start+1)%4 or (start+3)%4
 local ok,e=self:turnTo(want); if not ok then return false,e end; return self:move("forward",dig,detail)
end
function Box:beginReturn(reason) if reason and reason~="" and tostring(self.cp.reason or "")=="" then self.cp.reason=tostring(reason) end; self.cp.phase="RETURN"; self.cp.runtime.intent=nil; self:save(); return true end
function Box:start(args,rid,origin)
 if self.active then return false,"job_busy" end; if self.locked then return false,"recovery_required" end; args=type(args)=="table" and args or {}
 local plan,e=Industrial.plan({type=Box.TYPE,width=args.width,length=args.length,height=args.height or args.layers,stepDelay=args.stepDelay}); if not plan then return false,"industrial_preflight:"..tostring(e) end
 local ok,te=self:ensurePickaxe(); if not ok then return false,te end; local inv=self:inventory(); if not inv or inv.shouldUnload then return false,"inventory_pressure_start" end
 local safe=plan.volume*2+plan.fuelReserve; local fuelOk,fuel=self:refuel(safe); if not fuelOk then return false,"insufficient_fuel:"..tostring(fuel or "?").."/"..safe end
 local cp,ce=Industrial.newCheckpoint(tostring(args.jobId or rid or ("box-"..self.now())),plan.spec,pose(origin)); if not cp then return false,ce end
 cp.runtime={startHeading=cp.origin.heading,intent=nil,recoveryRequired=false,safeFuelRequired=safe}; cp.phase="WORK"; cp.reason=""; self.cp=cp; self.active=true; self.locked=false; self.resume=false
 local saved,se=self:save(); if not saved then self.active=false; return false,"checkpoint:"..tostring(se) end; return true,"job_started:"..plan.volume
end
function Box:cancel(reason) if not self.active then return false,"no_active_job" end; self:beginReturn(reason or "OPERATOR_ABORT"); return true,"returning" end
function Box:workStep()
 local done=math.floor(tonumber(self.cp.progress.completed) or 0); local volume=math.floor(tonumber(self.cp.plan.volume) or 0); if done>=volume then self:beginReturn(); return {event="RETURN"} end
 local inv=self:inventory(); if inv and inv.shouldUnload then self:beginReturn("INVENTORY_PRESSURE"); return {event="RETURN",reason=self.cp.reason} end
 local fuel=self:fuel(); if fuel~="unlimited" then fuel=tonumber(fuel); local reserve=tonumber(self.cp.plan.fuelReserve) or 64; if not fuel or fuel<done+2+reserve then self:beginReturn("LOW_FUEL_RESERVE"); return {event="RETURN",reason=self.cp.reason} end end
 local dx,dy,dz=0,0,1; if done>0 then local a,b=Industrial.cellAt(self.cp.spec,done),Industrial.cellAt(self.cp.spec,done+1); if not a or not b then self:beginReturn("PLAN_CURSOR_ERROR"); return {event="RETURN",reason=self.cp.reason} end; dx,dy,dz=b.x-a.x,b.y-a.y,b.z-a.z end
 local moved,me=self:localMove(dx,dy,dz,true,"work:"..(done+1)); if not moved then self:beginReturn(me); return {event="RETURN",reason=self.cp.reason} end
 self.cp.progress.completed=done+1; self.cp.progress.cursor=done+1; local cell=Industrial.cellAt(self.cp.spec,done+1); self.cp.progress.layer=cell and math.max(0,-cell.y) or 0
 local saved,se=self:save(); if not saved then self.active=false; self.locked=true; return {event="FAIL",reason="checkpoint_after_move:"..tostring(se),locked=true} end
 if self.cp.progress.completed>=volume then self:beginReturn(); return {event="RETURN"} end; inv=self:inventory(); if inv and inv.shouldUnload then self:beginReturn("INVENTORY_PRESSURE"); return {event="RETURN",reason=self.cp.reason} end; return {event="PROGRESS"}
end
function Box:returnStep()
 local done=math.floor(tonumber(self.cp.progress.completed) or 0); local ret=math.floor(tonumber(self.cp.progress.returned) or 0)
 if ret>=done then
  local start=math.floor(tonumber(self.cp.runtime.startHeading) or self.cp.origin.heading or 0)%4; local ok,e=self:turnTo(start); if not ok then self.cp.phase="FAILED"; self.cp.reason="return_heading:"..tostring(e); self.active=false; self.locked=true; self:save(); return {event="FAIL",reason=self.cp.reason,locked=true} end
  local p,o=self.cp.pose,self.cp.origin; local same=math.abs(p.x-o.x)<0.01 and math.abs(p.y-o.y)<0.01 and math.abs(p.z-o.z)<0.01; if not same then self.cp.phase="FAILED"; self.cp.reason="origin_mismatch"; self.active=false; self.locked=true; self:save(); return {event="FAIL",reason=self.cp.reason,locked=true} end
  local success=tostring(self.cp.reason or "")==""; self.cp.phase=success and "DONE" or "FAILED"; self.active=false; self.locked=false; self:save(); return {event=success and "DONE" or "FAIL",success=success,reason=success and "complete" or self.cp.reason}
 end
 local idx=done-ret; local dx,dy,dz=0,0,-1; if idx>1 then local a,b=Industrial.cellAt(self.cp.spec,idx),Industrial.cellAt(self.cp.spec,idx-1); if not a or not b then self.cp.phase="FAILED"; self.cp.reason="return_cursor_error"; self.active=false; self.locked=true; self:save(); return {event="FAIL",reason=self.cp.reason,locked=true} end; dx,dy,dz=b.x-a.x,b.y-a.y,b.z-a.z end
 local moved,me=self:localMove(dx,dy,dz,false,"return:"..(ret+1)); if not moved then self.cp.phase="FAILED"; self.cp.reason="return_blocked:"..tostring(me); self.active=false; self.locked=true; self.cp.runtime.intent=nil; self:save(); return {event="FAIL",reason=self.cp.reason,locked=true} end
 self.cp.progress.returned=ret+1; local saved,se=self:save(); if not saved then self.active=false; self.locked=true; return {event="FAIL",reason="return_checkpoint:"..tostring(se),locked=true} end; return {event="PROGRESS"}
end
function Box:step() if not self.active or not self.cp then return nil end; if self.cp.phase=="WORK" then return self:workStep() elseif self.cp.phase=="RETURN" then return self:returnStep() end; self.active=false end
function Box:job()
 if not self.cp then return nil end; local p=self.cp.progress or {}; local v=math.floor(tonumber(self.cp.plan and self.cp.plan.volume) or 0)
 return {id=self.cp.jobId,type=self.cp.type,phase=self.cp.phase,completed=math.floor(tonumber(p.completed) or 0),returned=math.floor(tonumber(p.returned) or 0),volume=v,outbound=math.floor(tonumber(p.completed) or 0),distance=v,width=self.cp.spec.width,length=self.cp.spec.length,height=self.cp.spec.layers,delay=self.cp.spec.stepDelay,reason=tostring(self.cp.reason or ""),recoveries=tonumber(self.cp.stats.recoveries) or 0,recoveryRequired=self.locked}
end
function Box:summary()
 if not self.cp then return nil end; local p=self.cp.progress or {}; return {engineVersion=Industrial.VERSION,executorVersion=Box.VERSION,checkpointSchema=Industrial.CHECKPOINT_SCHEMA,type=self.cp.type,phase=self.cp.phase,completed=p.completed,returned=p.returned,volume=self.cp.plan.volume,fuelRequired=(self.cp.runtime and self.cp.runtime.safeFuelRequired) or self.cp.plan.fuelRequired,fuelReserve=self.cp.plan.fuelReserve,checkpoint=self.path,inventory=self:inventory(),recoveryRequired=self.locked}
end
function Box:state() if self.locked then return "JOB:RECOVERY_REQUIRED" end; if not self.cp then return "IDLE" end; local p=self.cp.progress or {}; if self.active and self.cp.phase=="WORK" then return string.format("JOB:BOX %d/%d",p.completed or 0,self.cp.plan.volume or 0) end; if self.active then return string.format("JOB:BOX RETURN %d/%d",p.returned or 0,p.completed or 0) end; return self.cp.phase=="DONE" and "JOB_DONE" or self.cp.phase=="FAILED" and "JOB_FAILED" or "IDLE" end
function Box.headingName(v) return H[math.floor(tonumber(v) or 0)%4] or "?" end
return Box
