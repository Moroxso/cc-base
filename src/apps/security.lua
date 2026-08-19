local Button = require("lib.gui.button")
local List = require("lib.gui.list")
local Runtime = require("lib.runtime")
local Integrity = require("lib.security.integrity")

local width, height = term.getSize()

if width < 48 or height < 18 then
    error("Terminal is too small for Security UI")
end

local running = true
local message = "Integrity monitor protects deployed system files."
local status = Integrity.loadStatus() or Integrity.scan()

local function resetColors()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function line(y, text, color, x, maxWidth)
    x = x or 2
    maxWidth = maxWidth or (width - x)
    text = tostring(text or "")

    if #text > maxWidth then
        text = text:sub(1, maxWidth)
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(color or colors.white)
    term.setCursorPos(x, y)
    term.write(text .. string.rep(" ", math.max(0, maxWidth - #text)))
    resetColors()
end

local function issueLabel(item)
    return string.format(
        "%-10s %s",
        tostring(item.kind or "issue"):upper():sub(1, 10),
        tostring(item.path or "?")
    )
end

local issueList = List.new({
    x = 2,
    y = 7,
    width = width - 3,
    height = 5,
    items = status.issues or {},
    getLabel = issueLabel,
    selectedBackgroundColor = colors.lightBlue,
    selectedTextColor = colors.black
})

local function button(id, label, x, y, w, bg, fg)
    return Button.new({
        id = id,
        label = label,
        x = x,
        y = y,
        width = w,
        height = 1,
        backgroundColor = bg,
        textColor = fg or colors.white
    })
end

local scanButton = button("scan", "Scan", 2, 14, 10, colors.blue)
local quarantineButton = button("quarantine", "Quarantine", 13, 14, 13, colors.orange, colors.black)
local repairButton = button("repair", "Repair", 27, 14, 10, colors.green, colors.black)
local backButton = button("back", "Back", 38, 14, math.max(10, width - 39), colors.red)
local clearButton = button("clear", "Clear Log", 2, 15, 12, colors.gray)

local function refresh()
    status = Integrity.loadStatus() or Integrity.scan()
    issueList:setItems(status.issues or {})
end

local function drawHeader()
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    local title = "SYSTEM SECURITY / INTEGRITY"
    term.setCursorPos(math.max(1, math.floor((width - #title) / 2) + 1), 2)
    term.write(title)
    resetColors()
end

local function drawFooter()
    local text = "UP/DOWN issue ENTER scan CTRL repair SHIFT back"
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))
    term.setCursorPos(math.max(1, math.floor((width - #text) / 2) + 1), height)
    term.write(text:sub(1, width))
    resetColors()
end

local function draw()
    resetColors()
    term.clear()
    drawHeader()
    refresh()

    local issueCount = #(status.issues or {})
    local ok = status.ok == true

    line(
        4,
        "STATE: " .. (ok and "CLEAN" or "ALERT") ..
            "   VERSION: " .. tostring(status.projectVersion or "unknown"),
        ok and colors.lime or colors.red
    )

    line(
        5,
        "BASELINE: " .. tostring(status.baselineVersion or "unknown") ..
            "   PROTECTED: " .. tostring(status.protectedCount or 0) ..
            "   ISSUES: " .. tostring(issueCount),
        colors.lightGray
    )

    line(
        6,
        "QUARANTINE: " .. tostring(Integrity.quarantineCount()) ..
            "   HASH: DJB2-32 (integrity detection, not cryptographic trust)",
        colors.cyan
    )

    issueList:draw(term)

    local selected = issueList:getSelectedItem()

    if selected then
        line(
            12,
            tostring(selected.kind or "issue") .. " | " .. tostring(selected.path or "?"),
            selected.kind == "unexpected" and colors.orange or colors.red
        )
    else
        line(12, "No integrity issues detected.", colors.lime)
    end

    line(
        13,
        "Modified/missing system files: use Repair. Unexpected files may be quarantined.",
        colors.lightGray
    )

    scanButton:draw(term)
    quarantineButton:setEnabled(selected ~= nil and selected.kind == "unexpected")
    quarantineButton:draw(term)
    repairButton:draw(term)
    backButton:draw(term)
    clearButton:draw(term)

    line(16, "Network payload quarantine never auto-runs received content.", colors.yellow)
    line(17, message, colors.gray)
    drawFooter()
end

local function requestScan()
    os.queueEvent("ccbase_security_scan")
    message = "Integrity scan requested..."
end

local function quarantineSelected()
    local selected = issueList:getSelectedItem()

    if not selected or selected.kind ~= "unexpected" then
        message = "Only unexpected protected files can be quarantined automatically."
        return
    end

    os.queueEvent("ccbase_security_quarantine", selected.path)
    message = "Quarantining " .. tostring(selected.path) .. "..."
end

local function repair()
    message = "Running trusted GitHub updater..."
    draw()

    local ok, err = Runtime.run("/update.lua")

    if ok then
        message = "Repair/update complete. Reboot required."
        os.queueEvent("ccbase_security_scan")
    else
        message = "Repair failed: " .. tostring(err)
    end
end

local refreshTimer = os.startTimer(0.5)
draw()

while running do
    local event, a, b, c = os.pullEvent()
    local redraw = false

    if event == "mouse_click" and (a == 1 or a == 0) then
        local index = issueList:findAt(b, c)

        if index then
            issueList:setSelected(index)
            redraw = true
        elseif scanButton:contains(b, c) then
            requestScan()
            redraw = true
        elseif quarantineButton:contains(b, c) and quarantineButton.enabled then
            quarantineSelected()
            redraw = true
        elseif repairButton:contains(b, c) then
            repair()
            redraw = true
        elseif clearButton:contains(b, c) then
            os.queueEvent("ccbase_security_clear_log")
            message = "Clearing integrity incident log..."
            redraw = true
        elseif backButton:contains(b, c) then
            running = false
        end

    elseif event == "key" then
        if a == keys.up then
            issueList:move(-1)
            redraw = true
        elseif a == keys.down then
            issueList:move(1)
            redraw = true
        elseif a == keys.enter then
            requestScan()
            redraw = true
        elseif a == keys.leftCtrl then
            repair()
            redraw = true
        elseif a == keys.leftShift then
            running = false
        end

    elseif event == "ccbase_security_scan_result" then
        refresh()
        message = a and "Integrity scan: CLEAN." or
            ("Integrity scan: " .. tostring(b) .. " issue(s).")
        redraw = true

    elseif event == "ccbase_security_state" then
        refresh()
        message = a and "Integrity state returned to CLEAN." or
            ("Integrity ALERT: " .. tostring(b) .. " issue(s).")
        redraw = true

    elseif event == "ccbase_security_quarantine_result" then
        refresh()
        message = a and ("Quarantined as " .. tostring(b)) or
            ("Quarantine failed: " .. tostring(b))
        redraw = true

    elseif event == "ccbase_security_log_cleared" then
        message = a and "Integrity incident log cleared." or
            ("Log clear failed: " .. tostring(b))
        redraw = true

    elseif event == "timer" and a == refreshTimer then
        refresh()
        refreshTimer = os.startTimer(0.5)
        redraw = true

    elseif event == "term_resize" then
        local w, h = term.getSize()

        if w < 48 or h < 18 then
            running = false
        else
            redraw = true
        end
    end

    if redraw and running then
        draw()
    end
end

resetColors()
term.clear()
term.setCursorPos(1, 1)
print("Security Control closed.")
