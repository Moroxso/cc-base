local ui = require("lib.ui")
local Screen = require("lib.gui.screen")
local Automation = require("lib.automation")
local Address = require("lib.net.address")

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

local function safeCapacity(path)
    if type(fs.getCapacity) ~= "function" then return nil end
    local ok, value = pcall(fs.getCapacity, path)
    if not ok then return nil end
    return tonumber(value)
end

local function truncate(text, width)
    text = tostring(text or "")
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

local function waitForBack()
    while true do
        local event, key = os.pullEvent()
        if event == "key" and (key == keys.left or key == keys.leftShift) then
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
    ui.drawHeader(options.title)
    ui.centerText(term, 4, "STATUS / SERVICES", colors.cyan)

    local snapshot = options.supervisor and options.supervisor:snapshot() or {}
    local width = term.getSize()
    local y = 6

    if #snapshot == 0 then
        ui.centerText(term, 8, "No service data.", colors.orange)
    else
        for _, item in ipairs(snapshot) do
            if y > 14 then break end
            local left = truncate(item.label or item.id, 15)
            local right = string.format("%-10s R:%d F:%d", tostring(item.state or "?"), tonumber(item.restarts) or 0, tonumber(item.failures) or 0)

            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.setCursorPos(3, y)
            term.write(left)
            term.setTextColor(STATE_COLORS[item.state] or colors.lightGray)
            term.setCursorPos(19, y)
            term.write(truncate(right, math.max(1, width - 20)))
            y = y + 1
        end
    end

    local summary = serviceSummary(options)
    term.setTextColor(summary.failed > 0 and colors.red or colors.lightGray)
    term.setCursorPos(3, 15)
    term.write(truncate(string.format("Total %d  Running %d  Failed %d", summary.total, summary.running, summary.failed), math.max(1, width - 4)))

    ui.drawFooter("LEFT / SHIFT - Back")
    waitForBack()
end

local function showStorage(options)
    ui.drawHeader(options.title)
    ui.centerText(term, 4, "STATUS / STORAGE & PACKAGES", colors.cyan)

    local capacity = safeCapacity("/")
    local free = safeFreeSpace("/")
    local used = nil
    if capacity and free and free ~= math.huge then
        used = math.max(0, capacity - free)
    end

    local installed = options.packages and options.packages:listInstalled() or {}
    local pkgText, pkgColor = packageState(options)

    drawLine(6, "Drive", "hdd /", colors.white)
    drawLine(7, "Capacity", formatBytes(capacity), colors.white)
    drawLine(8, "Used", formatBytes(used), colors.white)
    drawLine(9, "Free", formatBytes(free), free and free ~= math.huge and free < 65536 and colors.orange or colors.lime)
    drawLine(11, "Packages", tostring(type(installed) == "table" and #installed or 0) .. " installed", colors.white)
    drawLine(12, "Pkg state", pkgText, pkgColor)

    ui.drawFooter("LEFT / SHIFT - Back")
    waitForBack()
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
    local width, height = term.getSize()
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
        y = math.min(13, math.max(12, height - 5)),
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
        elseif event == "key" and (a == keys.left or a == keys.leftShift) then
            return
        else
            local action, changed = screen:handleEvent(event, a, b, c)

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
            elseif changed then
                drawHub(options, screen)
            end
        end
    end
end

return StatusUI
