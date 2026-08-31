local Common = require("lib.fleet.common")

local VERSION = "0.23.0-alpha.4.2"
local CONFIG_PATH = "/data/fleet_agent.json"
local JOB_STATE_PATH = "/data/fleet_job.json"
local FORCE_UPDATE_PATH = "/data/fleet_force_update"

local FUEL_SLOTS = {1, 2, 3, 4}
local FUEL_LOW = 256
local FUEL_TARGET = 1536
local RTB_RESERVE = 64

local JOB_MAX_DISTANCE = 4096
local JOB_MIN_DELAY = 0.05
local JOB_MAX_DELAY = 2.0
local JOB_DEFAULT_DELAY = 0.15
local JOB_START_STAGGER = 0.025
local JOB_STALL_MS = 10000

local STATUS_IDLE_MS = 10000
local STATUS_ACTIVE_MS = 2500
local STATUS_RELAY_MS = 4000
local DISCOVERY_REPLY_COOLDOWN_MS = 3000
local TRAFFIC_RECENT_MS = 15000

local COMMAND_MAX_AGE_MS = 15000
local COMMAND_FUTURE_SKEW_MS = 5000

if type(turtle) ~= "table" then error("Fleet agent must run on a turtle", 0) end

local HEADINGS = {N=0, E=1, S=2, W=3}
local HEADING_NAMES = {[0]="N", [1]="E", [2]="S", [3]="W"}
local DIR = {
    [0] = {x=0, z=-1},
    [1] = {x=1, z=0},
    [2] = {x=0, z=1},
    [3] = {x=-1, z=0},
}

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local raw = f.readAll()
    f.close()
    local ok, value = pcall(textutils.unserializeJSON, raw)
    return ok and type(value) == "table" and value or nil
end

local function writeJson(path, value)
    ensureParent(path)
    local ok, raw = pcall(textutils.serializeJSON, value)
    if not ok then return false, raw end
    local tmp, bak = path .. ".tmp", path .. ".bak"
    if fs.exists(tmp) then pcall(fs.delete, tmp) end
    local f = fs.open(tmp, "w")
    if not f then return false, "open_failed" end
    local wrote, err = pcall(function() f.write(raw) end)
    pcall(function() f.close() end)
    if not wrote then pcall(fs.delete, tmp); return false, tostring(err) end
    if fs.exists(bak) then pcall(fs.delete, bak) end
    if fs.exists(path) then
        local backed = pcall(fs.move, path, bak)
        if not backed then pcall(fs.delete, tmp); return false, "backup_failed" end
    end
    local committed = pcall(fs.move, tmp, path)
    if not committed then
        if fs.exists(bak) and not fs.exists(path) then pcall(fs.move, bak, path) end
        return false, "commit_failed"
    end
    if fs.exists(bak) then pcall(fs.delete, bak) end
    return true
end

