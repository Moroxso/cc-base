local Common = require("lib.fleet.common")

local VERSION = "0.23.0-alpha.4.2"
local CONFIG_PATH = "/data/fleet_operator.json"
local CACHE_PATH = "/data/fleet_units_cache.json"

local UNIT_STALE_MS = 30000
local JOB_STALE_MS = 12000
local RETRY_TIMER_SECONDS = 0.2
local RETRY_DELAYS_MS = {250, 650, 1400}
local PENDING_TTL_MS = 6000
local DISCOVERY_INTERVAL_MS = 12000
local BEACON_INTERVAL_MS = 4000
local CACHE_FLUSH_MS = 2000

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

local config=readJson(CONFIG_PATH)
if type(config)~="table" or type(config.fleetId)~="string" or type(config.key)~="string" then
    error("Fleet operator config missing. Run fleet_control once first.",0)
end
config.relay=config.relay~=false

local mesh={bootId=Common.randomHex(12),seq=0}
local seen=Common.newSeenCache()
local units={}
local commandSeq=0
local pending={}
local cacheDirty=false
local message="Fleet Jobs ready"
local appRunning=true

local function loadCache()
    local raw=readJson(CACHE_PATH)
    if type(raw)~="table" then return end
    for key,value in pairs(raw) do
        local id=tonumber(type(value)=="table" and value.id or key)
        if id and type(value)=="table" then
            value.id=id
            value.lastSeen=tonumber(value.lastSeen) or 0
            value.jobProgressSeen=tonumber(value.jobProgressSeen) or 0
            value.jobSignature=tostring(value.jobSignature or "")
            units[id]=value
        end
    end
end

local function saveCache()
    local out={}
    for id,u in pairs(units) do
        out[tostring(id)]={
            id=id,name=u.name,role=u.role,state=u.state,linkState=u.linkState,
            fuel=u.fuel,version=u.version,lastSeen=u.lastSeen,hops=u.hops,
            job=u.job,jobProgressSeen=u.jobProgressSeen,jobSignature=u.jobSignature,
            navPos=u.navPos,heading=u.heading,capabilities=u.capabilities,
        }
    end
    cacheDirty=false
    return writeJson(CACHE_PATH,out)
end

loadCache()

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

local function ensureUnit(unitId)
    local u=units[unitId]
    if not u then
        u={
            id=unitId,name="Unit-"..tostring(unitId),role="ASSAULT",
            state="?",linkState="?",fuel="?",version="?",lastSeen=0,hops="?",
            job=nil,jobProgressSeen=0,jobSignature="",capabilities={},
        }
        units[unitId]=u
    end
    return u
end

local function jobSignature(job)
    if type(job)~="table" then return "" end
    return table.concat({
        tostring(job.id or ""),
        tostring(job.phase or ""),
        tostring(job.outbound or 0),
        tostring(job.returned or 0),
        tostring(job.recoveries or 0),
        tostring(job.stalled or false),
    },":")
end

local function applyJob(u,job,now)
    now=now or Common.nowMs()
    local sig=jobSignature(job)
    if sig~=u.jobSignature then
        u.jobProgressSeen=now
        u.jobSignature=sig
    end
    u.job=type(job)=="table" and job or nil
    if not u.job then
        u.jobProgressSeen=0
        u.jobSignature=""
    end
    cacheDirty=true
end

local function requestRedraw()
    os.queueEvent("fleet_jobs_redraw")
end

