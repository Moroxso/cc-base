local Industrial = {}

Industrial.VERSION = "0.23.0-alpha.6.0"
Industrial.SCHEMA = 1
Industrial.CHECKPOINT_SCHEMA = 1

Industrial.TYPE_TUNNEL = "tunnel_roundtrip"
Industrial.TYPE_EXCAVATE = "excavate_box"
Industrial.TYPE_QUARRY = "quarry"

Industrial.FUEL_RESERVE = 64
Industrial.WORK_SLOT_FIRST = 5
Industrial.WORK_SLOT_LAST = 16
Industrial.MIN_FREE_WORK_SLOTS = 1
Industrial.MAX_TUNNEL_DISTANCE = 4096
Industrial.MAX_DIMENSION = 64
Industrial.MAX_VOLUME = 262144
Industrial.MIN_DELAY = 0.05
Industrial.MAX_DELAY = 2.0
Industrial.DEFAULT_DELAY = 0.15

local function nowMs()
    if os and type(os.epoch) == "function" then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then return math.floor(value) end
    end
    if os and type(os.clock) == "function" then return math.floor(os.clock() * 1000) end
    return 0
end

local function copyTable(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[copyTable(k)] = copyTable(v) end
    return out
end

local function integer(value, name, lo, hi)
    local n = tonumber(value)
    if not n then return nil, name .. "_missing" end
    n = math.floor(n)
    if n < lo or n > hi then return nil, name .. "_range" end
    return n
end

local function delayValue(value)
    local n = tonumber(value)
    if not n then n = Industrial.DEFAULT_DELAY end
    if n < Industrial.MIN_DELAY or n > Industrial.MAX_DELAY then return nil, "step_delay_range" end
    return n
end

local function normalizeType(value)
    value = string.lower(tostring(value or ""))
    if value == "tunnel" or value == "roundtrip" then return Industrial.TYPE_TUNNEL end
    if value == "box" or value == "excavate" then return Industrial.TYPE_EXCAVATE end
    if value == "quarry" then return Industrial.TYPE_QUARRY end
    if value == Industrial.TYPE_TUNNEL or value == Industrial.TYPE_EXCAVATE or value == Industrial.TYPE_QUARRY then return value end
    return nil
end

function Industrial.normalizeSpec(spec)
    if type(spec) ~= "table" then return nil, "spec_required" end
    local kind = normalizeType(spec.type or spec.kind)
    if not kind then return nil, "unsupported_job_type" end

    local delay, delayErr = delayValue(spec.stepDelay or spec.delay)
    if not delay then return nil, delayErr end

    if kind == Industrial.TYPE_TUNNEL then
        local distance, err = integer(spec.distance, "distance", 1, Industrial.MAX_TUNNEL_DISTANCE)
        if not distance then return nil, err end
        return {
            schema = Industrial.SCHEMA,
            type = kind,
            distance = distance,
            stepDelay = delay,
            returnPolicy = "origin",
        }
    end

    local width, widthErr = integer(spec.width, "width", 1, Industrial.MAX_DIMENSION)
    if not width then return nil, widthErr end
    local length, lengthErr = integer(spec.length, "length", 1, Industrial.MAX_DIMENSION)
    if not length then return nil, lengthErr end
    local rawLayers = kind == Industrial.TYPE_QUARRY and (spec.depth or spec.height) or (spec.height or spec.depth)
    local layers, layerErr = integer(rawLayers, kind == Industrial.TYPE_QUARRY and "depth" or "height", 1, Industrial.MAX_DIMENSION)
    if not layers then return nil, layerErr end

    local volume = width * length * layers
    if volume > Industrial.MAX_VOLUME then return nil, "volume_range" end

    return {
        schema = Industrial.SCHEMA,
        type = kind,
        width = width,
        length = length,
        layers = layers,
        height = kind == Industrial.TYPE_EXCAVATE and layers or nil,
        depth = kind == Industrial.TYPE_QUARRY and layers or nil,
        stepDelay = delay,
        returnPolicy = "origin",
        vertical = "down",
        path = "serpentine",
    }
end

local function boxReturnAllowance(spec)
    -- Conservative Manhattan allowance from any cell in the work volume back to
    -- the entry point immediately outside the first cell.
    return spec.length + math.max(0, spec.width - 1) + math.max(0, spec.layers - 1) + 1
end

function Industrial.plan(spec)
    local normalized, err = Industrial.normalizeSpec(spec)
    if not normalized then return nil, err end

    if normalized.type == Industrial.TYPE_TUNNEL then
        local workMoves = normalized.distance
        local returnMoves = normalized.distance
        return {
            schema = Industrial.SCHEMA,
            type = normalized.type,
            spec = normalized,
            volume = normalized.distance,
            workMoves = workMoves,
            returnMoves = returnMoves,
            estimatedMoves = workMoves + returnMoves,
            fuelReserve = Industrial.FUEL_RESERVE,
            fuelRequired = workMoves + returnMoves + Industrial.FUEL_RESERVE,
            workSlots = Industrial.WORK_SLOT_LAST - Industrial.WORK_SLOT_FIRST + 1,
            checkpointEvery = 1,
            returnPolicy = normalized.returnPolicy,
        }
    end

    local volume = normalized.width * normalized.length * normalized.layers
    local returnMoves = boxReturnAllowance(normalized)
    return {
        schema = Industrial.SCHEMA,
        type = normalized.type,
        spec = normalized,
        volume = volume,
        area = normalized.width * normalized.length,
        workMoves = volume,
        returnMoves = returnMoves,
        estimatedMoves = volume + returnMoves,
        fuelReserve = Industrial.FUEL_RESERVE,
        fuelRequired = volume + returnMoves + Industrial.FUEL_RESERVE,
        workSlots = Industrial.WORK_SLOT_LAST - Industrial.WORK_SLOT_FIRST + 1,
        checkpointEvery = 1,
        returnPolicy = normalized.returnPolicy,
        path = "serpentine",
    }
end

-- Return the zero-origin logical cell for a 1-based excavation index. The path
-- reverses on alternating layers so the last cell of one layer is directly
-- above the first cell of the next layer. Consecutive cells are Manhattan-adjacent.
function Industrial.cellAt(spec, index)
    local normalized, err = Industrial.normalizeSpec(spec)
    if not normalized then return nil, err end
    if normalized.type == Industrial.TYPE_TUNNEL then return nil, "cell_path_not_tunnel" end

    local i, indexErr = integer(index, "index", 1, normalized.width * normalized.length * normalized.layers)
    if not i then return nil, indexErr end
    i = i - 1

    local area = normalized.width * normalized.length
    local layer = math.floor(i / area)
    local inLayer = i % area
    local pathIndex = layer % 2 == 0 and inLayer or (area - 1 - inLayer)
    local row = math.floor(pathIndex / normalized.length)
    local col = pathIndex % normalized.length
    local z = row % 2 == 0 and col or (normalized.length - 1 - col)

    return {x = row, y = -layer, z = z, index = index}
end

local function poseCopy(pose)
    pose = type(pose) == "table" and pose or {}
    return {
        x = tonumber(pose.x) or 0,
        y = tonumber(pose.y) or 0,
        z = tonumber(pose.z) or 0,
        heading = math.floor(tonumber(pose.heading) or 0) % 4,
        frame = tostring(pose.frame or ""),
    }
end

function Industrial.newCheckpoint(jobId, spec, pose)
    local plan, err = Industrial.plan(spec)
    if not plan then return nil, err end
    local id = tostring(jobId or "")
    if id == "" then return nil, "job_id_required" end

    local phase = plan.type == Industrial.TYPE_TUNNEL and "OUT" or "WORK"
    return {
        schema = Industrial.CHECKPOINT_SCHEMA,
        engineVersion = Industrial.VERSION,
        jobId = id,
        type = plan.type,
        spec = copyTable(plan.spec),
        plan = {
            volume = plan.volume,
            workMoves = plan.workMoves,
            returnMoves = plan.returnMoves,
            estimatedMoves = plan.estimatedMoves,
            fuelRequired = plan.fuelRequired,
            fuelReserve = plan.fuelReserve,
        },
        phase = phase,
        progress = {
            completed = 0,
            returned = 0,
            cursor = 0,
            layer = 0,
        },
        origin = poseCopy(pose),
        pose = poseCopy(pose),
        stats = {
            moves = 0,
            digs = 0,
            unloaded = 0,
            refuels = 0,
            recoveries = 0,
        },
        reason = "",
        savedAt = nowMs(),
    }
end

function Industrial.normalizeCheckpoint(value)
    if type(value) ~= "table" then return nil, "checkpoint_required" end
    if tonumber(value.schema) ~= Industrial.CHECKPOINT_SCHEMA then return nil, "checkpoint_schema" end
    local plan, err = Industrial.plan(value.spec or {})
    if not plan then return nil, "checkpoint_" .. tostring(err) end
    if tostring(value.jobId or "") == "" then return nil, "checkpoint_job_id" end
    if tostring(value.type or "") ~= plan.type then return nil, "checkpoint_type" end

    local progress = type(value.progress) == "table" and value.progress or {}
    local completed = math.max(0, math.floor(tonumber(progress.completed) or 0))
    local returned = math.max(0, math.floor(tonumber(progress.returned) or 0))
    if completed > plan.workMoves then completed = plan.workMoves end
    if returned > plan.returnMoves then returned = plan.returnMoves end

    local phase = tostring(value.phase or "")
    local allowed
    if plan.type == Industrial.TYPE_TUNNEL then
        allowed = {OUT=true, RETURN=true, DONE=true, FAILED=true}
    else
        allowed = {WORK=true, UNLOAD=true, REFUEL=true, RETURN=true, DONE=true, FAILED=true}
    end
    if not allowed[phase] then return nil, "checkpoint_phase" end

    local out = copyTable(value)
    out.schema = Industrial.CHECKPOINT_SCHEMA
    out.engineVersion = tostring(value.engineVersion or Industrial.VERSION)
    out.type = plan.type
    out.spec = copyTable(plan.spec)
    out.plan = {
        volume = plan.volume,
        workMoves = plan.workMoves,
        returnMoves = plan.returnMoves,
        estimatedMoves = plan.estimatedMoves,
        fuelRequired = plan.fuelRequired,
        fuelReserve = plan.fuelReserve,
    }
    out.phase = phase
    out.progress = {
        completed = completed,
        returned = returned,
        cursor = math.max(0, math.floor(tonumber(progress.cursor) or completed)),
        layer = math.max(0, math.floor(tonumber(progress.layer) or 0)),
    }
    out.origin = poseCopy(value.origin)
    out.pose = poseCopy(value.pose)
    out.stats = type(value.stats) == "table" and copyTable(value.stats) or {}
    out.stats.moves = math.max(0, math.floor(tonumber(out.stats.moves) or 0))
    out.stats.digs = math.max(0, math.floor(tonumber(out.stats.digs) or 0))
    out.stats.unloaded = math.max(0, math.floor(tonumber(out.stats.unloaded) or 0))
    out.stats.refuels = math.max(0, math.floor(tonumber(out.stats.refuels) or 0))
    out.stats.recoveries = math.max(0, math.floor(tonumber(out.stats.recoveries) or 0))
    out.reason = tostring(value.reason or "")
    out.savedAt = math.floor(tonumber(value.savedAt) or nowMs())
    return out
end

function Industrial.inventorySummary(slotCounts, options)
    options = type(options) == "table" and options or {}
    local first = math.max(1, math.floor(tonumber(options.firstSlot) or Industrial.WORK_SLOT_FIRST))
    local last = math.min(16, math.floor(tonumber(options.lastSlot) or Industrial.WORK_SLOT_LAST))
    if last < first then return nil, "slot_range" end

    local totalSlots, freeSlots, usedSlots, itemCount = 0, 0, 0, 0
    for slot = first, last do
        totalSlots = totalSlots + 1
        local count
        if type(slotCounts) == "function" then
            local ok, value = pcall(slotCounts, slot)
            count = ok and tonumber(value) or 0
        elseif type(slotCounts) == "table" then
            count = tonumber(slotCounts[slot]) or 0
        else
            count = 0
        end
        count = math.max(0, math.floor(count))
        if count == 0 then freeSlots = freeSlots + 1 else usedSlots = usedSlots + 1 end
        itemCount = itemCount + count
    end

    local minFree = math.max(0, math.floor(tonumber(options.minFreeSlots) or Industrial.MIN_FREE_WORK_SLOTS))
    return {
        firstSlot = first,
        lastSlot = last,
        totalSlots = totalSlots,
        freeSlots = freeSlots,
        usedSlots = usedSlots,
        itemCount = itemCount,
        pressure = totalSlots > 0 and (usedSlots / totalSlots) or 1,
        full = freeSlots == 0,
        shouldUnload = freeSlots <= minFree,
        minFreeSlots = minFree,
    }
end

function Industrial.fuelStatus(currentFuel, planOrSpec)
    if currentFuel == "unlimited" then
        return {unlimited=true, current=currentFuel, required=0, shortfall=0, ready=true}
    end
    local fuel = tonumber(currentFuel)
    if not fuel then return nil, "fuel_unknown" end

    local plan = planOrSpec
    if type(plan) ~= "table" or tonumber(plan.fuelRequired) == nil then
        local err
        plan, err = Industrial.plan(planOrSpec)
        if not plan then return nil, err end
    end
    local required = math.max(0, math.floor(tonumber(plan.fuelRequired) or 0))
    return {
        unlimited = false,
        current = math.floor(fuel),
        required = required,
        shortfall = math.max(0, required - math.floor(fuel)),
        ready = fuel >= required,
    }
end

function Industrial.progress(checkpoint)
    local cp, err = Industrial.normalizeCheckpoint(checkpoint)
    if not cp then return nil, err end
    local total = math.max(1, tonumber(cp.plan.workMoves) or 1)
    local done = math.max(0, tonumber(cp.progress.completed) or 0)
    return math.max(0, math.min(1, done / total))
end

function Industrial.selfTest()
    local failures = {}
    local function expect(name, condition)
        if not condition then failures[#failures + 1] = name end
    end

    local tunnel = Industrial.plan({type="tunnel", distance=100, stepDelay=0.15})
    expect("tunnel_plan", tunnel and tunnel.estimatedMoves == 200 and tunnel.fuelRequired == 264)

    local box = Industrial.plan({type="excavate_box", width=2, length=3, height=2, stepDelay=0.15})
    expect("box_plan", box and box.volume == 12 and box.workMoves == 12)
    if box then
        local seen = {}
        local previous
        for i = 1, box.volume do
            local cell = Industrial.cellAt(box.spec, i)
            expect("box_cell_" .. i, type(cell) == "table")
            if cell then
                local key = table.concat({cell.x, cell.y, cell.z}, ":")
                expect("box_unique_" .. i, not seen[key])
                seen[key] = true
                if previous then
                    local d = math.abs(cell.x-previous.x) + math.abs(cell.y-previous.y) + math.abs(cell.z-previous.z)
                    expect("box_adjacent_" .. i, d == 1)
                end
                previous = cell
            end
        end
    end

    local cp = Industrial.newCheckpoint("test-job", {type="quarry", width=3, length=4, depth=2}, {x=1,y=2,z=3,heading=1,frame="test"})
    local normalized = cp and Industrial.normalizeCheckpoint(cp)
    expect("checkpoint", normalized and normalized.jobId == "test-job" and normalized.plan.volume == 24)

    local inv = Industrial.inventorySummary({[5]=64,[6]=1})
    expect("inventory", inv and inv.totalSlots == 12 and inv.freeSlots == 10 and inv.shouldUnload == false)

    return #failures == 0, failures
end

return Industrial