local function ask(prompt, default)
    write(prompt .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
    local value = read()
    if value == "" and default ~= nil then return tostring(default) end
    return value
end

local function firstRun()
    Common.openModems()
    term.clear()
    term.setCursorPos(1, 1)
    print("BASE Fleet Agent Setup")
    print("Computer ID: " .. os.getComputerID())
    local fleetId = ask("Fleet ID")
    if fleetId == "" then error("Fleet ID cannot be empty", 0) end
    local key = ask("Fleet key")
    if #key < 16 then error("Fleet key must be at least 16 characters", 0) end
    local name = ask("Unit name", os.getComputerLabel() or ("Unit-" .. tostring(os.getComputerID())))
    local role = string.upper(ask("Role ASSAULT/RELAY", "ASSAULT"))
    if role ~= "RELAY" then role = "ASSAULT" end
    local headingName = string.upper(ask("Facing N/E/S/W", "N"))
    local heading = HEADINGS[headingName] or 0
    local navX = tonumber(ask("Local X", "0")) or 0
    local navY = tonumber(ask("Local Y", "0")) or 0
    local navZ = tonumber(ask("Local Z", "0")) or 0
    local cfg = {
        schema=4, fleetId=fleetId, key=key, name=name, role=role,
        relay=(role=="RELAY"), heading=heading,
        nav={x=navX, y=navY, z=navZ, frame=fleetId}, homeNav=nil,
    }
    writeJson(CONFIG_PATH, cfg)
    return cfg
end

local function normalizeConfig(cfg)
    if type(cfg) ~= "table" or type(cfg.fleetId) ~= "string" or cfg.fleetId == "" then return nil end
    if type(cfg.key) ~= "string" or #cfg.key < 16 then return nil end
    cfg.schema = 4
    cfg.name = tostring(cfg.name or ("Unit-" .. tostring(os.getComputerID()))):sub(1, 32)
    cfg.role = cfg.role == "RELAY" and "RELAY" or "ASSAULT"
    cfg.relay = cfg.role == "RELAY"
    cfg.heading = math.floor(tonumber(cfg.heading) or 0) % 4
    if type(cfg.nav) ~= "table" then cfg.nav = {x=0,y=0,z=0,frame=cfg.fleetId} end
    cfg.nav.x = tonumber(cfg.nav.x) or 0
    cfg.nav.y = tonumber(cfg.nav.y) or 0
    cfg.nav.z = tonumber(cfg.nav.z) or 0
    cfg.nav.frame = tostring(cfg.nav.frame or cfg.fleetId)
    if type(cfg.homeNav) == "table" then
        cfg.homeNav = {
            x=tonumber(cfg.homeNav.x) or 0,
            y=tonumber(cfg.homeNav.y) or 0,
            z=tonumber(cfg.homeNav.z) or 0,
            frame=tostring(cfg.homeNav.frame or cfg.nav.frame),
        }
    else
        cfg.homeNav = nil
    end
    cfg.operatorSeq = nil
    return cfg
end

local config = normalizeConfig(readJson(CONFIG_PATH)) or firstRun()
local mesh = {bootId=Common.randomHex(12), seq=0}
local seen = Common.newSeenCache()
local operatorSeq = {}
local resultCache = {}

local state = "IDLE"
local navPosition = {x=config.nav.x, y=config.nav.y, z=config.nav.z, frame=config.nav.frame}
local rtbActive, rtbReason = false, ""
local poseDirty = false

local activeJob = nil
local lastJobProgressMs = 0
local lastJobStallEventMs = 0

local lastValidMesh = 0
local modemReady = false
local forceStatusDueMs = nil
local lastDiscoveryReplyMs = 0

local function saveConfig()
    config.nav = {
        x=navPosition.x, y=navPosition.y, z=navPosition.z, frame=navPosition.frame,
    }
    return writeJson(CONFIG_PATH, config)
end

local function fuelSnapshot()
    local ok, fuel = pcall(turtle.getFuelLevel)
    if not ok then return nil, nil end
    local limit
    local ok2, value = pcall(turtle.getFuelLimit)
    if ok2 then limit = value end
    return fuel, limit
end

local function refuelTo(target)
    local fuel = select(1, fuelSnapshot())
    if fuel == "unlimited" then return true, fuel end
    fuel = tonumber(fuel)
    if not fuel then return false, nil end
    target = math.max(FUEL_LOW, math.floor(tonumber(target) or FUEL_TARGET))
    if fuel >= target then return true, fuel end

    local oldSlot = 1
    local okSel, selected = pcall(turtle.getSelectedSlot)
    if okSel and type(selected) == "number" then oldSlot = selected end

    for _, slot in ipairs(FUEL_SLOTS) do
        if fuel >= target then break end
        pcall(turtle.select, slot)
        while fuel < target do
            local okCount, count = pcall(turtle.getItemCount, slot)
            if not okCount or not count or count <= 0 then break end
            local okProbe, usable = pcall(turtle.refuel, 0)
            if not okProbe or usable ~= true then break end
            local okBurn, burned = pcall(turtle.refuel, 1)
            if not okBurn or burned ~= true then break end
            local nextFuel = select(1, fuelSnapshot())
            if nextFuel == "unlimited" then fuel = target; break end
            fuel = tonumber(nextFuel) or fuel
        end
    end

    pcall(turtle.select, oldSlot)
    local after = select(1, fuelSnapshot())
    if after == "unlimited" then return true, after end
    return tonumber(after) and tonumber(after) >= target, tonumber(after)
end

local function autoRefuel()
    return refuelTo(FUEL_TARGET)
end

local function equipped(side)
    local fn = side == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn)
    return ok and type(value) == "table" and value or nil
end

local function itemName(item)
    return string.lower(tostring(type(item) == "table" and item.name or ""))
end

local function matchesTool(name, kind)
    name = string.lower(tostring(name or ""))
    if kind == "sword" then return name:find("sword", 1, true) ~= nil end
    if kind == "pickaxe" then return name:find("pickaxe", 1, true) ~= nil end
    return false
end

