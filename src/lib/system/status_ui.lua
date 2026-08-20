local ui = require("lib.ui")
local Screen = require("lib.gui.screen")
local Automation = require("lib.automation")
local Address = require("lib.net.address")
local StorageManager = require("lib.system.storage_manager")
local StorageInspector = require("lib.system.storage_inspector")
local ServiceControl = require("lib.system.service_control")

local StatusUI = {}

local DEFAULT_AUTOMATION_PATH = "/data/automation.json"
local VERSION_PATH = "/.project-version"

local STATE_COLORS = {
    RUNNING = colors.lime,
    STARTING = colors.orange,
    RESTARTING = colors.orange,
    FAILED = colors.red,
    STOPPED = colors.lightGray
}

local function readVersion()
    if not fs.exists(VERSION_PATH) or fs.isDir(VERSION_PATH) then
        return "unknown"
    end

    local file = fs.open(VERSION_PATH, "r")
    if not file then return "unknown" end
    local version = file.readAll()
    file.close()
    return version ~= "" and version or "unknown"
end

local function formatBytes(value)
    if value == nil then return "unknown" end
    if value == math.huge or value == "unlimited" then return "unlimited" end

    value = tonumber(value)
    if not value then return "unknown" end

    if value >= 1024 * 1024 then
        return string.format("%.2f MiB", value / (1024 * 1024))
    elseif value >= 1024 then
        return string.format("%.1f KiB", value / 1024)
    end

    return tostring(math.floor(value)) .. " B"
end

local function safeFreeSpace(path)
    if type(fs.getFreeSpace) ~= "function" then return nil end
    local ok, value = pcall(fs.getFreeSpace, path)
    if not ok then return nil end
    if value == "unlimited" then return math.huge end
    return tonumber(value)
end

local function truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

local function waitForBack()
    while true do
        local event, key = os.pullEvent()
        if event == "key"
            and (key == keys.left or key == keys.leftShift or key == keys.escape)
        then
            return
        end
    end
end

local function drawLine(y, label, value, color)
    local width = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(3, y)
    term.write(truncate(label, 15))
    term.setTextColor(color or colors.white)
    term.setCursorPos(18, y)
    term.write(truncate(value, math.max(1, width - 19)))
end

local function promptLine(label, initial)
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.setCursorPos(1, height - 1)
    term.write(string.rep(" ", width))
    term.setCursorPos(2, height - 1)
    term.write(truncate(label, math.max(1, width - 3)))
    term.setTextColor(colors.white)
    term.setCursorBlink(true)
    local value = read(nil, nil, nil, initial)
    term.setCursorBlink(false)
    return value
end

local function confirmAction(text)
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.orange)
    term.setCursorPos(1, height - 1)
    term.write(string.rep(" ", width))
    term.setCursorPos(2, height - 1)
    term.write(truncate(text .. "  Y=confirm / N=cancel", width - 2))

    while true do
        local event, value = os.pullEvent()
        if event == "char" then
            value = string.lower(value)
            if value == "y" then return true end
            if value == "n" then return false end
        elseif event == "key"
            and (value == keys.escape or value == keys.left or value == keys.leftShift)
        then
            return false
        end
    end
end

local function packageState(options)
    if options.packageRecoveryError then
        return "RECOVERY NEEDED", colors.orange
    end

    local packages = options.packages
    if not packages then return "UNKNOWN", colors.lightGray end

    local pending = packages:pendingTransaction()
    if pending then return "TRANSACTION PENDING", colors.orange end
    return "READY", colors.lime
end

local function serviceSummary(options)
    local supervisor = options.supervisor
    if not supervisor then
        return {total = 0, running = 0, failed = 0, restarting = 0, starting = 0, stopped = 0}
    end
    return supervisor:summary()
end

