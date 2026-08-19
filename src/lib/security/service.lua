local Integrity = require("lib.security.integrity")

local SecurityService = {}
SecurityService.__index = SecurityService

local SCAN_SECONDS = 3

function SecurityService.new()
    local self = setmetatable({}, SecurityService)

    self.running = false
    self.lastSignature = nil

    return self
end

local function signature(status)
    local parts = {}

    for _, item in ipairs(status and status.issues or {}) do
        table.insert(parts, tostring(item.kind) .. ":" .. tostring(item.path))
    end

    return table.concat(parts, "|")
end

function SecurityService:scan(announce)
    local status = Integrity.scan()
    status.quarantineCount = Integrity.quarantineCount()

    Integrity.writeStatus(status)

    local currentSignature = signature(status)

    if not status.ok then
        Integrity.appendLog(status)
    end

    if currentSignature ~= self.lastSignature then
        self.lastSignature = currentSignature

        os.queueEvent(
            "ccbase_security_state",
            status.ok == true,
            #(status.issues or {}),
            status.projectVersion or "unknown"
        )
    end

    if announce then
        os.queueEvent(
            "ccbase_security_scan_result",
            status.ok == true,
            #(status.issues or {}),
            status.projectVersion or "unknown"
        )
    end

    return status
end

function SecurityService:run()
    self.running = true
    self:scan(false)

    local timer = os.startTimer(SCAN_SECONDS)

    while self.running do
        local event, a, b = os.pullEvent()

        if event == "timer" and a == timer then
            self:scan(false)
            timer = os.startTimer(SCAN_SECONDS)

        elseif event == "ccbase_security_scan" then
            self:scan(true)

        elseif event == "ccbase_security_quarantine" then
            local ok, detail = Integrity.quarantineUnexpected(a)

            os.queueEvent(
                "ccbase_security_quarantine_result",
                ok == true,
                detail or "unknown",
                a or ""
            )

            self:scan(false)

        elseif event == "ccbase_security_clear_log" then
            local ok, err = Integrity.clearLog()

            os.queueEvent(
                "ccbase_security_log_cleared",
                ok == true,
                err or "cleared"
            )

        elseif event == "ccbase_security_quarantine_payload" then
            local id, detail = Integrity.quarantineContent(a, b, {
                source = "network",
                reason = "network_payload"
            })

            os.queueEvent(
                "ccbase_security_payload_result",
                id ~= nil,
                id or detail or "unknown"
            )
        end
    end
end

function SecurityService:stop()
    self.running = false
end

return SecurityService