local function findToolSide()
    if peripheral.hasType then
        local okL, modemL = pcall(peripheral.hasType, "left", "modem")
        if okL and modemL then return "right" end
        local okR, modemR = pcall(peripheral.hasType, "right", "modem")
        if okR and modemR then return "left" end
    end
    local left, right = itemName(equipped("left")), itemName(equipped("right"))
    if left:find("modem", 1, true) then return "right" end
    if right:find("modem", 1, true) then return "left" end
    return "left"
end

local function inventoryHas(kind)
    if matchesTool(itemName(equipped("left")), kind)
        or matchesTool(itemName(equipped("right")), kind)
    then
        return true
    end
    for slot=5,16 do
        local ok, detail = pcall(turtle.getItemDetail, slot)
        if ok and type(detail) == "table" and matchesTool(detail.name, kind) then return true end
    end
    return false
end

local function ensureTool(kind)
    local side = findToolSide()
    if matchesTool(itemName(equipped(side)), kind) then return true end

    local oldSlot = 1
    local okSel, selected = pcall(turtle.getSelectedSlot)
    if okSel and type(selected) == "number" then oldSlot = selected end

    for slot=5,16 do
        local ok, detail = pcall(turtle.getItemDetail, slot)
        if ok and type(detail) == "table" and matchesTool(detail.name, kind) then
            turtle.select(slot)
            local equipFn = side == "left" and turtle.equipLeft or turtle.equipRight
            local equippedOk, err = equipFn()
            turtle.select(oldSlot)
            return equippedOk == true, equippedOk and nil or tostring(err or "equip_failed")
        end
    end

    turtle.select(oldSlot)
    return false, kind .. "_missing"
end

local function capabilitySnapshot()
    return {
        move=true,
        modem=modemReady,
        melee=inventoryHas("sword"),
        dig=inventoryHas("pickaxe"),
        nav=true,
        relay=config.role=="RELAY",
        autoUpdate=fs.exists("/fleet_update.lua"),
        jobs=true,
        jobWorker=true,
        jobResume=true,
    }
end

local function send(messageType, target, payload, ttl)
    local packet, err = Common.newPacket(config, mesh, messageType, target, payload, ttl)
    if not packet then return false, err end
    Common.markSeen(seen, Common.packetId(packet))
    return Common.broadcast(packet)
end

local function maybeRelay(packet)
    if config.role ~= "RELAY" or packet.ttl <= 0 then return end
    local forwarded = Common.forwardPacket(packet, config.key)
    if forwarded then Common.broadcast(forwarded) end
end

local function targetMatches(target)
    if target == nil or target == "*" then return true end
    if tonumber(target) == os.getComputerID() then return true end
    return tostring(target) == config.role
end

local function markMove(command)
    local d = DIR[config.heading]
    if command == "forward" then
        navPosition.x=navPosition.x+d.x; navPosition.z=navPosition.z+d.z
    elseif command == "back" then
        navPosition.x=navPosition.x-d.x; navPosition.z=navPosition.z-d.z
    elseif command == "up" then
        navPosition.y=navPosition.y+1
    elseif command == "down" then
        navPosition.y=navPosition.y-1
    end
    poseDirty = true
end

local function move(command)
    local fn = command=="forward" and turtle.forward
        or command=="back" and turtle.back
        or command=="up" and turtle.up
        or command=="down" and turtle.down
    if not fn then return false, "bad_move" end
    local ok, err = fn()
    if ok then markMove(command) end
    return ok == true, err
end

local function turnLeft()
    local ok, err = turtle.turnLeft()
    if ok then config.heading=(config.heading+3)%4; poseDirty=true end
    return ok==true, err
end

local function turnRight()
    local ok, err = turtle.turnRight()
    if ok then config.heading=(config.heading+1)%4; poseDirty=true end
    return ok==true, err
end

local function face(desired)
    desired = math.floor(desired) % 4
    local diff = (desired-config.heading)%4
    if diff==0 then return true end
    if diff==1 then return turnRight() end
    if diff==3 then return turnLeft() end
    local ok, err = turnRight()
    if not ok then return false, err end
    return turnRight()
end

local function distanceHome()
    if not config.homeNav or config.homeNav.frame ~= navPosition.frame then return nil end
    return math.abs(navPosition.x-config.homeNav.x)
        + math.abs(navPosition.y-config.homeNav.y)
        + math.abs(navPosition.z-config.homeNav.z)
end