local function handlePacket(packet,protocol)
    if protocol~=Common.REDNET_PROTOCOL then return end
    local valid=Common.verify(packet,config.key,config.fleetId)
    if not valid then return end
    local id=Common.packetId(packet)
    if Common.seen(seen,id) then return end
    Common.markSeen(seen,id)
    local now=Common.nowMs()

    if packet.type=="status" then
        local p=packet.payload
        local unitId=tonumber(p.unit or packet.origin)
        if unitId then
            local u=ensureUnit(unitId)
            u.name=tostring(p.name or u.name)
            u.role=tostring(p.role or u.role)
            u.state=tostring(p.state or u.state)
            u.linkState=tostring(p.linkState or u.linkState or "?")
            u.fuel=p.fuel
            u.version=p.version or u.version
            u.lastSeen=now
            u.hops=Common.DEFAULT_TTL-math.max(0,tonumber(packet.ttl) or 0)
            u.navPos=p.navPos
            u.heading=p.heading
            u.capabilities=p.capabilities or u.capabilities or {}
            applyJob(u,p.job,now)
            cacheDirty=true
        end

    elseif packet.type=="job_event" then
        local p=packet.payload
        local unitId=tonumber(p.unit or packet.origin)
        if unitId then
            local u=ensureUnit(unitId)
            u.lastSeen=now
            u.role="ASSAULT"
            local eventName=tostring(p.event or "")
            if eventName=="START" or eventName=="RETURN" or eventName=="RESUME" or eventName=="STALLED" then
                applyJob(u,{
                    id=p.id,type=p.type,phase=p.phase,outbound=p.outbound,returned=p.returned,
                    distance=p.distance,reason=p.reason,delay=p.delay,recoveries=p.recoveries,
                    stalled=eventName=="STALLED" or p.stalled,
                },now)
                u.state=eventName=="STALLED" and "JOB:STALLED" or ("JOB:"..tostring(p.phase or eventName))
                message=string.format("#%s %s %s %s/%s",unitId,eventName,tostring(p.phase or "?"),tostring(p.outbound or 0),tostring(p.distance or 0))
            else
                applyJob(u,nil,now)
                u.state=eventName=="DONE" and "JOB_DONE" or "JOB_FAILED"
                message=string.format("#%s JOB %s %s",unitId,eventName~="" and eventName or (p.success and "DONE" or "FAIL"),tostring(p.reason or ""))
            end
            cacheDirty=true
        end

    elseif packet.type=="result" then
        local p=packet.payload
        local unitId=tonumber(p.unit or packet.origin)
        if unitId then
            local u=ensureUnit(unitId)
            u.lastSeen=now
            if type(p.job)=="table" then applyJob(u,p.job,now) end
            cacheDirty=true
        end

        local rid=tostring(p.requestId or "")
        local item=pending[rid]
        if item then
            item.expected[tostring(p.unit or packet.origin)]=nil
            local any=false
            for _ in pairs(item.expected) do any=true break end
            if not any then pending[rid]=nil end
        end

        if p.command=="job_tunnel_roundtrip" or p.command=="job_cancel" then
            message=string.format("#%s %s %s",tostring(p.unit or packet.origin),p.ok and "ACK" or "FAIL",tostring(p.detail or ""))
        end
    end

    relay(packet)
    requestRedraw()
end

local function onlineCounts()
    local now=Common.nowMs()
    local assault,relayCount,busy,stalled=0,0,0,0
    for _,u in pairs(units) do
        if now-(u.lastSeen or 0)<=UNIT_STALE_MS then
            if u.role=="ASSAULT" then assault=assault+1 else relayCount=relayCount+1 end
            if type(u.job)=="table" then
                busy=busy+1
                if u.job.stalled or (u.jobProgressSeen>0 and now-u.jobProgressSeen>JOB_STALE_MS) then
                    stalled=stalled+1
                end
            end
        end
    end
    return assault,relayCount,busy,stalled
end

local function pendingCount()
    local n=0
    for _ in pairs(pending) do n=n+1 end
    return n
end

