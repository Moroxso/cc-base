local Common = require("lib.fleet.common")

local VERSION = "0.23.0-alpha.5"
local CONFIG_PATH = "/data/fleet_operator.json"
local CACHE_PATH = "/data/fleet_units_cache.json"
local STATE_PATH = "/data/fleet_scheduler_state.json"
local HISTORY_PATH = "/data/fleet_job_history.json"

local UNIT_STALE_MS = 30000
local JOB_STALE_MS = 15000
local RETRY_TICK = 0.10
local RETRY_DELAYS_MS = {400, 1100, 2400, 4200}
local PENDING_TTL_MS = 9000
local DISCOVERY_DIRECT_MS = 10000
local DISCOVERY_MESH_MS = 45000
local CACHE_FLUSH_MS = 2000
local STATE_FLUSH_MS = 1000
local GOVERNOR_MS = 5000
local MAX_HISTORY = 20
local DISPATCH_BUDGET = 3

local function ensureParent(path)
    local dir=fs.getDir(path)
    if dir~="" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f=fs.open(path,"r")
    if not f then return nil end
    local raw=f.readAll()
    f.close()
    local ok,value=pcall(textutils.unserializeJSON,raw)
    return ok and type(value)=="table" and value or nil
end

local function writeJson(path,value)
    ensureParent(path)
    local ok,raw=pcall(textutils.serializeJSON,value)
    if not ok then return false end
    local tmp=path..".tmp"
    if fs.exists(tmp) then pcall(fs.delete,tmp) end
    local f=fs.open(tmp,"w")
    if not f then return false end
    f.write(raw)
    f.close()
    if fs.exists(path) then pcall(fs.delete,path) end
    fs.move(tmp,path)
    return true
end

local function normalizeTransport(value)
    value=string.upper(tostring(value or "AUTO"))
    if value~="DIRECT" and value~="MESH" then value="AUTO" end
    return value
end

local config=readJson(CONFIG_PATH)
if type(config)~="table" or type(config.fleetId)~="string" or type(config.key)~="string" then
    error("Fleet operator config missing. Run Fleet Control once first.",0)
end
config.schema=math.max(5,tonumber(config.schema) or 0)
config.transportMode=normalizeTransport(config.transportMode)
config.relay=config.relay~=false

local mesh={bootId=Common.randomHex(12),seq=0}
local seen=Common.newSeenCache()
local units={}
local pending={}
local commandSeq=0
local currentRun=nil
local history={}
local cacheDirty=false
local stateDirty=false
local appRunning=true
local message="Scheduler ready"
local appStartedAt=Common.nowMs()

local function loadCache()
    local raw=readJson(CACHE_PATH)
    if type(raw)~="table" then return end
    for key,value in pairs(raw) do
        local id=tonumber(type(value)=="table" and value.id or key)
        if id and type(value)=="table" then
            value.id=id
            value.lastSeen=tonumber(value.lastSeen) or 0
            value.capabilities=type(value.capabilities)=="table" and value.capabilities or {}
            value.route=tostring(value.route or "?")
            value.rttMs=tonumber(value.rttMs)
            units[id]=value
        end
    end
end

local function saveCache()
    local out={}
    for id,u in pairs(units) do
        out[tostring(id)]={
            id=id,name=u.name,role=u.role,state=u.state,linkState=u.linkState,
            fuel=u.fuel,version=u.version,lastSeen=u.lastSeen,hops=u.hops,route=u.route,rttMs=u.rttMs,
            job=u.job,jobProgressSeen=u.jobProgressSeen,navPos=u.navPos,heading=u.heading,
            capabilities=u.capabilities,
        }
    end
    cacheDirty=false
    return writeJson(CACHE_PATH,out)
end

local function loadHistory()
    local raw=readJson(HISTORY_PATH)
    if type(raw)=="table" then history=raw end
end

local function saveHistory()
    while #history>MAX_HISTORY do table.remove(history,1) end
    return writeJson(HISTORY_PATH,history)
end

local function loadState()
    local raw=readJson(STATE_PATH)
    if type(raw)=="table" and raw.schema==1 and type(raw.run)=="table" and not raw.run.finished then
        currentRun=raw.run
        currentRun.resumeAt=Common.nowMs()
        currentRun.healthPenalty=tonumber(currentRun.healthPenalty) or 0
        if type(currentRun.units)=="table" then
            for _,r in pairs(currentRun.units) do
                local state=tostring(r.state or "")
                if state=="DISPATCHED" or state=="RUNNING" or state=="RETURN" or state=="STALLED" or state=="CANCELING" then
                    r.resumeGuard=true
                end
            end
        end
        message="Recovered scheduler state; reconciling units"
    end