local function checkLowFuel()
    if config.role=="RELAY" or activeJob or not config.homeNav then return false end
    local fuel = select(1, fuelSnapshot())
    if fuel=="unlimited" then return false end
    fuel=tonumber(fuel)
    if not fuel then return false end
    local need=distanceHome()
    if not need then return false end
    if fuel <= need + RTB_RESERVE then
        rtbActive=true
        rtbReason="LOW_FUEL"
        state="RTB"
        return true
    end
    return false
end

local function rtbStep()
    if not rtbActive or activeJob then return end
    local h=config.homeNav
    if not h or h.frame~=navPosition.frame then
        state="RTB_NO_HOME"
        rtbActive=false
        return
    end

    local x,y,z=math.floor(navPosition.x+0.5),math.floor(navPosition.y+0.5),math.floor(navPosition.z+0.5)
    local hx,hy,hz=math.floor(h.x+0.5),math.floor(h.y+0.5),math.floor(h.z+0.5)
    if x==hx and y==hy and z==hz then
        state="HOME"
        rtbActive=false
        return
    end

    local ok,err
    if x<hx then ok,err=face(1); if ok then ok,err=move("forward") end
    elseif x>hx then ok,err=face(3); if ok then ok,err=move("forward") end
    elseif z<hz then ok,err=face(2); if ok then ok,err=move("forward") end
    elseif z>hz then ok,err=face(0); if ok then ok,err=move("forward") end
    elseif y<hy then ok,err=move("up")
    else ok,err=move("down") end

    if not ok then
        state="RTB_BLOCKED:"..tostring(err or "blocked")
        rtbActive=false
    end
end

local function jobPayload(job)
    job=job or activeJob
    if not job then return nil end
    return {
        id=job.id,
        type=job.type,
        phase=job.phase,
        outbound=job.outbound,
        returned=job.returned,
        distance=job.distance,
        reason=job.reason,
        delay=job.delay,
        recoveries=job.recoveries or 0,
        stalled=lastJobProgressMs>0 and Common.nowMs()-lastJobProgressMs>JOB_STALL_MS or false,
    }
end

local function saveJobState()
    if not activeJob then
        if fs.exists(JOB_STATE_PATH) then pcall(fs.delete, JOB_STATE_PATH) end
        return true
    end
    return writeJson(JOB_STATE_PATH, {
        schema=2,
        savedAt=Common.nowMs(),
        job=jobPayload(activeJob),
        startHeading=activeJob.startHeading,
        nav={x=navPosition.x,y=navPosition.y,z=navPosition.z,frame=navPosition.frame},
        heading=config.heading,
    })
end

local function emitJobEvent(eventName, job, success, reason)
    job=job or activeJob
    if not job then return end
    local payload=jobPayload(job)
    payload.unit=os.getComputerID()
    payload.event=eventName
    payload.success=success
    payload.reason=reason or payload.reason
    send("job_event", "*", payload)
end

local function requestStatusSoon(delayMs)
    local due=Common.nowMs()+math.max(0, math.floor(tonumber(delayMs) or 0))
    if not forceStatusDueMs or due<forceStatusDueMs then forceStatusDueMs=due end
    os.queueEvent("fleet_status_wake")
end

local function wakeJobWorker()
    os.queueEvent("fleet_job_wake")
end

local function markJobProgress()
    lastJobProgressMs=Common.nowMs()
    saveJobState()
    requestStatusSoon(0)
end

local function finishJob(success, reason)
    if not activeJob then return end
    local job=activeJob
    activeJob=nil
    lastJobProgressMs=0
    lastJobStallEventMs=0
    state=success and "JOB_DONE" or "JOB_FAILED"
    if fs.exists(JOB_STATE_PATH) then pcall(fs.delete, JOB_STATE_PATH) end
    emitJobEvent(success and "DONE" or "FAIL", job, success, reason)
    if poseDirty then saveConfig(); poseDirty=false end
    requestStatusSoon(0)
end

local function switchJobToReturn(reason)
    if not activeJob then return end
    if reason and reason~="" and activeJob.reason=="" then activeJob.reason=tostring(reason) end
    activeJob.phase="RETURN"
    state="JOB:RETURN"
    markJobProgress()
    emitJobEvent("RETURN", activeJob)
    wakeJobWorker()
end

