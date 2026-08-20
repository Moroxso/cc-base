local Supervisor = {}
Supervisor.__index = Supervisor

Supervisor.SCHEMA = 1
Supervisor.DEFAULT_STATUS_PATH = "/data/system/services.json"
Supervisor.HISTORY_LIMIT = 24
Supervisor.RESTART_BASE_SECONDS = 0.5
Supervisor.RESTART_MAX_SECONDS = 8
Supervisor.HEALTHY_RESET_MS = 30000

Supervisor.STATE_STOPPED = "STOPPED"
Supervisor.STATE_STARTING = "STARTING"
Supervisor.STATE_RUNNING = "RUNNING"
Supervisor.STATE_FAILED = "FAILED"
Supervisor.STATE_RESTARTING = "RESTARTING"

local VALID_POLICIES = {
    always = true,
    ["on-failure"] = true,
    no = true
}

local function nowMs()
    if os.epoch then
        return os.epoch("utc")
    end

    return math.floor(os.clock() * 1000)
end

local function validId(value)
    return type(value) == "string"
        and value ~= ""
        and value:match("^[a-z0-9][a-z0-9%._%-]*$") ~= nil
end

local function copyArray(value)
    local result = {}

    for index, item in ipairs(value or {}) do
        result[index] = item
    end

    return result
end

local function ensureParent(path)
    local parent = fs.getDir(path)

    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then
        return nil
    end

    local file = fs.open(path, "r")

    if not file then
        return nil
    end

    local raw = file.readAll()
    file.close()

    local ok, value = pcall(textutils.unserializeJSON, raw)

    if not ok or type(value) ~= "table" then
        return nil
    end

    return value
end

local function writeAtomicJson(path, value)
    local ok, raw = pcall(textutils.serializeJSON, value)

    if not ok or type(raw) ~= "string" then
        return false, "service_status_serialize_failed"
    end

    ensureParent(path)

    local temp = path .. ".tmp"
    local backup = path .. ".bak"

    if fs.exists(temp) then
        pcall(fs.delete, temp)
    end

    local file = fs.open(temp, "w")

    if not file then
        return false, "service_status_temp_open_failed"
    end

    local writeOk, writeError = pcall(function()
        file.write(raw)
    end)

    pcall(function()
        file.close()
    end)

    if not writeOk then
        if fs.exists(temp) then
            pcall(fs.delete, temp)
        end

        return false, "service_status_write_failed:" .. tostring(writeError)
    end

    if type(readJson(temp)) ~= "table" then
        pcall(fs.delete, temp)
        return false, "service_status_temp_invalid"
    end

    if fs.exists(backup) then
        pcall(fs.delete, backup)
    end

    if fs.exists(path) then
        local moved, moveError = pcall(fs.move, path, backup)

        if not moved then
            pcall(fs.delete, temp)
            return false, "service_status_backup_failed:" .. tostring(moveError)
        end
    end

    local committed, commitError = pcall(fs.move, temp, path)

    if not committed then
        if fs.exists(backup) and not fs.exists(path) then
            pcall(fs.move, backup, path)
        end

        return false, "service_status_commit_failed:" .. tostring(commitError)
    end

    if type(readJson(path)) ~= "table" then
        if fs.exists(path) then
            pcall(fs.delete, path)
        end

        if fs.exists(backup) then
            pcall(fs.move, backup, path)
        end

        return false, "service_status_commit_invalid"
    end

    if fs.exists(backup) then
        pcall(fs.delete, backup)
    end

    return true
end

function Supervisor.new(options)
    options = type(options) == "table" and options or {}

    return setmetatable({
        statusPath = options.statusPath or Supervisor.DEFAULT_STATUS_PATH,
        services = {},
        order = {},
        history = {},
        running = false,
        lastStatusError = nil
    }, Supervisor)
end

