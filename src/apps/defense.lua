local ui = require("lib.ui")

local TITLE = "BASE DEFENSE CONTROL"
local STATUS_PATH = "/data/defense/status.json"

local running = true
local selected = 1
local offset = 1
local message = "Defense controller ready."
local status = nil

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
    return ok and type(value) == "table" and value or nil
end

local function truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

local function refresh()
    status = readJson(STATUS_PATH) or {
        running = false,
        controllerId = os.getComputerID(),
        mode = "SAFE",
        totalUnits = 0,
        onlineUnits = 0,
        pendingCount = 0,
        units = {},
        pending = {},
        lastError = "status_unavailable"
    }
end

local function rows()
    local result = {}

    for _, item in ipairs(status.pending or {}) do
        result[#result + 1] = {
            kind = "pending",
            id = item.id,
            name = item.name,
            code = item.code,
            online = false
        }
    end

    for _, item in ipairs(status.units or {}) do
        result[#result + 1] = {
            kind = "unit",
            id = item.id,
            name = item.name,
            online = item.online == true,
            mode = item.mode,
            state = item.state,
            fuel = item.fuel,
            fuelLimit = item.fuelLimit,
            lastResult = item.lastResult
        }
    end

    table.sort(result, function(a, b)
        if a.kind ~= b.kind then
            return a.kind == "pending"
        end
        return tonumber(a.id) < tonumber(b.id)
    end)

    return result
end