local function startTunnelJob(args, requestId)
    if config.role~="ASSAULT" then return false, "assault_only" end
    if activeJob then return false, "job_busy" end

    local distance=math.floor(tonumber(args.distance) or 0)
    if distance<1 or distance>JOB_MAX_DISTANCE then return false, "bad_distance" end
    local delay=tonumber(args.stepDelay) or JOB_DEFAULT_DELAY
    delay=math.max(JOB_MIN_DELAY, math.min(JOB_MAX_DELAY, delay))

    local toolOk, toolErr=ensureTool("pickaxe")
    if not toolOk then return false, toolErr end
    local fuelNeed=distance*2+RTB_RESERVE
    local fuelOk, fuel=refuelTo(fuelNeed)
    if not fuelOk then
        return false, "insufficient_fuel:"..tostring(fuel or "?").."/"..tostring(fuelNeed)
    end

    rtbActive=false
    rtbReason=""
    activeJob={
        id=tostring(args.jobId or requestId or ("job-"..Common.nowMs())),
        type="tunnel_roundtrip",
        phase="OUT",
        distance=distance,
        outbound=0,
        returned=0,
        delay=delay,
        reason="",
        startHeading=config.heading,
        recoveries=0,
        initialDelay=delay+(os.getComputerID()%24)*JOB_START_STAGGER,
    }
    state="JOB:OUT"
    lastJobProgressMs=Common.nowMs()
    saveJobState()
    emitJobEvent("START", activeJob)
    requestStatusSoon(0)
    wakeJobWorker()
    return true, "job_started:"..tostring(distance)
end

local function requestJobReturn(reason)
    if not activeJob then return false, "no_active_job" end
    if activeJob.reason=="" then activeJob.reason=tostring(reason or "OPERATOR_ABORT") end
    activeJob.phase="RETURN"
    state="JOB:RETURN"
    markJobProgress()
    emitJobEvent("RETURN", activeJob)
    wakeJobWorker()
    return true, "returning"
end

local function jobStep()
    local job=activeJob
    if not job then return end

    if job.phase=="OUT" then
        if job.outbound>=job.distance then
            switchJobToReturn()
            return
        end

        local toolOk, toolErr=ensureTool("pickaxe")
        if not toolOk then switchJobToReturn(toolErr); return end

        local detected=false
        pcall(function() detected=turtle.detect() end)
        if detected then
            local dug, digErr=turtle.dig()
            if not dug then
                switchJobToReturn("dig_failed:"..tostring(digErr or "blocked"))
                return
            end
        end

        local moved, moveErr=move("forward")
        if not moved then
            switchJobToReturn("move_failed:"..tostring(moveErr or "blocked"))
            return
        end

        job.outbound=job.outbound+1
        state="JOB:OUT "..job.outbound.."/"..job.distance
        markJobProgress()

        if job.outbound>=job.distance then switchJobToReturn() end

    elseif job.phase=="RETURN" then
        if job.returned>=job.outbound then
            finishJob(job.reason=="", job.reason~="" and job.reason or "complete")
            return
        end

        local moved, moveErr=move("back")
        if not moved then
            finishJob(false, "return_blocked:"..tostring(moveErr or "blocked"))
            return
        end

        job.returned=job.returned+1
        state="JOB:RETURN "..job.returned.."/"..job.outbound
        markJobProgress()

        if job.returned>=job.outbound then
            finishJob(job.reason=="", job.reason~="" and job.reason or "complete")
        end
    else
        finishJob(false, "bad_job_phase:"..tostring(job.phase))
    end
end

local function restoreJobState()
    local saved=readJson(JOB_STATE_PATH)
    if type(saved)~="table" or type(saved.job)~="table" then return false end
    local job=saved.job
    if job.type~="tunnel_roundtrip" then return false end

    local distance=math.floor(tonumber(job.distance) or 0)
    local outbound=math.floor(tonumber(job.outbound) or 0)
    local returned=math.floor(tonumber(job.returned) or 0)
    local phase=tostring(job.phase or "")
    if distance<1 or distance>JOB_MAX_DISTANCE then return false end
    if phase~="OUT" and phase~="RETURN" then return false end

    outbound=math.max(0, math.min(distance, outbound))
    returned=math.max(0, math.min(outbound, returned))
    if phase=="OUT" and outbound>=distance then phase="RETURN" end

    activeJob={
        id=tostring(job.id or ("recovered-"..Common.nowMs())),
        type="tunnel_roundtrip",
        phase=phase,
        distance=distance,
        outbound=outbound,
        returned=returned,
        delay=math.max(JOB_MIN_DELAY, math.min(JOB_MAX_DELAY, tonumber(job.delay) or JOB_DEFAULT_DELAY)),
        reason=tostring(job.reason or ""),
        startHeading=math.floor(tonumber(saved.startHeading) or config.heading)%4,
        recoveries=math.floor(tonumber(job.recoveries) or 0)+1,
        initialDelay=0.1+(os.getComputerID()%24)*JOB_START_STAGGER,
    }

    if type(saved.nav)=="table" then
        navPosition={
            x=tonumber(saved.nav.x) or navPosition.x,
            y=tonumber(saved.nav.y) or navPosition.y,
            z=tonumber(saved.nav.z) or navPosition.z,
            frame=tostring(saved.nav.frame or navPosition.frame),
        }
    end
    if tonumber(saved.heading) then config.heading=math.floor(tonumber(saved.heading))%4 end

    state="JOB:RESUME "..activeJob.phase
    lastJobProgressMs=Common.nowMs()
    saveJobState()
    emitJobEvent("RESUME", activeJob)
    requestStatusSoon(0)
    return true