end

local function saveState()
    stateDirty=false
    if not currentRun or currentRun.finished then
        if fs.exists(STATE_PATH) then pcall(fs.delete,STATE_PATH) end
        return true
    end
    return writeJson(STATE_PATH,{schema=1,savedAt=Common.nowMs(),run=currentRun})
end

loadCache()
loadHistory()
loadState()

local function ensureUnit(id)
    local u=units[id]
    if not u then
        u={id=id,name="Unit-"..tostring(id),role="ASSAULT",state="?",linkState="?",fuel="?",version="?",lastSeen=0,hops="?",route="?",capabilities={}}
        units[id]=u
    end
    return u
end

local function sendPacket(kind,target,payload,ttl)
    local packet,err=Common.newPacket(config,mesh,kind,target,payload,ttl)
    if not packet then return false,err end
    Common.markSeen(seen,Common.packetId(packet))
    return Common.broadcast(packet)
end

local function packetHops(packet)
    return math.max(0,Common.DEFAULT_TTL-math.max(0,tonumber(packet.ttl) or 0))
end

local function markRoute(u,packet,rtt)
    local hops=packetHops(packet)
    u.hops=hops
    u.route=hops==0 and "DIRECT" or ("MESH/"..tostring(hops))
    if rtt then u.rttMs=math.floor(rtt+0.5) end
    cacheDirty=true
end

local function routeTtl(attempt)
    local mode=config.transportMode
    if mode=="DIRECT" then return 0,"DIRECT" end
    if mode=="MESH" then return Common.DEFAULT_TTL,"MESH" end
    if attempt<=1 then return 0,"DIRECT" end
    return Common.DEFAULT_TTL,"MESH"
end

local function sendDiscovery(meshScan)
    local ttl
    if config.transportMode=="DIRECT" then ttl=0
    elseif config.transportMode=="MESH" then ttl=Common.DEFAULT_TTL
    elseif meshScan then ttl=Common.DEFAULT_TTL else ttl=0 end
    sendPacket("discover","*",{operator=os.getComputerID(),app="scheduler",version=VERSION,transport=config.transportMode},ttl)
end

local function sendBeacon()
    local ttl=config.transportMode=="MESH" and Common.DEFAULT_TTL or 0
    sendPacket("operator_status","*",{operator=os.getComputerID(),app="scheduler",version=VERSION,transport=config.transportMode},ttl)
end

local function relay(packet)
    if config.transportMode~="MESH" or not config.relay or packet.ttl<=0 then return end
    local forwarded=Common.forwardPacket(packet,config.key)
    if forwarded then Common.broadcast(forwarded) end
end

local function runUnitRecord(id)
    if not currentRun or type(currentRun.units)~="table" then return nil end
    return currentRun.units[tostring(id)]
end

local function countRunStates()
    local queued,active,done,failed,canceled,stalled=0,0,0,0,0,0
    if not currentRun or type(currentRun.units)~="table" then return queued,active,done,failed,canceled,stalled end
    for _,r in pairs(currentRun.units) do
        local s=tostring(r.state or "")
        if s=="QUEUED" then queued=queued+1
        elseif s=="DISPATCHED" or s=="RUNNING" or s=="RETURN" or s=="STALLED" or s=="CANCELING" then
            active=active+1
            if s=="STALLED" then stalled=stalled+1 end
        elseif s=="DONE" then done=done+1
        elseif s=="CANCELED" then canceled=canceled+1
        else failed=failed+1 end
    end
    return queued,active,done,failed,canceled,stalled
end