local function selectedRow()
    local list = rows()
    if #list == 0 then return nil end
    selected = math.max(1, math.min(selected, #list))
    return list[selected]
end

local function line(y, text, color)
    local width = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(color or colors.white)
    term.setCursorPos(1, y)
    term.write(string.rep(" ", width))
    term.setCursorPos(2, y)
    term.write(truncate(text, width - 2))
end

local function modeColor(mode)
    if mode == "SAFE" then return colors.lime end
    if mode == "ARMED" then return colors.orange end
    if mode == "LOCKDOWN" then return colors.red end
    return colors.lightGray
end

local function draw()
    refresh()

    local width, height = term.getSize()
    ui.drawHeader(TITLE)

    line(
        4,
        string.format(
            "MODE %-8s  CTRL %s  UNITS %d/%d  PENDING %d",
            tostring(status.mode or "SAFE"),
            tostring(status.controllerId or "?"),
            tonumber(status.onlineUnits) or 0,
            tonumber(status.totalUnits) or 0,
            tonumber(status.pendingCount) or 0
        ),
        modeColor(status.mode)
    )

    line(
        5,
        "1 SAFE   2 ARMED   3 LOCKDOWN   C CONFIRM   X REVOKE",
        colors.lightGray
    )

    local list = rows()
    if #list == 0 then
        line(8, "No defense units. Start defense_agent on a turtle.", colors.yellow)
        line(9, "Its pairing request and 6-digit code will appear here.", colors.lightGray)
    else
        local firstRow = 7
        local lastRow = math.max(firstRow, height - 6)
        local visible = lastRow - firstRow + 1

        selected = math.max(1, math.min(selected, #list))
        if selected < offset then offset = selected end
        if selected > offset + visible - 1 then
            offset = selected - visible + 1
        end
        offset = math.max(1, offset)

        for row = firstRow, lastRow do
            local index = offset + (row - firstRow)
            local item = list[index]

            term.setBackgroundColor(index == selected and colors.lightBlue or colors.black)
            term.setTextColor(index == selected and colors.black or colors.white)
            term.setCursorPos(1, row)
            term.write(string.rep(" ", width))

            if item then
                local text
                if item.kind == "pending" then
                    text = string.format(
                        "[PAIR] #%s %-14s CODE %s",
                        tostring(item.id),
                        tostring(item.name or "unit"),
                        tostring(item.code or "??????")
                    )
                else
                    local online = item.online and "ON " or "OFF"
                    local fuel = item.fuel
                    local fuelText = fuel == "unlimited" and "INF" or tostring(fuel or "?")
                    text = string.format(
                        "[%s] #%s %-12s %-8s %-12s F:%s",
                        online,
                        tostring(item.id),
                        tostring(item.name or "unit"):sub(1, 12),
                        tostring(item.mode or "?"),
                        tostring(item.state or "?"):sub(1, 12),
                        fuelText
                    )
                end

                term.setCursorPos(2, row)
                term.write(truncate(text, width - 2))
            end
        end
    end

    local row = selectedRow()
    if row and row.kind == "pending" then
        line(height - 5, "Compare CODE with turtle, then press C to enroll.", colors.cyan)
    elseif row and row.kind == "unit" then
        line(
            height - 5,
            "A ATTACK  Q/E TURN  W/S MOVE  R/F UP/DOWN   Alpha1 manual only",
            status.mode == "SAFE" and colors.gray or colors.orange
        )
    else
        line(height - 5, "Alpha1: manual sentry control; lost controller link => SAFE.", colors.lightGray)
    end

    line(height - 4, message, colors.yellow)

    local err = tostring(status.lastError or "")
    if err ~= "" then
        line(height - 3, "Controller: " .. err, colors.red)
    else
        line(height - 3, "Link fail-safe: 6.5s without controller beacon => turtle SAFE.", colors.lightGray)
    end

    ui.drawFooter("UP/DOWN SELECT  1/2/3 MODE  C PAIR  X REVOKE  SHIFT BACK")
end

local function confirm(text)
    local _, height = term.getSize()
    line(height - 4, text .. "  Y=CONFIRM N=CANCEL", colors.orange)

    while true do
        local event, value = os.pullEvent()
        if event == "char" then
            value = string.lower(tostring(value or ""))
            if value == "y" then return true end
            if value == "n" then return false end
        elseif event == "key" then
            if value == keys.y then return true end
            if value == keys.n or value == keys.escape or value == keys.left or value == keys.enter then
                return false
            end
        end
    end
end

local function setMode(mode)
    if mode ~= "SAFE" and not confirm("Set defense mode " .. mode .. "?") then
        message = "Mode change cancelled."
        return
    end

    os.queueEvent("ccbase_defense_mode_set", mode)
    message = "Requested mode " .. mode .. "..."
end

local function confirmPending()
    local item = selectedRow()
    if not item or item.kind ~= "pending" then
        message = "Select a pending turtle first."
        return
    end

    if not confirm("Enroll #" .. tostring(item.id) .. " code " .. tostring(item.code) .. "?") then
        message = "Enrollment cancelled."
        return
    end

    os.queueEvent("ccbase_defense_enroll_confirm", item.id, item.code)
    message = "Confirming turtle #" .. tostring(item.id) .. "..."
end

local function revokeSelected()
    local item = selectedRow()
    if not item or item.kind ~= "unit" then
        message = "Select an enrolled unit first."
        return
    end

    if not confirm("REVOKE unit #" .. tostring(item.id) .. "?") then
        message = "Revoke cancelled."
        return
    end

    os.queueEvent("ccbase_defense_revoke", item.id)
    message = "Revoking unit #" .. tostring(item.id) .. "..."
end

local function commandSelected(command)
    local item = selectedRow()
    if not item or item.kind ~= "unit" then
        message = "Select an enrolled unit first."
        return
    end

    if not item.online then
        message = "Unit #" .. tostring(item.id) .. " is offline."
        return
    end

    local requestId = string.format(
        "ui:%d:%s:%d",
        tonumber(item.id) or 0,
        command,
        os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000)
    )

    os.queueEvent("ccbase_defense_command", item.id, command, requestId)
    message = "Sent " .. command .. " to #" .. tostring(item.id) .. "..."
end

refresh()

while running do
    draw()
    local event, a, b, c, d = os.pullEvent()

    if event == "key" then
        if a == keys.up then
            selected = math.max(1, selected - 1)
        elseif a == keys.down then
            selected = selected + 1
        elseif a == keys.one then
            setMode("SAFE")
        elseif a == keys.two then
            setMode("ARMED")
        elseif a == keys.three then
            setMode("LOCKDOWN")
        elseif a == keys.c then
            confirmPending()
        elseif a == keys.x then
            revokeSelected()
        elseif a == keys.a then
            commandSelected("attack")
        elseif a == keys.q then
            commandSelected("turn_left")
        elseif a == keys.e then
            commandSelected("turn_right")
        elseif a == keys.w then
            commandSelected("forward")
        elseif a == keys.s then
            commandSelected("back")
        elseif a == keys.r then
            commandSelected("up")
        elseif a == keys.f then
            commandSelected("down")
        elseif a == keys.leftShift or a == keys.escape or a == keys.left then
            running = false
        end

    elseif event == "ccbase_defense_action_result" then
        local action, ok, detail = a, b, c
        message = tostring(action) .. ": " .. (ok and "OK " or "FAILED ") .. tostring(detail or "")

    elseif event == "ccbase_defense_command_result" then
        local id, _, ok, detail = a, b, c, d
        message = "Unit #" .. tostring(id) .. ": " .. (ok and "OK" or ("FAILED " .. tostring(detail or "")))

    elseif event == "ccbase_defense_pending" then
        message = "Pairing request from turtle #" .. tostring(a) .. ", code " .. tostring(b)

    elseif event == "ccbase_defense_enrolled" then
        message = "Enrolled turtle #" .. tostring(a) .. "."

    elseif event == "ccbase_defense_revoked" then
        message = "Revoked turtle #" .. tostring(a) .. "."

    elseif event == "term_resize" then
        -- redraw on next loop
    end
end

ui.clear(term)
print("BASE Defense Control closed.")