end

local function perform(command, args, requestId)
    args=type(args)=="table" and args or {}

    if activeJob then
        if command=="job_cancel" or command=="hold" then return requestJobReturn("OPERATOR_ABORT") end
        return false, "job_active"
    end

    if rtbActive and command~="hold" and command~="set_home" and command~="update" then
        return false, "rtb_active"
    end

    local ok,err
    if command=="forward" or command=="back" or command=="up" or command=="down" then
        autoRefuel()
        ok,err=move(command)
    elseif command=="turn_left" then
        return turnLeft()
    elseif command=="turn_right" then
        return turnRight()
    elseif command=="attack" or command=="attack_up" or command=="attack_down" then
        local toolOk,toolErr=ensureTool("sword")
        if not toolOk then return false,toolErr end
        local fn=command=="attack" and turtle.attack
            or command=="attack_up" and turtle.attackUp
            or turtle.attackDown
        ok,err=fn()
    elseif command=="dig" or command=="dig_up" or command=="dig_down" then
        local toolOk,toolErr=ensureTool("pickaxe")
        if not toolOk then return false,toolErr end
        local fn=command=="dig" and turtle.dig
            or command=="dig_up" and turtle.digUp
            or turtle.digDown
        ok,err=fn()
    elseif command=="breach" then
        local detected=false
        pcall(function() detected=turtle.detect() end)
        if detected then
            local t,e=ensureTool("pickaxe")
            if not t then return false,e end
            local d,de=turtle.dig()
            if not d then return false,tostring(de or "dig_failed") end
        else
            local t=ensureTool("sword")
            if t then pcall(turtle.attack) end
        end
        autoRefuel()
        ok,err=move("forward")
    elseif command=="job_tunnel_roundtrip" then
        return startTunnelJob(args, requestId)
    elseif command=="job_cancel" then
        return requestJobReturn("OPERATOR_ABORT")
    elseif command=="rtb" then
        if not config.homeNav then return false,"home_not_set" end
        rtbActive=true; rtbReason="OPERATOR"; state="RTB"
        return true,"rtb_started"
    elseif command=="hold" then
        rtbActive=false; state="HOLD"
        return true,"hold"
    elseif command=="set_home" then
        config.homeNav={x=navPosition.x,y=navPosition.y,z=navPosition.z,frame=navPosition.frame}
        saveConfig(); poseDirty=false
        return true,"home_set"
    elseif command=="set_pose" then
        local x,y,z=tonumber(args.x),tonumber(args.y),tonumber(args.z)
        local heading=HEADINGS[string.upper(tostring(args.heading or ""))]
        if not x or not y or not z or heading==nil then return false,"bad_pose" end
        navPosition={x=x,y=y,z=z,frame=tostring(args.frame or config.fleetId)}
        config.heading=heading
        poseDirty=true
        saveConfig()
        poseDirty=false
        return true,"pose_set"
    elseif command=="update" then
        local f=fs.open(FORCE_UPDATE_PATH,"w")
        if f then f.write(VERSION); f.close() end
        return true,"update_reboot_scheduled"
    else
        return false,"unknown_command"
    end

    if ok then checkLowFuel() end
    requestStatusSoon(0)
    return ok==true,tostring(err or (ok and "ok" or "failed"))
end

local function sendResult(packet,payload,ok,detail)
    send("result",packet.origin,{
        requestId=payload.requestId,
        command=payload.command,
        ok=ok,
        detail=detail,
        unit=os.getComputerID(),
        state=state,
        job=jobPayload(),
    })