local function percentile(values,p)
    if #values==0 then return nil end
    table.sort(values)
    local index=math.max(1,math.min(#values,math.ceil(#values*p)))
    return values[index]
end

local function finalizeRun()
    if not currentRun or currentRun.finished then return end
    local queued,active,done,failed,canceled=countRunStates()
    if queued>0 or active>0 then return end
    local now=Common.nowMs()
    currentRun.finished=true
    currentRun.finishedAt=now

    local durations={}
    local firstDone=nil
    local lastDone=nil
    for _,r in pairs(currentRun.units) do
        if r.state=="DONE" and tonumber(r.doneAt) then
            local start=tonumber(r.startAt) or tonumber(r.dispatchAt) or currentRun.startedAt
            durations[#durations+1]=math.max(0,r.doneAt-start)
            firstDone=not firstDone and r.doneAt or math.min(firstDone,r.doneAt)
            lastDone=not lastDone and r.doneAt or math.max(lastDone,r.doneAt)
        end
    end
    local elapsed=math.max(1,now-(tonumber(currentRun.startedAt) or now))
    local entry={
        id=currentRun.id,finishedAt=now,distance=currentRun.distance,delay=currentRun.delay,
        total=currentRun.total,done=done,failed=failed,canceled=canceled,
        transport=currentRun.transport,concurrency=currentRun.concurrency,
        durationMs=elapsed,p50Ms=percentile(durations,0.50),p95Ms=percentile(durations,0.95),
        firstDoneAt=firstDone,lastDoneAt=lastDone,
        excavationBps=(done*currentRun.distance)/(elapsed/1000),
        movementBps=(done*currentRun.distance*2)/(elapsed/1000),
    }
    history[#history+1]=entry
    saveHistory()
    if fs.exists(STATE_PATH) then pcall(fs.delete,STATE_PATH) end
    stateDirty=false
    message=string.format("Run done %d/%d fail:%d",done,currentRun.total,failed+canceled)
end

local function finishRunUnit(id,success,reason)
    local r=runUnitRecord(id)
    if not r then return end
    if r.state=="DONE" or r.state=="FAILED" or r.state=="CANCELED" then return end
    r.doneAt=Common.nowMs()
    r.reason=tostring(reason or "")
    if currentRun.canceled then r.state="CANCELED" else r.state=success and "DONE" or "FAILED" end
    stateDirty=true
    finalizeRun()
end

local function markRunning(id,job,now)
    local r=runUnitRecord(id)
    if not r or not currentRun or tostring(job and job.id or "")~=tostring(currentRun.id) then return end
    if r.state=="DONE" or r.state=="FAILED" or r.state=="CANCELED" then return end
    if not r.startAt then r.startAt=now end
    r.lastProgressAt=now
    r.resumeGuard=false
    r.outbound=tonumber(job.outbound) or r.outbound or 0
    r.returned=tonumber(job.returned) or r.returned or 0
    r.phase=tostring(job.phase or r.phase or "OUT")
    r.state=job.stalled and "STALLED" or (r.phase=="RETURN" and "RETURN" or "RUNNING")
    if job.stalled then currentRun.healthPenalty=(currentRun.healthPenalty or 0)+1 end
    stateDirty=true
end

local function transmit(item)
    local nextAttempt=(item.attempts or 0)+1
    local ttl,route=routeTtl(nextAttempt)
    local ok,err=sendPacket("command",item.target,item.payload,ttl)
    item.attempts=nextAttempt
    item.lastRoute=route
    item.lastSentAt=Common.nowMs()
    item.nextRetry=item.lastSentAt+RETRY_DELAYS_MS[math.min(item.attempts,#RETRY_DELAYS_MS)]
    if not ok then message="send failed: "..tostring(err) end
end

local function issueToUnit(command,args,unitId,purpose)
    commandSeq=commandSeq+1
    local now=Common.nowMs()
    local rid=string.format("%d:%s:%d",os.getComputerID(),mesh.bootId,commandSeq)
    local payload={
        operator=os.getComputerID(),operatorBoot=mesh.bootId,commandSeq=commandSeq,
        issuedAt=now,requestId=rid,command=command,args=type(args)=="table" and args or {},
    }
    local item={
        target=unitId,payload=payload,purpose=purpose,unitId=unitId,
        attempts=0,firstSentAt=now,nextRetry=0,expires=now+PENDING_TTL_MS,
    }
    pending[rid]=item
    transmit(item)
    return rid
end

local function retryPending()
    local now=Common.nowMs()
    for rid,item in pairs(pending) do
        if now>=item.expires then
            pending[rid]=nil
            if item.purpose=="START" then
                local r=runUnitRecord(item.unitId)
                local u=units[item.unitId]
                local job=u and u.job
                if r and type(job)=="table" and currentRun and tostring(job.id or "")==tostring(currentRun.id) then
                    markRunning(item.unitId,job,now)
                elseif r and r.state=="DISPATCHED" then
                    currentRun.healthPenalty=(currentRun.healthPenalty or 0)+1
                    finishRunUnit(item.unitId,false,"dispatch_timeout")
                end
            end
            message="TIMEOUT #"..tostring(item.unitId).." "..tostring(item.payload.command)
        elseif now>=item.nextRetry and item.attempts<#RETRY_DELAYS_MS then
            transmit(item)
        end
    end
end

local function onlineAssaults()
    local now=Common.nowMs()
    local list={}
    for _,u in pairs(units) do
        if tostring(u.role)=="ASSAULT" and now-(tonumber(u.lastSeen) or 0)<=UNIT_STALE_MS then list[#list+1]=u end
    end
    table.sort(list,function(a,b) return a.id<b.id end)
    return list
end

local function concurrencyLimit()
    if not currentRun then return 0 end
    local spec=tonumber(currentRun.concurrency) or 0
    if spec==0 then return currentRun.total end
    if spec==-1 then return math.max(1,math.floor(tonumber(currentRun.autoTarget) or 1)) end
    return math.max(1,math.min(currentRun.total,math.floor(spec)))
end

local function dispatchQueued(budget)
    if not currentRun or currentRun.finished or currentRun.canceled then return end
    local _,active=countRunStates()
    local limit=concurrencyLimit()
    local room=math.max(0,limit-active)
    local allowed=math.min(room,budget or DISPATCH_BUDGET)
    if allowed<=0 then return end
    local now=Common.nowMs()
    for _,id in ipairs(currentRun.order or {}) do
        if allowed<=0 then break end
        local r=currentRun.units[tostring(id)]
        if r and r.state=="QUEUED" then
            r.state="DISPATCHED"
            r.dispatchAt=now
            r.route="?"
            r.resumeGuard=false
            issueToUnit("job_tunnel_roundtrip",{
                jobId=currentRun.id,distance=currentRun.distance,stepDelay=currentRun.delay,
            },id,"START")
            allowed=allowed-1
            stateDirty=true
        end
    end
end

local function governorStep()
    if not currentRun or currentRun.finished or tonumber(currentRun.concurrency)~=-1 then return end
    local now=Common.nowMs()
    if now-(tonumber(currentRun.lastGovernorAt) or 0)<GOVERNOR_MS then return end
    currentRun.lastGovernorAt=now
    local queued,active,_,_,_,stalled=countRunStates()
    local target=math.max(1,math.floor(tonumber(currentRun.autoTarget) or 1))
    if stalled>0 or (tonumber(currentRun.healthPenalty) or 0)>0 then
        target=math.max(2,target-2)
        currentRun.healthPenalty=0
    elseif queued>0 and active>=target then
        target=math.min(currentRun.total,target+2)
    end
    currentRun.autoTarget=target
    stateDirty=true
end

local function reconcileStatus(id,p,now)
    if not currentRun or currentRun.finished then return end
    local r=runUnitRecord(id)
    if not r then return end
    if type(p.job)=="table" and tostring(p.job.id or "")==tostring(currentRun.id) then
        markRunning(id,p.job,now)
        return
    end
    if r.state=="RUNNING" or r.state=="RETURN" or r.state=="STALLED" or r.state=="DISPATCHED" then
        local s=tostring(p.state or "")
        if s=="JOB_DONE" then finishRunUnit(id,true,"status_done")
        elseif s=="JOB_FAILED" then finishRunUnit(id,false,"status_failed")
        elseif r.resumeGuard and currentRun.resumeAt and now-currentRun.resumeAt>8000 and not p.job then
            r.resumeGuard=false
            finishRunUnit(id,false,"resume_no_active_job")
        end
    end
end

local function handlePacket(packet,protocol)
    if protocol~=Common.REDNET_PROTOCOL then return end
    local valid=Common.verify(packet,config.key,config.fleetId)
    if not valid then return end
    local pid=Common.packetId(packet)
    if Common.seen(seen,pid) then return end
    Common.markSeen(seen,pid)
    local now=Common.nowMs()

    if packet.type=="status" then
        local p=packet.payload
        local id=tonumber(p.unit or packet.origin)
        if id then
            local u=ensureUnit(id)
            u.name=tostring(p.name or u.name)
            u.role=tostring(p.role or u.role)
            u.state=tostring(p.state or u.state)
            u.linkState=tostring(p.linkState or u.linkState)
            u.fuel=p.fuel
            u.version=p.version or u.version
            u.lastSeen=now
            u.job=p.job
            u.jobProgressSeen=type(p.job)=="table" and now or u.jobProgressSeen
            u.navPos=p.navPos
            u.heading=p.heading
            u.capabilities=p.capabilities or u.capabilities or {}
            markRoute(u,packet)
            reconcileStatus(id,p,now)
        end

    elseif packet.type=="job_event" then
        local p=packet.payload
        local id=tonumber(p.unit or packet.origin)
        if id then
            local u=ensureUnit(id)
            u.lastSeen=now
            markRoute(u,packet)
            local event=tostring(p.event or "")
            if currentRun and tostring(p.id or "")==tostring(currentRun.id) then
                if event=="DONE" then
                    u.job=nil; u.state="JOB_DONE"
                    finishRunUnit(id,true,p.reason or "complete")
                elseif event=="FAIL" then
                    u.job=nil; u.state="JOB_FAILED"
                    finishRunUnit(id,false,p.reason or "failed")
                else
                    local job={id=p.id,type=p.type,phase=p.phase,outbound=p.outbound,returned=p.returned,distance=p.distance,reason=p.reason,delay=p.delay,recoveries=p.recoveries,stalled=event=="STALLED" or p.stalled}
                    u.job=job
                    markRunning(id,job,now)
                end
            end
        end

    elseif packet.type=="result" then
        local p=packet.payload
        local id=tonumber(p.unit or packet.origin)
        local rid=tostring(p.requestId or "")
        local item=pending[rid]
        if id then
            local u=ensureUnit(id)
            u.lastSeen=now
            local rtt=item and (now-item.firstSentAt) or nil
            markRoute(u,packet,rtt)
            if type(p.job)=="table" then u.job=p.job; markRunning(id,p.job,now) end
        end
        if item then
            pending[rid]=nil
            local r=runUnitRecord(item.unitId)
            if r then
                r.rttMs=math.floor(now-item.firstSentAt+0.5)
                r.route=units[item.unitId] and units[item.unitId].route or item.lastRoute
                if item.purpose=="START" and not p.ok and r.state=="DISPATCHED" then
                    finishRunUnit(item.unitId,false,tostring(p.detail or "start_rejected"))
                end
            end
        end
        message=string.format("#%s %s %s",tostring(id or packet.origin),p.ok and "ACK" or "FAIL",tostring(p.detail or ""))
    end

    relay(packet)
    cacheDirty=true
    os.queueEvent("fleet_scheduler_redraw")
end

local function ask(prompt,default)
    write(prompt..(default~=nil and (" ["..tostring(default).."]") or "")..": ")
    local value=read()
    if value=="" and default~=nil then return tostring(default) end
    return value
end

local function confirm(text)
    term.clear(); term.setCursorPos(1,1)
    print(text)
    print("Y=CONFIRM  N/ESC=CANCEL")
    while true do
        local e,a=os.pullEvent()
        if e=="char" then
            if a:lower()=="y" then return true elseif a:lower()=="n" then return false end
        elseif e=="key" then
            if a==keys.y then return true end
            if a==keys.n or a==keys.escape then return false end
        end
    end
end

local function startTunnel()
    if currentRun and not currentRun.finished then message="A scheduler run is already active"; return end
    sendDiscovery(false)
    term.clear(); term.setCursorPos(1,1)
    print("Scheduled tunnel roundtrip")
    local distance=math.floor(tonumber(ask("Distance blocks",100)) or 0)
    local delay=tonumber(ask("Step delay seconds",0.15)) or 0.15
    local concurrency=math.floor(tonumber(ask("Concurrency 0=ALL -1=AUTO",0)) or 0)
    if distance<1 or distance>4096 then message="Distance must be 1..4096"; return end
    if delay<0.05 or delay>2 then message="Delay must be 0.05..2.0"; return end
    local list=onlineAssaults()
    if #list==0 then message="No online ASSAULT units"; return end
    if concurrency>0 then concurrency=math.min(concurrency,#list) elseif concurrency<-1 then concurrency=-1 end
    local label=concurrency==0 and "ALL" or (concurrency==-1 and "AUTO" or tostring(concurrency))
    if not confirm(string.format("Start %d blocks on %d units?\nConcurrency: %s  Transport: %s",distance,#list,label,config.transportMode)) then message="Run cancelled"; return end

    local now=Common.nowMs()
    local run={
        schema=1,id=string.format("SCH-%d-%d",os.getComputerID(),now),distance=distance,delay=delay,
        total=#list,startedAt=now,transport=config.transportMode,concurrency=concurrency,
        autoTarget=concurrency==-1 and math.min(6,#list) or nil,lastGovernorAt=now,healthPenalty=0,
        units={},order={},canceled=false,finished=false,
    }
    for _,u in ipairs(list) do
        run.order[#run.order+1]=u.id
        run.units[tostring(u.id)]={id=u.id,state="QUEUED",route=u.route or "?"}
    end
    currentRun=run
    stateDirty=true
    saveState()
    message=string.format("Run %s queued: %d units",run.id,#list)
    dispatchQueued(DISPATCH_BUDGET)
end

local function cancelRun()
    if not currentRun or currentRun.finished then message="No active scheduler run"; return end
    if not confirm("Cancel queued work and return active turtles?") then message="Cancel aborted"; return end
    currentRun.canceled=true
    for _,r in pairs(currentRun.units) do
        if r.state=="QUEUED" or r.state=="DISPATCHED" then
            r.state="CANCELED"; r.doneAt=Common.nowMs(); r.reason="operator_cancel"
        elseif r.state=="RUNNING" or r.state=="RETURN" or r.state=="STALLED" then
            r.state="CANCELING"
            issueToUnit("job_cancel",{},r.id,"CANCEL")
        end
    end
    stateDirty=true
    finalizeRun()
    message="Cancel/return dispatched"
end

local function cycleTransport()
    if config.transportMode=="AUTO" then config.transportMode="DIRECT"
    elseif config.transportMode=="DIRECT" then config.transportMode="MESH"
    else config.transportMode="AUTO" end
    writeJson(CONFIG_PATH,config)
    message="Transport: "..config.transportMode
    sendDiscovery(config.transportMode=="MESH")
end

local function showHistory()
    term.clear(); term.setCursorPos(1,1)
    print("Fleet Scheduler History")
    print("Transport: "..config.transportMode)
    if #history==0 then print("No completed runs") end
    local first=math.max(1,#history-4)
    for i=first,#history do
        local h=history[i]
        print(string.format("%s",tostring(h.id or "run")))
        print(string.format(" %d/%d fail:%d  %.1fs",tonumber(h.done) or 0,tonumber(h.total) or 0,(tonumber(h.failed) or 0)+(tonumber(h.canceled) or 0),(tonumber(h.durationMs) or 0)/1000))
        print(string.format(" p50:%s p95:%s blk/s:%.1f",h.p50Ms and string.format("%.1fs",h.p50Ms/1000) or "-",h.p95Ms and string.format("%.1fs",h.p95Ms/1000) or "-",tonumber(h.excavationBps) or 0))
    end
    print("Press any key")
    os.pullEvent("key")
end

local function textAt(y,text,color)
    local w=term.getSize()
    term.setCursorPos(1,y); term.setBackgroundColor(colors.black); term.setTextColor(color or colors.white)
    term.write(string.rep(" ",w)); term.setCursorPos(1,y); term.write(tostring(text):sub(1,w))
end

local function draw()
    local w,h=term.getSize()
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
    term.setCursorPos(1,1); term.setBackgroundColor(colors.orange); term.write(string.rep(" ",w))
    term.setCursorPos(1,1); term.setTextColor(colors.black); term.write("BASE / FLEET SCHEDULER")
    term.setBackgroundColor(colors.black)

    local assaults=#onlineAssaults()
    textAt(2,string.format("v%s  Fleet:%s",VERSION,config.fleetId),colors.lightGray)
    textAt(3,string.format("Transport:%s  online:%d",config.transportMode,assaults),colors.cyan)

    local row=5
    if currentRun then
        local queued,active,done,failed,canceled,stalled=countRunStates()
        local conc=tonumber(currentRun.concurrency) or 0
        local concText=conc==0 and "ALL" or (conc==-1 and ("AUTO/"..tostring(currentRun.autoTarget or "?")) or tostring(conc))
        textAt(row,string.format("Run %s",tostring(currentRun.id):sub(-12)),currentRun.finished and colors.green or colors.yellow)
        textAt(row+1,string.format("Q:%d A:%d D:%d F:%d C:%d",queued,active,done,failed,canceled),stalled>0 and colors.red or colors.white)
        textAt(row+2,string.format("Dist:%d Delay:%.2f Conc:%s",currentRun.distance,currentRun.delay,concText),colors.lightGray)
        row=row+4
    else
        textAt(row,"No scheduler run",colors.lightGray)
        row=row+2
    end

    local list=onlineAssaults()
    local visible=math.max(1,h-row-4)
    for i=1,math.min(#list,visible) do
        local u=list[i]
        local r=runUnitRecord(u.id)
        local s=r and tostring(r.state or "?") or "IDLE"
        local route=tostring((r and r.route) or u.route or "?")
        local extra=""
        if r and (r.state=="RUNNING" or r.state=="RETURN" or r.state=="STALLED") then
            local cur=r.phase=="RETURN" and (r.returned or 0) or (r.outbound or 0)
            extra=" "..tostring(cur).."/"..tostring(currentRun and currentRun.distance or "?")
        end
        textAt(row+i-1,string.format("#%s %-9s %-7s%s",u.id,s,route,extra),r and r.state=="STALLED" and colors.red or colors.white)
    end

    textAt(h-2,message,colors.orange)
    textAt(h-1,"T run C cancel M transport H history Q back",colors.lightGray)
end

local function networkLoop()
    if #Common.openModems()==0 then error("No wireless modem found",0) end
    local retryTimer=os.startTimer(RETRY_TICK)
    local modemTimer=os.startTimer(2)
    local beaconTimer=os.startTimer(0.2)
    local directDiscover=os.startTimer(0.1)
    local meshDiscover=os.startTimer(config.transportMode=="AUTO" and 2.0 or DISCOVERY_MESH_MS/1000)
    local cacheTimer=os.startTimer(CACHE_FLUSH_MS/1000)
    local stateTimer=os.startTimer(STATE_FLUSH_MS/1000)
    local schedulerTimer=os.startTimer(0.1)

    while appRunning do
        local e,a,b,c=os.pullEvent()
        if e=="rednet_message" then
            handlePacket(b,c)
        elseif e=="timer" and a==retryTimer then
            retryPending(); retryTimer=os.startTimer(RETRY_TICK)
        elseif e=="timer" and a==modemTimer then
            Common.openModems(); modemTimer=os.startTimer(2)
        elseif e=="timer" and a==beaconTimer then
            sendBeacon(); beaconTimer=os.startTimer(4)
        elseif e=="timer" and a==directDiscover then
            sendDiscovery(false); directDiscover=os.startTimer(DISCOVERY_DIRECT_MS/1000)
        elseif e=="timer" and a==meshDiscover then
            if config.transportMode~="DIRECT" then sendDiscovery(true) end
            meshDiscover=os.startTimer(DISCOVERY_MESH_MS/1000)
        elseif e=="timer" and a==cacheTimer then
            if cacheDirty then saveCache() end
            cacheTimer=os.startTimer(CACHE_FLUSH_MS/1000)
        elseif e=="timer" and a==stateTimer then
            if stateDirty then saveState() end
            stateTimer=os.startTimer(STATE_FLUSH_MS/1000)
        elseif e=="timer" and a==schedulerTimer then
            governorStep(); dispatchQueued(DISPATCH_BUDGET); finalizeRun()
            schedulerTimer=os.startTimer(0.10)
            os.queueEvent("fleet_scheduler_redraw")
        elseif e=="peripheral" or e=="peripheral_detach" then
            Common.openModems()
        end
    end
end

local function uiLoop()
    draw()
    while true do
        local e,a=os.pullEvent()
        if e=="key" then
            if a==keys.t then startTunnel()
            elseif a==keys.c then cancelRun()
            elseif a==keys.m then cycleTransport()
            elseif a==keys.h then showHistory()
            elseif a==keys.q or a==keys.escape or a==keys.leftShift then
                appRunning=false
                if cacheDirty then saveCache() end
                if stateDirty then saveState() end
                return
            end
            draw()
        elseif e=="fleet_scheduler_redraw" or e=="term_resize" then
            draw()
        end
    end
end

parallel.waitForAny(uiLoop,networkLoop)
