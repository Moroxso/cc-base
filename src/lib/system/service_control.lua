local Supervisor = require("lib.system.service_supervisor")

local Control = {}

local function getDescriptor(supervisor, id)
    if type(supervisor) ~= "table" or type(supervisor.services) ~= "table" then
        return nil, "supervisor_unavailable"
    end

    local descriptor = supervisor.services[tostring(id or "")]
    if not descriptor then
        return nil, "service_not_found:" .. tostring(id)
    end

    return descriptor
end

local function setDesired(supervisor, descriptor, desired)
    descriptor.record.desired = desired
    descriptor.record.changedAt = os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000)
    supervisor:writeStatus()
end

local function startRecursive(supervisor, id, visited)
    visited = visited or {}
    if visited[id] then return true end
    visited[id] = true

    local descriptor, err = getDescriptor(supervisor, id)
    if not descriptor then return false, err end

    for _, dependency in ipairs(descriptor.dependencies or {}) do
        local ok, dependencyError = startRecursive(supervisor, dependency, visited)
        if not ok then return false, dependencyError end
    end

    descriptor.enabled = true
    descriptor.halted = false
    setDesired(supervisor, descriptor, "RUNNING")

    if descriptor.record.state == Supervisor.STATE_STOPPED
        or descriptor.record.state == Supervisor.STATE_FAILED
    then
        supervisor:_setState(
            descriptor,
            Supervisor.STATE_STARTING,
            "manual_start"
        )
    end

    os.queueEvent("ccbase_supervisor_wakeup", descriptor.id)
    return true
end

function Control.start(supervisor, id)
    if type(supervisor) ~= "table" or not supervisor.running then
        return false, "supervisor_not_running"
    end

    return startRecursive(supervisor, tostring(id or ""), {})
end

function Control.stop(supervisor, id)
    if type(supervisor) ~= "table" or not supervisor.running then
        return false, "supervisor_not_running"
    end

    local descriptor, err = getDescriptor(supervisor, id)
    if not descriptor then return false, err end

    descriptor.enabled = false
    descriptor.halted = false
    descriptor.forceRestart = nil
    setDesired(supervisor, descriptor, "STOPPED")

    supervisor:_restartDependents(descriptor.id)
    supervisor:_stopInstance(descriptor)
    supervisor:_setState(
        descriptor,
        Supervisor.STATE_STOPPED,
        "manual_stop",
        ""
    )

    return true
end

function Control.restart(supervisor, id)
    if type(supervisor) ~= "table" or not supervisor.running then
        return false, "supervisor_not_running"
    end

    local descriptor, err = getDescriptor(supervisor, id)
    if not descriptor then return false, err end

    local dependenciesOk, dependencyError = startRecursive(
        supervisor,
        descriptor.id,
        {}
    )
    if not dependenciesOk then return false, dependencyError end

    local state = descriptor.record.state
    local active = state == Supervisor.STATE_RUNNING
        or state == Supervisor.STATE_STARTING
        or state == Supervisor.STATE_RESTARTING

    if active then
        descriptor.forceRestart = "manual_restart"
        descriptor.record.restarts = descriptor.record.restarts + 1
        supervisor:_setState(
            descriptor,
            Supervisor.STATE_RESTARTING,
            "manual_restart"
        )
        supervisor:_restartDependents(descriptor.id)
        supervisor:_stopInstance(descriptor)
    else
        supervisor:_setState(
            descriptor,
            Supervisor.STATE_STARTING,
            "manual_restart"
        )
        os.queueEvent("ccbase_supervisor_wakeup", descriptor.id)
    end

    return true
end

function Control.get(supervisor, id)
    local descriptor, err = getDescriptor(supervisor, id)
    if not descriptor then return nil, err end

    local record = descriptor.record
    return {
        id = record.id,
        label = record.label,
        state = record.state,
        desired = record.desired,
        restartPolicy = record.restartPolicy,
        dependencies = record.dependencies,
        starts = record.starts,
        restarts = record.restarts,
        failures = record.failures,
        detail = record.detail,
        lastError = record.lastError
    }
end

return Control