end

local function acceptCommand(packet)
    if not targetMatches(packet.target) then return end
    local payload=packet.payload
    local issuedAt=tonumber(payload.issuedAt) or 0
    local now=Common.nowMs()
    if issuedAt<=0 or now-issuedAt>COMMAND_MAX_AGE_MS or issuedAt-now>COMMAND_FUTURE_SKEW_MS then return end

    local operator=tostring(payload.operator or packet.origin)
    local operatorBoot=tostring(payload.operatorBoot or packet.originBoot)
    local key=operator..":"..operatorBoot
    local commandSeq=math.floor(tonumber(payload.commandSeq) or 0)
    if commandSeq<1 then return end

    local last=math.floor(tonumber(operatorSeq[key]) or 0)
    if commandSeq<last then return end
    if commandSeq==last then
        local cached=resultCache[key]
        if cached and cached.seq==commandSeq and cached.requestId==payload.requestId then
            sendResult(packet,payload,cached.ok,cached.detail)
        end
        return
    end

    operatorSeq[key]=commandSeq
    local command=tostring(payload.command or "")
    state="EXEC:"..command
    local ok,detail=perform(command,payload.args,payload.requestId)
    if not activeJob then
        state=ok and (rtbActive and "RTB" or "IDLE") or ("FAILED:"..tostring(detail))
    end
    resultCache[key]={seq=commandSeq,requestId=payload.requestId,ok=ok,detail=detail}
    sendResult(packet,payload,ok,detail)

    if command=="update" and ok then sleep(0.25); os.reboot() end
end

local function scheduleDiscoveryReply()
    local now=Common.nowMs()
    if now-lastDiscoveryReplyMs<DISCOVERY_REPLY_COOLDOWN_MS then return end
    local jitter=(os.getComputerID()%40)*50
    local due=now+jitter
    if not forceStatusDueMs or due<forceStatusDueMs then forceStatusDueMs=due end
    os.queueEvent("fleet_status_wake")
end

local function handlePacket(packet,protocol)
    if protocol~=Common.REDNET_PROTOCOL then return end
    local valid=Common.verify(packet,config.key,config.fleetId)
    if not valid then return end

    lastValidMesh=Common.nowMs()
    local id=Common.packetId(packet)
    if Common.seen(seen,id) then return end
    Common.markSeen(seen,id)

    if packet.type=="command" then
        acceptCommand(packet)
    elseif packet.type=="discover" then
        scheduleDiscoveryReply()
    end
    maybeRelay(packet)
end

local function currentLinkState()
    if not modemReady then return "NO_MODEM" end
    if lastValidMesh>0 and Common.nowMs()-lastValidMesh<=TRAFFIC_RECENT_MS then return "TRAFFIC" end
    return "READY"
end

local function draw()
    local w,h=term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)
    term.setBackgroundColor(config.role=="RELAY" and colors.blue or colors.red)
    term.write(string.rep(" ",w))
    term.setCursorPos(2,1)
    term.write("BASE FLEET "..config.role)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)

    local fuel=select(1,fuelSnapshot())
    local caps=capabilitySnapshot()
    local lines={
        config.name.." #"..os.getComputerID(),
        "State: "..state.." Link:"..currentLinkState(),
        string.format("NAV %.0f %.0f %.0f H:%s",navPosition.x,navPosition.y,navPosition.z,HEADING_NAMES[config.heading]),
        "Fuel: "..tostring(fuel or "?"),
        string.format("A%s D%s JOB%s R%s",caps.melee and "+" or "-",caps.dig and "+" or "-",caps.jobs and "+" or "-",caps.relay and "+" or "-"),
        activeJob and string.format(
            "Job %s %s %d/%d R:%d",
            activeJob.type,
            activeJob.phase,
            activeJob.phase=="OUT" and activeJob.outbound or activeJob.returned,
            activeJob.phase=="OUT" and activeJob.distance or activeJob.outbound,
            activeJob.recoveries or 0
        ) or "Job: none",
        config.homeNav and string.format("Home %.0f %.0f %.0f",config.homeNav.x,config.homeNav.y,config.homeNav.z) or "Home: not set",
        "v"..VERSION.." Fleet:"..config.fleetId,
    }
    for i,text in ipairs(lines) do
        if i+2<=h then
            term.setCursorPos(1,i+2)
            term.write(tostring(text):sub(1,w))
        end
    end
end