local function transmit(item)
    local ok,err=sendPacket("command",item.target,item.payload)
    item.attempts=item.attempts+1
    item.nextRetry=Common.nowMs()+RETRY_DELAYS_MS[math.min(item.attempts,#RETRY_DELAYS_MS)]
    if not ok then message="send failed: "..tostring(err) end
end

local function issue(command,args,target)
    commandSeq=commandSeq+1
    local rid=string.format("%d:%s:%d",os.getComputerID(),mesh.bootId,commandSeq)
    local payload={
        operator=os.getComputerID(),operatorBoot=mesh.bootId,commandSeq=commandSeq,
        issuedAt=Common.nowMs(),requestId=rid,command=command,
        args=type(args)=="table" and args or {},
    }

    local expected={}
    local now=Common.nowMs()
    for _,u in pairs(units) do
        if now-(u.lastSeen or 0)<=UNIT_STALE_MS then
            if target=="*" or tonumber(target)==u.id or (target=="ASSAULT" and u.role=="ASSAULT") then
                expected[tostring(u.id)]=true
            end
        end
    end

    local item={
        target=target or "ASSAULT",payload=payload,expected=expected,
        attempts=0,nextRetry=0,expires=Common.nowMs()+PENDING_TTL_MS,
    }
    pending[rid]=item
    transmit(item)
    requestRedraw()
    return true,rid
end

local function retryPending()
    local now=Common.nowMs()
    for rid,item in pairs(pending) do
        if now>=item.expires then
            pending[rid]=nil
            message="TIMEOUT "..tostring(item.payload.command)
        elseif now>=item.nextRetry and item.attempts<#RETRY_DELAYS_MS then
            transmit(item)
        end
    end
end

local function confirm(text)
    term.clear()
    term.setCursorPos(1,1)
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

local function ask(prompt,default)
    write(prompt..(default~=nil and (" ["..tostring(default).."]") or "")..": ")
    local value=read()
    if value=="" and default~=nil then return tostring(default) end
    return value
end

local function textAt(y,text,color)
    local w=term.getSize()
    term.setCursorPos(1,y)
    term.setBackgroundColor(colors.black)
    term.setTextColor(color or colors.white)
    term.write(string.rep(" ",w))
    term.setCursorPos(1,y)
    term.write(tostring(text):sub(1,w))
end

local function draw()
    local w,h=term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)
    term.setBackgroundColor(colors.orange)
    term.write(string.rep(" ",w))
    term.setCursorPos(1,1)
    term.setTextColor(colors.black)
    term.write("BASE POCKET / FLEET JOBS")
    term.setBackgroundColor(colors.black)

    local assault,relays,busy,stalled=onlineCounts()
    textAt(3,string.format("Fleet %s",config.fleetId),colors.lightGray)
    textAt(4,string.format("ASSAULT online: %d",assault))
    textAt(5,string.format("RELAY online:   %d",relays))
    textAt(6,string.format("Jobs:%d stalled:%d TX:%d",busy,stalled,pendingCount()),stalled>0 and colors.red or (busy>0 and colors.yellow or colors.lightGray))

    local row=8
    local now=Common.nowMs()
    local list={}
    for _,u in pairs(units) do
        if now-(u.lastSeen or 0)<=UNIT_STALE_MS and u.role=="ASSAULT" then list[#list+1]=u end
    end
    table.sort(list,function(a,b) return a.id<b.id end)

    local visible=math.max(1,h-13)
    for i=1,math.min(#list,visible) do
        local u=list[i]
        local job="IDLE"
        local color=colors.white
        if type(u.job)=="table" then
            local phase=tostring(u.job.phase or "?")
            local current=tonumber(phase=="OUT" and u.job.outbound or u.job.returned) or 0
            local total=tonumber(phase=="OUT" and u.job.distance or u.job.outbound) or 0
            local isStalled=u.job.stalled or (u.jobProgressSeen>0 and now-u.jobProgressSeen>JOB_STALE_MS)
            if isStalled then
                job=string.format("STALLED %s %d/%d",phase,current,total)
                color=colors.red
            else
                job=string.format("%s %d/%d",phase,current,total)
                if tonumber(u.job.recoveries or 0)>0 then job=job.." R"..tostring(u.job.recoveries) end
                color=colors.yellow
            end
        end
        textAt(row+i-1,string.format("#%s F:%s %s",u.id,tostring(u.fuel or "?"),job),color)
    end

    textAt(h-3,message,colors.orange)
    textAt(h-2,"T tunnel roundtrip   C cancel/return",colors.lightGray)
    textAt(h-1,"U update fleet       Q back",colors.lightGray)
end

local function startTunnel()
    sendPacket("discover","*",{operator=os.getComputerID(),app="jobs",version=VERSION})
    term.clear()
    term.setCursorPos(1,1)
    print("Tunnel roundtrip job")
    local distance=math.floor(tonumber(ask("Distance blocks",100)) or 0)
    local delay=tonumber(ask("Step delay seconds",0.15)) or 0.15
    if distance<1 or distance>4096 then message="Distance must be 1..4096"; return end
    if delay<0.05 or delay>2 then message="Delay must be 0.05..2.0"; return end

    local assault=select(1,onlineCounts())
    if assault==0 then message="No online ASSAULT units"; return end
    if not confirm(string.format("Start %d-block tunnel on %d ASSAULT units?",distance,assault)) then
        message="Job cancelled"
        return
    end

    local jobId=string.format("TUN-%d-%d",os.getComputerID(),Common.nowMs())
    issue("job_tunnel_roundtrip",{jobId=jobId,distance=distance,stepDelay=delay},"ASSAULT")
    message=string.format("Tunnel %d queued for %d units",distance,assault)
end

local function cancelJobs()
    local _,_,busy=onlineCounts()
    if busy==0 then message="No reported active jobs"; return end
    if not confirm("Abort active jobs and return along tunnel?") then message="Abort cancelled"; return end
    issue("job_cancel",{},"ASSAULT")
    message="Abort/return queued"
end

local function updateFleet()
    local _,_,busy=onlineCounts()
    if busy>0 then message="Update blocked: active jobs="..tostring(busy); return end
    if not confirm("Update all Fleet nodes? Units may reboot.") then message="Update cancelled"; return end
    issue("update",{},"*")
    message="Fleet update queued"
end

local function networkLoop()
    if #Common.openModems()==0 then error("No wireless modem found",0) end

    local retryTimer=os.startTimer(RETRY_TIMER_SECONDS)
    local recoveryTimer=os.startTimer(2)
    local beaconTimer=os.startTimer(0.2)
    local discoverTimer=os.startTimer(0.1)
    local cacheTimer=os.startTimer(CACHE_FLUSH_MS/1000)

    while appRunning do
        local e,a,b,c=os.pullEvent()
        if e=="rednet_message" then
            handlePacket(b,c)
        elseif e=="timer" and a==retryTimer then
            retryPending()
            retryTimer=os.startTimer(RETRY_TIMER_SECONDS)
        elseif e=="timer" and a==recoveryTimer then
            Common.openModems()
            recoveryTimer=os.startTimer(2)
        elseif e=="timer" and a==beaconTimer then
            sendPacket("operator_status","*",{operator=os.getComputerID(),app="jobs",version=VERSION})
            beaconTimer=os.startTimer(BEACON_INTERVAL_MS/1000)
        elseif e=="timer" and a==discoverTimer then
            sendPacket("discover","*",{operator=os.getComputerID(),app="jobs",version=VERSION})
            discoverTimer=os.startTimer(DISCOVERY_INTERVAL_MS/1000)
        elseif e=="timer" and a==cacheTimer then
            if cacheDirty then saveCache() end
            cacheTimer=os.startTimer(CACHE_FLUSH_MS/1000)
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
            elseif a==keys.c then cancelJobs()
            elseif a==keys.u then updateFleet()
            elseif a==keys.q or a==keys.escape or a==keys.leftShift then
                appRunning=false
                if cacheDirty then saveCache() end
                return
            end
            draw()
        elseif e=="fleet_jobs_redraw" or e=="term_resize" then
            draw()
        end
    end
end

parallel.waitForAny(uiLoop,networkLoop)