function Supervisor:register(spec)
    if self.running then
        return false, "service_register_while_running"
    end

    if type(spec) ~= "table" or not validId(spec.id) then
        return false, "service_spec_invalid"
    end

    if self.services[spec.id] then
        return false, "service_duplicate:" .. spec.id
    end

    local instance = spec.instance
    local run = spec.run
    local stop = spec.stop

    if run == nil and type(instance) == "table" and type(instance.run) == "function" then
        run = function()
            return instance:run()
        end
    end

    if stop == nil and type(instance) == "table" and type(instance.stop) == "function" then
        stop = function()
            return instance:stop()
        end
    end

    if type(run) ~= "function" then
        return false, "service_run_missing:" .. spec.id
    end

    local policy = tostring(spec.restartPolicy or "always")

    if not VALID_POLICIES[policy] then
        return false, "service_restart_policy_invalid:" .. spec.id
    end

    local dependencies = {}
    local seenDependencies = {}

    for _, dependency in ipairs(spec.dependencies or {}) do
        if not validId(dependency) or dependency == spec.id then
            return false, "service_dependency_invalid:" .. spec.id
        end

        if seenDependencies[dependency] then
            return false, "service_dependency_duplicate:" .. spec.id .. ":" .. dependency
        end

        seenDependencies[dependency] = true
        dependencies[#dependencies + 1] = dependency
    end

    local descriptor = {
        id = spec.id,
        label = tostring(spec.label or spec.id),
        instance = instance,
        run = run,
        stop = type(stop) == "function" and stop or nil,
        restartPolicy = policy,
        dependencies = dependencies,
        enabled = spec.enabled ~= false,
        halted = false,
        forceRestart = nil,
        consecutiveFailures = 0,
        record = {
            id = spec.id,
            label = tostring(spec.label or spec.id),
            state = Supervisor.STATE_STOPPED,
            desired = spec.enabled == false and "STOPPED" or "RUNNING",
            restartPolicy = policy,
            dependencies = copyArray(dependencies),
            starts = 0,
            restarts = 0,
            failures = 0,
            changedAt = nowMs(),
            startedAt = nil,
            lastExitAt = nil,
            lastError = "",
            detail = "registered"
        }
    }

    self.services[descriptor.id] = descriptor
    self.order[#self.order + 1] = descriptor.id

    return true
end

function Supervisor:validate()
    local state = {}
    local stack = {}
    local positions = {}

    local function visit(id)
        if state[id] == 2 then
            return true
        end

        if state[id] == 1 then
            local cycle = {}
            local first = positions[id] or 1

            for index = first, #stack do
                cycle[#cycle + 1] = stack[index]
            end

            cycle[#cycle + 1] = id
            return false, "service_dependency_cycle:" .. table.concat(cycle, "->")
        end

        local descriptor = self.services[id]

        if not descriptor then
            return false, "service_dependency_missing:" .. tostring(id)
        end

        state[id] = 1
        stack[#stack + 1] = id
        positions[id] = #stack

        for _, dependency in ipairs(descriptor.dependencies) do
            if not self.services[dependency] then
                return false, "service_dependency_missing:" .. id .. ":" .. dependency
            end

            local ok, err = visit(dependency)

            if not ok then
                return false, err
            end
        end

        positions[id] = nil
        stack[#stack] = nil
        state[id] = 2
        return true
    end

    for _, id in ipairs(self.order) do
        local ok, err = visit(id)

        if not ok then
            return false, err
        end
    end

    return true
end

function Supervisor:_appendHistory(record)
    self.history[#self.history + 1] = {
        service = record.id,
        state = record.state,
        detail = record.detail,
        at = record.changedAt
    }

    while #self.history > Supervisor.HISTORY_LIMIT do
        table.remove(self.history, 1)
    end
end

function Supervisor:summary()
    local result = {
        total = #self.order,
        running = 0,
        starting = 0,
        failed = 0,
        restarting = 0,
        stopped = 0
    }

    for _, id in ipairs(self.order) do
        local state = self.services[id].record.state

        if state == Supervisor.STATE_RUNNING then
            result.running = result.running + 1
        elseif state == Supervisor.STATE_STARTING then
            result.starting = result.starting + 1
        elseif state == Supervisor.STATE_FAILED then
            result.failed = result.failed + 1
        elseif state == Supervisor.STATE_RESTARTING then
            result.restarting = result.restarting + 1
        else
            result.stopped = result.stopped + 1
        end
    end

    return result
end

function Supervisor:snapshot()
    local result = {}

    for _, id in ipairs(self.order) do
        local descriptor = self.services[id]
        local record = descriptor.record
        local runtimeError = nil

        if type(descriptor.instance) == "table" and descriptor.instance.lastError ~= nil then
            runtimeError = tostring(descriptor.instance.lastError)
        end

        result[#result + 1] = {
            id = record.id,
            label = record.label,
            state = record.state,
            desired = record.desired,
            restartPolicy = record.restartPolicy,
            dependencies = copyArray(record.dependencies),
            starts = record.starts,
            restarts = record.restarts,
            failures = record.failures,
            changedAt = record.changedAt,
            startedAt = record.startedAt,
            lastExitAt = record.lastExitAt,
            lastError = record.lastError,
            runtimeError = runtimeError,
            detail = record.detail
        }
    end

    return result
end

function Supervisor:writeStatus()
    local ok, err = writeAtomicJson(self.statusPath, {
        schema = Supervisor.SCHEMA,
        running = self.running,
        updatedAt = nowMs(),
        summary = self:summary(),
        services = self:snapshot(),
        history = self.history
    })

    if not ok then
        self.lastStatusError = err
        return false, err
    end

    self.lastStatusError = nil
    return true
end

function Supervisor:_setState(descriptor, state, detail, lastError)
    local record = descriptor.record
    detail = tostring(detail or "")
    lastError = lastError ~= nil and tostring(lastError) or record.lastError

    if record.state == state and record.detail == detail and record.lastError == lastError then
        return
    end

    record.state = state
    record.detail = detail
    record.lastError = lastError
    record.changedAt = nowMs()

    if state == Supervisor.STATE_RUNNING then
        record.startedAt = record.changedAt
    elseif state == Supervisor.STATE_FAILED or state == Supervisor.STATE_STOPPED then
        record.lastExitAt = record.changedAt
    end

    self:_appendHistory(record)
    self:writeStatus()

    os.queueEvent(
        "ccbase_service_state",
        descriptor.id,
        state,
        detail,
        record.failures,
        record.restarts
    )
end

function Supervisor:_stopInstance(descriptor)
    if descriptor.stop then
        pcall(descriptor.stop)
    end

    os.queueEvent("ccbase_supervisor_wakeup", descriptor.id)
end

function Supervisor:_restartDependents(failedId, visited)
    visited = visited or {}

    if visited[failedId] then
        return
    end

    visited[failedId] = true

    for _, id in ipairs(self.order) do
        local descriptor = self.services[id]
        local state = descriptor.record.state
        local active = state == Supervisor.STATE_RUNNING
            or state == Supervisor.STATE_STARTING

        if descriptor.enabled and active then
            for _, dependency in ipairs(descriptor.dependencies) do
                if dependency == failedId then
                    descriptor.forceRestart = "dependency:" .. failedId
                    descriptor.record.restarts = descriptor.record.restarts + 1
                    self:_setState(
                        descriptor,
                        Supervisor.STATE_RESTARTING,
                        descriptor.forceRestart
                    )
                    self:_stopInstance(descriptor)
                    self:_restartDependents(descriptor.id, visited)
                    break
                end
            end
        end
    end
end

function Supervisor:_dependenciesReady(descriptor)
    local missing = {}

    for _, dependency in ipairs(descriptor.dependencies) do
        local dependencyDescriptor = self.services[dependency]

        if not dependencyDescriptor
            or not dependencyDescriptor.enabled
            or dependencyDescriptor.record.state ~= Supervisor.STATE_RUNNING
        then
            missing[#missing + 1] = dependency
        end
    end

    return #missing == 0, missing
end

function Supervisor:_waitForDependencies(descriptor)
    while self.running and descriptor.enabled do
        local ready, missing = self:_dependenciesReady(descriptor)

        if ready then
            return true
        end

        self:_setState(
            descriptor,
            Supervisor.STATE_STARTING,
            "waiting:" .. table.concat(missing, ",")
        )
        sleep(0.25)
    end

    return false
end

function Supervisor:_restartDelay(descriptor, uptimeMs)
    if uptimeMs and uptimeMs >= Supervisor.HEALTHY_RESET_MS then
        descriptor.consecutiveFailures = 0
    end

    local exponent = math.max(0, math.min(descriptor.consecutiveFailures - 1, 4))
    local delay = Supervisor.RESTART_BASE_SECONDS * (2 ^ exponent)

    return math.min(delay, Supervisor.RESTART_MAX_SECONDS)
end

function Supervisor:_runOne(descriptor)
    while self.running do
        if not descriptor.enabled or descriptor.halted then
            local detail = descriptor.halted and "halted" or "disabled"
            self:_setState(descriptor, Supervisor.STATE_STOPPED, detail)
            sleep(0.25)
        else
            local dependenciesReady = self:_waitForDependencies(descriptor)

            if dependenciesReady and self.running and descriptor.enabled then
                descriptor.forceRestart = nil
                descriptor.record.starts = descriptor.record.starts + 1
                self:_setState(descriptor, Supervisor.STATE_STARTING, "launching", "")
                self:_setState(descriptor, Supervisor.STATE_RUNNING, "active", "")

                local startedAt = nowMs()
                local ok, err = pcall(descriptor.run)
                local uptimeMs = math.max(0, nowMs() - startedAt)
                local forcedRestart = descriptor.forceRestart
                descriptor.forceRestart = nil

                if not ok then
                    self:_stopInstance(descriptor)
                end

                if not self.running then
                    self:_setState(descriptor, Supervisor.STATE_STOPPED, "supervisor_stopping")
                    return
                elseif not descriptor.enabled then
                    self:_setState(descriptor, Supervisor.STATE_STOPPED, "disabled")
                elseif forcedRestart then
                    self:_setState(descriptor, Supervisor.STATE_RESTARTING, forcedRestart)
                    sleep(0.25)
                elseif ok then
                    if descriptor.restartPolicy == "always" then
                        descriptor.record.failures = descriptor.record.failures + 1
                        descriptor.consecutiveFailures = descriptor.consecutiveFailures + 1
                        self:_setState(
                            descriptor,
                            Supervisor.STATE_FAILED,
                            "unexpected_exit",
                            "service returned while enabled"
                        )
                        self:_restartDependents(descriptor.id)
                        descriptor.record.restarts = descriptor.record.restarts + 1
                        local delay = self:_restartDelay(descriptor, uptimeMs)
                        self:_setState(
                            descriptor,
                            Supervisor.STATE_RESTARTING,
                            string.format("retry_in:%.2fs", delay)
                        )
                        sleep(delay)
                    else
                        descriptor.consecutiveFailures = 0
                        self:_setState(descriptor, Supervisor.STATE_STOPPED, "exited", "")
                    end
                else
                    descriptor.record.failures = descriptor.record.failures + 1
                    descriptor.consecutiveFailures = descriptor.consecutiveFailures + 1
                    self:_setState(
                        descriptor,
                        Supervisor.STATE_FAILED,
                        "runtime_error",
                        tostring(err)
                    )
                    self:_restartDependents(descriptor.id)

                    if descriptor.restartPolicy == "always"
                        or descriptor.restartPolicy == "on-failure"
                    then
                        descriptor.record.restarts = descriptor.record.restarts + 1
                        local delay = self:_restartDelay(descriptor, uptimeMs)
                        self:_setState(
                            descriptor,
                            Supervisor.STATE_RESTARTING,
                            string.format("retry_in:%.2fs", delay)
                        )
                        sleep(delay)
                    else
                        descriptor.halted = true
                    end
                end
            end
        end
    end

    self:_setState(descriptor, Supervisor.STATE_STOPPED, "supervisor_stopping")
end

function Supervisor:run()
    local valid, validationError = self:validate()

    if not valid then
        error(validationError, 0)
    end

    self.running = true
    self:writeStatus()

    local workers = {}

    for _, id in ipairs(self.order) do
        local descriptor = self.services[id]

        workers[#workers + 1] = function()
            while self.running do
                local ok, err = pcall(function()
                    self:_runOne(descriptor)
                end)

                if not ok and self.running then
                    descriptor.record.failures = descriptor.record.failures + 1
                    descriptor.record.restarts = descriptor.record.restarts + 1
                    descriptor.consecutiveFailures = descriptor.consecutiveFailures + 1
                    self:_setState(
                        descriptor,
                        Supervisor.STATE_FAILED,
                        "supervisor_worker_error",
                        tostring(err)
                    )
                    self:_restartDependents(descriptor.id)
                    sleep(self:_restartDelay(descriptor, 0))
                else
                    break
                end
            end
        end
    end

    parallel.waitForAll(table.unpack(workers))
    self.running = false
    self:writeStatus()
end

function Supervisor:stop()
    if not self.running then
        return
    end

    self.running = false

    for _, id in ipairs(self.order) do
        local descriptor = self.services[id]
        self:_stopInstance(descriptor)
        self:_setState(descriptor, Supervisor.STATE_STOPPED, "supervisor_stopping")
    end

    self:writeStatus()
end

function Supervisor.loadStatus(path)
    path = path or Supervisor.DEFAULT_STATUS_PATH
    local value = readJson(path)

    if type(value) ~= "table" or value.schema ~= Supervisor.SCHEMA then
        return nil, "service_status_unavailable"
    end

    return value
end

return Supervisor