local function sendStatus(reason)
    local fuel,fuelLimit=fuelSnapshot()
    send("status","*",{
        unit=os.getComputerID(),
        name=config.name,
        role=config.role,
        state=state,
        linkState=currentLinkState(),
        fuel=fuel,
        fuelLimit=fuelLimit,
        navPos={x=navPosition.x,y=navPosition.y,z=navPosition.z},
        navFrame=navPosition.frame,
        heading=HEADING_NAMES[config.heading],
        homeNav=config.homeNav,
        capabilities=capabilitySnapshot(),
        rtb=rtbActive,
        rtbReason=rtbReason,
        job=jobPayload(),
        version=VERSION,
        statusReason=reason,
    })
    draw()
end

local function waitUntil(dueMs, wakeEvent)
    while true do
        local now=Common.nowMs()
        local remaining=dueMs-now
        if remaining<=0 then return end
        local timer=os.startTimer(math.max(0.05, remaining/1000))
        while true do
            local event,a=os.pullEvent()
            if event=="timer" and a==timer then break end
            if event==wakeEvent then return end
        end
    end
end

local function jobWorker()
    local first=true
    while true do
        if not activeJob then
            os.pullEvent("fleet_job_wake")
            first=true
        else
            local delay
            if first then
                delay=tonumber(activeJob.initialDelay) or activeJob.delay
                activeJob.initialDelay=nil
                first=false
            else
                delay=activeJob.delay
            end

            local due=Common.nowMs()+math.floor(math.max(JOB_MIN_DELAY,tonumber(delay) or JOB_DEFAULT_DELAY)*1000)
            waitUntil(due,"fleet_job_wake")
            if activeJob then
                autoRefuel()
                jobStep()
            end
        end
    end
end

local function radioLoop()
    while true do
        local event,a,b,c=os.pullEvent()
        if event=="rednet_message" then
            handlePacket(b,c)
        elseif event=="peripheral" or event=="peripheral_detach" then
            modemReady=#Common.openModems()>0
            requestStatusSoon(0)
        end
    end
end

local function statusLoop()
    local nextPeriodic=Common.nowMs()+300+(os.getComputerID()%20)*70
    while true do
        local now=Common.nowMs()
        local due=nextPeriodic
        if forceStatusDueMs and forceStatusDueMs<due then due=forceStatusDueMs end
        waitUntil(due,"fleet_status_wake")
        now=Common.nowMs()

        if forceStatusDueMs and now>=forceStatusDueMs then
            forceStatusDueMs=nil
            lastDiscoveryReplyMs=now
            sendStatus("REQUESTED")
        end

        if now>=nextPeriodic then
            sendStatus("PERIODIC")
            local interval
            if activeJob then interval=STATUS_ACTIVE_MS
            elseif config.role=="RELAY" then interval=STATUS_RELAY_MS
            else interval=STATUS_IDLE_MS end
            nextPeriodic=now+interval+(os.getComputerID()%11)*37
        end

        if activeJob and lastJobProgressMs>0 and now-lastJobProgressMs>JOB_STALL_MS then
            state="JOB:STALLED "..tostring(activeJob.phase)
            if now-lastJobStallEventMs>JOB_STALL_MS then
                lastJobStallEventMs=now
                emitJobEvent("STALLED",activeJob,false,"worker_no_progress")
            end
        end
    end
end

local function modemLoop()
    while true do
        sleep(2)
        modemReady=#Common.openModems()>0
    end
end

local function rtbLoop()
    while true do
        sleep(0.4)
        if not activeJob then
            if rtbActive then
                autoRefuel()
                rtbStep()
                requestStatusSoon(0)
            else
                checkLowFuel()
            end
        end
    end
end

local function checkpointLoop()
    while true do
        sleep(2)
        if poseDirty and not activeJob then
            saveConfig()
            poseDirty=false
        end
    end
end

local function localControlLoop()
    while true do
        local _,key=os.pullEvent("key")
        if key==keys.leftShift then
            if activeJob then
                requestJobReturn("LOCAL_STOP")
            else
                state="STOPPED"
                if poseDirty then saveConfig() end
                draw()
                return
            end
        end
    end
end

modemReady=#Common.openModems()>0
if not modemReady then error("No wireless modem found",0) end
autoRefuel()
restoreJobState()
draw()
requestStatusSoon(0)
if activeJob then wakeJobWorker() end

parallel.waitForAny(
    radioLoop,
    jobWorker,
    statusLoop,
    modemLoop,
    rtbLoop,
    checkpointLoop,
    localControlLoop
)