local function showOverview(options)
    ui.drawHeader(options.title)
    ui.centerText(term, 4, "STATUS / OVERVIEW", colors.cyan)

    local width, height = term.getSize()
    local config = Automation.loadConfig(options.automationPath)
    local summary = serviceSummary(options)
    local pkgText, pkgColor = packageState(options)

    drawLine(6, "State", "ONLINE", colors.lime)
    drawLine(7, "Version", readVersion(), colors.white)
    drawLine(8, "Computer", (os.getComputerLabel() or "Computer") .. " #" .. os.getComputerID(), colors.white)
    drawLine(9, "Terminal", width .. "x" .. height, colors.white)
    drawLine(10, "HTTP", http and "AVAILABLE" or "UNAVAILABLE", http and colors.lime or colors.red)
    drawLine(11, "Automation", (config.enabled and "ON" or "OFF") .. " / " .. #config.rules .. " rules", config.enabled and colors.lime or colors.orange)
    drawLine(12, "Services", string.format("%d/%d RUNNING", summary.running, summary.total), summary.failed > 0 and colors.red or ((summary.restarting > 0 or summary.starting > 0) and colors.orange or colors.lime))
    drawLine(13, "Packages", pkgText, pkgColor)

    ui.drawFooter("LEFT / SHIFT - Back")
    waitForBack()
end

local function showServices(options)
    local supervisor = options.supervisor
    local selected = 1
    local message = "S=start  X=stop  R=restart"

    while true do
        ui.drawHeader(options.title)
        ui.centerText(term, 4, "STATUS / SERVICES", colors.cyan)

        local snapshot = supervisor and supervisor:snapshot() or {}
        if selected > #snapshot then selected = math.max(1, #snapshot) end
        local width = term.getSize()

        if #snapshot == 0 then
            ui.centerText(term, 8, "No service data.", colors.orange)
        else
            for index, item in ipairs(snapshot) do
                if index > 6 then break end
                local y = 5 + index
                local isSelected = index == selected
                term.setBackgroundColor(isSelected and colors.lightBlue or colors.black)
                term.setTextColor(isSelected and colors.black or colors.white)
                term.setCursorPos(2, y)
                term.write(string.rep(" ", math.max(1, width - 2)))
                term.setCursorPos(3, y)
                term.write(truncate(item.label or item.id, 15))
                term.setCursorPos(19, y)
                term.setTextColor(isSelected and colors.black or (STATE_COLORS[item.state] or colors.lightGray))
                local right = string.format("%-10s R:%d F:%d", tostring(item.state or "?"), tonumber(item.restarts) or 0, tonumber(item.failures) or 0)
                term.write(truncate(right, math.max(1, width - 20)))
            end

            local item = snapshot[selected]
            if item then
                drawLine(13, "Desired", tostring(item.desired or "?"), colors.white)
                drawLine(14, "Depends", #(item.dependencies or {}) > 0 and table.concat(item.dependencies, ",") or "none", colors.lightGray)
                drawLine(15, "Detail", tostring(item.lastError ~= "" and item.lastError or item.detail or ""), item.lastError ~= "" and colors.red or colors.lightGray)
            end
        end

        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.setCursorPos(2, 17)
        term.write(truncate(message, math.max(1, width - 2)))
        ui.drawFooter("UP/DOWN  S START  X STOP  R RESTART  LEFT")

        local event, a, b, c = os.pullEvent()
        if event == "key" then
            if a == keys.left or a == keys.leftShift or a == keys.escape then
                return
            elseif a == keys.up and #snapshot > 0 then
                selected = math.max(1, selected - 1)
            elseif a == keys.down and #snapshot > 0 then
                selected = math.min(#snapshot, selected + 1)
            end
        elseif event == "char" and #snapshot > 0 then
            local action = string.lower(a)
            local item = snapshot[selected]
            if item then
                if action == "s" then
                    local ok, err = ServiceControl.start(supervisor, item.id)
                    message = ok and ("Start requested: " .. item.id) or tostring(err)
                elseif action == "x" then
                    if confirmAction("Stop " .. item.id .. "?") then
                        local ok, err = ServiceControl.stop(supervisor, item.id)
                        message = ok and ("Stopped: " .. item.id) or tostring(err)
                    else
                        message = "Stop cancelled"
                    end
                elseif action == "r" then
                    if confirmAction("Restart " .. item.id .. "?") then
                        local ok, err = ServiceControl.restart(supervisor, item.id)
                        message = ok and ("Restart requested: " .. item.id) or tostring(err)
                    else
                        message = "Restart cancelled"
                    end
                end
            end
        elseif event == "mouse_click" and a == 1 and b >= 3 and b <= width - 1 and c >= 6 and c <= 11 then
            local index = c - 5
            if snapshot[index] then selected = index end
        end
    end
end

local function showMounts(options, manager)
    ui.drawHeader(options.title)
    ui.centerText(term, 4, "STORAGE / MOUNTS", colors.cyan)

    local mounts = manager:listMounts()
    local width = term.getSize()
    local y = 6

    for _, mount in ipairs(mounts) do
        if y > 15 then break end
        term.setCursorPos(2, y)
        term.setTextColor(mount.readOnly and colors.orange or colors.white)
        local line = string.format(
            "%s [%s] free %s / %s",
            mount.path,
            tostring(mount.drive or "?"),
            formatBytes(mount.free),
            formatBytes(mount.capacity)
        )
        term.write(truncate(line, width - 2))
        y = y + 1
    end

    if #mounts == 0 then
        ui.centerText(term, 8, "No mounts detected.", colors.orange)
    end

    ui.drawFooter("LEFT / SHIFT - Back")
    waitForBack()
end

local function showPackages(options)
    ui.drawHeader(options.title)
    ui.centerText(term, 4, "STORAGE / PACKAGES", colors.cyan)

    local installed = options.packages and options.packages:listInstalled() or {}
    local width = term.getSize()
    local y = 6

    if type(installed) ~= "table" or #installed == 0 then
        ui.centerText(term, 8, "No installed package records.", colors.orange)
    else
        for _, item in ipairs(installed) do
            if y > 15 then break end
            term.setCursorPos(2, y)
            term.setTextColor(colors.white)
            local line = string.format(
                "%s  %s  [%s]",
                tostring(item.id or "?"),
                tostring(item.version or "?"),
                tostring(item.mount or item.managedBy or "?")
            )
            term.write(truncate(line, width - 2))
            y = y + 1
        end
    end

    ui.drawFooter("LEFT / SHIFT - Back")
    waitForBack()
end

local function showOwnership(options, manager)
    local entries, truncated = StorageInspector.ownership(manager, "/", 200)
    local offset = 1

    while true do
        ui.drawHeader(options.title)
        ui.centerText(term, 4, "STORAGE / OWNERSHIP", colors.cyan)
        local width = term.getSize()
        local visible = 10

        for row = 1, visible do
            local item = entries[offset + row - 1]
            if not item then break end
            term.setCursorPos(2, 5 + row)
            term.setTextColor(colors.white)
            term.write(truncate(item.path .. "  <" .. tostring(item.owner) .. ">", width - 2))
        end

        term.setCursorPos(2, 17)
        term.setTextColor(colors.lightGray)
        term.write(truncate(string.format("%d managed targets%s", #entries, truncated and "+" or ""), width - 2))
        ui.drawFooter("UP/DOWN/PgUp/PgDn  LEFT - Back")

        local _, key = os.pullEvent("key")
        if key == keys.left or key == keys.leftShift or key == keys.escape then
            return
        elseif key == keys.up then
            offset = math.max(1, offset - 1)
        elseif key == keys.down then
            offset = math.min(math.max(1, #entries - visible + 1), offset + 1)
        elseif key == keys.pageUp then
            offset = math.max(1, offset - visible)
        elseif key == keys.pageDown then
            offset = math.min(math.max(1, #entries - visible + 1), offset + visible)
        end
    end
end

local function showSearchResults(options, results, meta)
    local offset = 1
    local visible = 10

    while true do
        ui.drawHeader(options.title)
        ui.centerText(term, 4, "STORAGE / SEARCH", colors.cyan)
        local width = term.getSize()

        if #results == 0 then
            ui.centerText(term, 8, "No matches.", colors.orange)
        else
            for row = 1, visible do
                local item = results[offset + row - 1]
                if not item then break end
                term.setCursorPos(2, 5 + row)
                term.setTextColor(item.isDir and colors.cyan or colors.white)
                local marker = item.protected and "*" or " "
                term.write(truncate(marker .. " " .. item.path, width - 2))
            end
        end

        term.setCursorPos(2, 17)
        term.setTextColor(colors.lightGray)
        local suffix = meta and meta.truncated and " (limit reached)" or ""
        term.write(truncate(tostring(#results) .. " matches" .. suffix, width - 2))
        ui.drawFooter("UP/DOWN/PgUp/PgDn  LEFT - Back")

        local _, key = os.pullEvent("key")
        if key == keys.left or key == keys.leftShift or key == keys.escape then
            return
        elseif key == keys.up then
            offset = math.max(1, offset - 1)
        elseif key == keys.down then
            offset = math.min(math.max(1, #results - visible + 1), offset + 1)
        elseif key == keys.pageUp then
            offset = math.max(1, offset - visible)
        elseif key == keys.pageDown then
            offset = math.min(math.max(1, #results - visible + 1), offset + visible)
        end
    end
end

local function showSearch(options, manager)
    ui.drawHeader(options.title)
    ui.centerText(term, 4, "STORAGE / SEARCH", colors.cyan)
    drawLine(7, "Root", "Enter search root (default /)", colors.lightGray)
    local root = promptLine("Root: ", "/")
    if not root or root == "" then root = "/" end
    local query = promptLine("Name contains: ")
    if not query or query == "" then return end

    local results, err, meta = StorageInspector.search(manager, root, query, {
        limit = 100,
        maxDepth = 16
    })

    if not results then
        ui.drawHeader(options.title)
        ui.centerText(term, 4, "STORAGE / SEARCH ERROR", colors.red)
        ui.centerText(term, 8, truncate(tostring(err), select(1, term.getSize()) - 4), colors.orange)
        ui.drawFooter("LEFT / SHIFT - Back")
        waitForBack()
        return
    end

    showSearchResults(options, results, meta)
end

local function showCleanup(options)
    ui.drawHeader(options.title)
    ui.centerText(term, 4, "STORAGE / CLEANUP", colors.cyan)

    local report = StorageInspector.cleanupReport()
    drawLine(6, "Transactions", report.activeTransaction and "ACTIVE" or "none", report.activeTransaction and colors.orange or colors.lime)
    drawLine(7, "Stale files", tostring(#report.candidates), #report.candidates > 0 and colors.orange or colors.lime)

    local y = 9
    for _, item in ipairs(report.candidates) do
        if y > 13 then break end
        drawLine(y, item.kind, item.path, colors.lightGray)
        y = y + 1
    end

    if report.safeToRunUpdaterCleanup then
        drawLine(15, "Action", "run: update --cleanup", colors.cyan)
    else
        drawLine(15, "Action", "finish recovery first", colors.orange)
    end

    ui.drawFooter("LEFT / SHIFT - Back")
    waitForBack()
end

local function createStorageHub()
    local width = term.getSize()
    local gap = 2
    local margin = 2
    local columnWidth = math.max(15, math.floor((width - margin * 2 - gap) / 2))
    local leftX = margin
    local rightX = leftX + columnWidth + gap
    local screen = Screen.new(term, {columns = 2})

    local function add(id, label, column, y, background, foreground)
        screen:addButton({
            id = id,
            label = label,
            x = column == 1 and leftX or rightX,
            y = y,
            width = columnWidth,
            height = 2,
            backgroundColor = background,
            textColor = foreground or colors.white,
            selectedBackgroundColor = colors.lightBlue,
            selectedTextColor = colors.black
        })
    end

    add("mounts", "Mounts", 1, 5, colors.brown)
    add("packages", "Packages", 2, 5, colors.purple)
    add("ownership", "Ownership", 1, 8, colors.gray)
    add("search", "Search", 2, 8, colors.cyan, colors.black)
    add("cleanup", "Cleanup", 1, 11, colors.orange, colors.black)
    add("back", "Back", 2, 11, colors.gray)

    return screen
end

local function showStorage(options)
    local manager = options.storageManager or StorageManager.new()
    local screen = createStorageHub()

    while true do
        ui.drawHeader(options.title)
        ui.centerText(term, 4, "STATUS / STORAGE & PACKAGES", colors.cyan)
        screen:draw()

        local mounts = manager:listMounts()
        local installed = options.packages and options.packages:listInstalled() or {}
        local free = safeFreeSpace("/")
        local width = term.getSize()
        term.setCursorPos(2, 15)
        term.setTextColor(colors.lightGray)
        term.write(truncate(string.format("Root free %s | mounts %d | packages %d", formatBytes(free), #mounts, type(installed) == "table" and #installed or 0), width - 2))
        ui.drawFooter("MOUSE CLICK  ARROWS  ENTER  LEFT/SHIFT")

        local event, a, b, c = os.pullEvent()
        if event == "term_resize" then
            screen = createStorageHub()
        elseif event == "key" and (a == keys.left or a == keys.leftShift or a == keys.escape) then
            return
        else
            local action = screen:handleEvent(event, a, b, c)
            if action == "back" then return
            elseif action == "mounts" then showMounts(options, manager); screen = createStorageHub()
            elseif action == "packages" then showPackages(options); screen = createStorageHub()
            elseif action == "ownership" then showOwnership(options, manager); screen = createStorageHub()
            elseif action == "search" then showSearch(options, manager); screen = createStorageHub()
            elseif action == "cleanup" then showCleanup(options); screen = createStorageHub()
            end
        end
    end
end

local function modemCount()
    if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
        return nil
    end

    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return nil end

    local count = 0
    for _, name in ipairs(names) do
        local typeOk, kind = pcall(peripheral.getType, name)
        if typeOk and kind == "modem" then count = count + 1 end
    end
    return count
end

local function findService(snapshot, id)
    for _, item in ipairs(snapshot or {}) do
        if item.id == id then return item end
    end
    return nil
end

local function showNetwork(options)
    ui.drawHeader(options.title)
    ui.centerText(term, 4, "STATUS / NETWORK", colors.cyan)

    local rednetOpen = rednet and type(rednet.isOpen) == "function" and rednet.isOpen() or false
    local snapshot = options.supervisor and options.supervisor:snapshot() or {}
    local network = findService(snapshot, "network")
    local ip = findService(snapshot, "ip")
    local datagrams = findService(snapshot, "datagrams")
    local streams = findService(snapshot, "streams")

    drawLine(6, "Rednet", rednetOpen and "OPEN" or "NO OPEN MODEM", rednetOpen and colors.lime or colors.orange)
    drawLine(7, "Modems", tostring(modemCount() or "unknown"), colors.white)
    drawLine(8, "CCIP", tostring(Address.localAddress() or "UNAVAILABLE"), colors.cyan)
    drawLine(10, "Network Core", network and network.state or "UNKNOWN", network and (STATE_COLORS[network.state] or colors.white) or colors.lightGray)
    drawLine(11, "CCIP service", ip and ip.state or "UNKNOWN", ip and (STATE_COLORS[ip.state] or colors.white) or colors.lightGray)
    drawLine(12, "CCDP", datagrams and datagrams.state or "UNKNOWN", datagrams and (STATE_COLORS[datagrams.state] or colors.white) or colors.lightGray)
    drawLine(13, "CCTP", streams and streams.state or "UNKNOWN", streams and (STATE_COLORS[streams.state] or colors.white) or colors.lightGray)

    ui.drawFooter("LEFT / SHIFT - Back")
    waitForBack()
end

local function createHub()
    local width = term.getSize()
    local gap = 2
    local margin = 2
    local columnWidth = math.max(15, math.floor((width - margin * 2 - gap) / 2))
    local leftX = margin
    local rightX = leftX + columnWidth + gap
    local screen = Screen.new(term, {columns = 2})

    local function add(id, label, column, y, background, foreground)
        screen:addButton({
            id = id,
            label = label,
            x = column == 1 and leftX or rightX,
            y = y,
            width = columnWidth,
            height = 2,
            backgroundColor = background,
            textColor = foreground or colors.white,
            selectedBackgroundColor = colors.lightBlue,
            selectedTextColor = colors.black
        })
    end

    add("overview", "Overview", 1, 6, colors.gray)
    add("services", "Services", 2, 6, colors.blue)
    add("storage", "Storage / Packages", 1, 9, colors.brown)
    add("network", "Network", 2, 9, colors.cyan, colors.black)

    local backWidth = math.min(24, width - 4)
    screen:addButton({
        id = "back",
        label = "Back",
        x = math.max(2, math.floor((width - backWidth) / 2) + 1),
        y = 13,
        width = backWidth,
        height = 2,
        backgroundColor = colors.gray,
        textColor = colors.white
    })

    return screen
end

local function drawHub(options, screen)
    ui.drawHeader(options.title)
    ui.centerText(term, 4, "SYSTEM STATUS", colors.cyan)
    screen:draw()
    ui.drawFooter("MOUSE CLICK  ARROWS  ENTER  LEFT/SHIFT")
end

function StatusUI.show(options)
    options = type(options) == "table" and options or {}
    options.title = options.title or "BASE CONTROL SYSTEM"
    options.automationPath = options.automationPath or DEFAULT_AUTOMATION_PATH

    local screen = createHub()

    while true do
        drawHub(options, screen)
        local event, a, b, c = os.pullEvent()

        if event == "term_resize" then
            screen = createHub()
        elseif event == "key" and (a == keys.left or a == keys.leftShift or a == keys.escape) then
            return
        else
            local action = screen:handleEvent(event, a, b, c)

            if action == "back" then
                return
            elseif action == "overview" then
                showOverview(options)
                screen = createHub()
            elseif action == "services" then
                showServices(options)
                screen = createHub()
            elseif action == "storage" then
                showStorage(options)
                screen = createHub()
            elseif action == "network" then
                showNetwork(options)
                screen = createHub()
            end
        end
    end
end

return StatusUI
