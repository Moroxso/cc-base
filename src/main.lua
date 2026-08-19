local ui = require("lib.ui")
local Runtime = require("lib.runtime")
local Automation = require("lib.automation")
local Screen = require("lib.gui.screen")
local NetworkService = require("lib.net.service")
local IPService = require("lib.net.ip_service")
local DatagramService = require("lib.net.datagram_service")
local Address = require("lib.net.address")

local APP_TITLE = "BASE CONTROL SYSTEM"
local AUTOMATION_PATH = "/data/automation.json"

local automation = Automation.new(AUTOMATION_PATH)
local network = NetworkService.new()
local ip = IPService.new()
local datagrams = DatagramService.new()

local function waitForBack()
    while true do
        local _, key = os.pullEvent("key")

        if key == keys.left or key == keys.leftShift then
            return
        end
    end
end

local function readVersion()
    local path = "/.project-version"

    if not fs.exists(path) then
        return "unknown"
    end

    local file = fs.open(path, "r")

    if not file then
        return "unknown"
    end

    local version = file.readAll()
    file.close()

    if version == "" then
        return "unknown"
    end

    return version
end

local function showStatus()
    ui.drawHeader(APP_TITLE)

    ui.centerText(
        term,
        5,
        "SYSTEM STATUS",
        colors.cyan
    )

    term.setCursorPos(4, 7)
    term.setTextColor(colors.lime)
    term.write("STATUS: ONLINE")

    ui.resetColors(term)

    term.setCursorPos(4, 9)
    term.write("Computer ID: " .. os.getComputerID())

    local label = os.getComputerLabel()

    term.setCursorPos(4, 10)
    term.write("Computer name: " .. (label or "NOT SET"))

    local width, height = term.getSize()

    term.setCursorPos(4, 11)
    term.write("Terminal: " .. width .. "x" .. height)

    term.setCursorPos(4, 12)
    term.write("Version: " .. readVersion())

    term.setCursorPos(4, 13)

    if http then
        term.setTextColor(colors.lime)
        term.write("HTTP API: AVAILABLE")
    else
        term.setTextColor(colors.red)
        term.write("HTTP API: UNAVAILABLE")
    end

    ui.resetColors(term)

    local config = Automation.loadConfig(AUTOMATION_PATH)

    term.setCursorPos(4, 14)
    term.setTextColor(
        config.enabled and colors.lime or colors.red
    )
    term.write(
        "Automation: " ..
        (config.enabled and "ON" or "OFF") ..
        " (" .. #config.rules .. " rules)"
    )

    term.setCursorPos(4, 15)

    if rednet and rednet.isOpen and rednet.isOpen() then
        term.setTextColor(colors.lime)
        term.write("Network: REDNET OPEN")
    else
        term.setTextColor(colors.orange)
        term.write("Network: NO OPEN MODEM")
    end

    term.setCursorPos(4, 16)
    term.setTextColor(colors.cyan)
    term.write("CCIP: " .. tostring(Address.localAddress() or "UNAVAILABLE"))

    ui.resetColors(term)
    ui.drawFooter("LEFT / SHIFT - Back")

    waitForBack()
end

local function showHello()
    ui.drawHeader(APP_TITLE)

    ui.centerText(
        term,
        8,
        "Hello!",
        colors.lime
    )

    ui.centerText(
        term,
        10,
        (os.getComputerLabel() or "Computer") .. " is online.",
        colors.white
    )

    ui.drawFooter("LEFT / SHIFT - Back")

    waitForBack()
end

local function showProgramError(name, detail)
    ui.drawHeader(APP_TITLE)

    ui.centerText(
        term,
        7,
        "PROGRAM ERROR",
        colors.red
    )

    ui.centerText(
        term,
        9,
        name .. " failed to start.",
        colors.white
    )

    if detail then
        local width = term.getSize()
        local text = tostring(detail)

        if #text > width - 6 then
            text = text:sub(1, width - 9) .. "..."
        end

        ui.centerText(
            term,
            11,
            text,
            colors.lightGray
        )
    end

    ui.drawFooter("LEFT / SHIFT - Back")
    waitForBack()
end

local function runProgram(name, path)
    ui.clear(term)

    local ok, err = Runtime.run(path)

    if not ok then
        showProgramError(name, err)
    end
end

local function createGamesScreen()
    local width = term.getSize()
    local buttonWidth = math.min(28, math.max(18, width - 12))
    local x = math.max(2, math.floor((width - buttonWidth) / 2) + 1)

    local screen = Screen.new(term, {
        columns = 1
    })

    screen:addButton({
        id = "breakout",
        label = "Breakout",
        x = x,
        y = 5,
        width = buttonWidth,
        height = 2,
        backgroundColor = colors.blue,
        textColor = colors.white
    })

    screen:addButton({
        id = "tetris",
        label = "Tetris",
        x = x,
        y = 8,
        width = buttonWidth,
        height = 2,
        backgroundColor = colors.cyan,
        textColor = colors.black
    })

    screen:addButton({
        id = "chess",
        label = "Chess PvP",
        x = x,
        y = 11,
        width = buttonWidth,
        height = 2,
        backgroundColor = colors.brown,
        textColor = colors.white
    })

    screen:addButton({
        id = "back",
        label = "Back",
        x = x,
        y = 14,
        width = buttonWidth,
        height = 2,
        backgroundColor = colors.gray,
        textColor = colors.white
    })

    return screen
end

local function drawGamesScreen(screen)
    ui.drawHeader(APP_TITLE)

    ui.centerText(
        term,
        4,
        "GAMES",
        colors.lightGray
    )

    screen:draw()
    ui.drawFooter("MOUSE CLICK  UP/DOWN  ENTER  LEFT/SHIFT")
end

local function showGames()
    local screen = createGamesScreen()

    while true do
        drawGamesScreen(screen)

        local event, a, b, c = os.pullEvent()

        if event == "term_resize" then
            screen = createGamesScreen()

        elseif event == "key" and (a == keys.left or a == keys.leftShift) then
            return

        else
            local action, changed = screen:handleEvent(event, a, b, c)

            if action == "breakout" then
                runProgram(
                    "Breakout",
                    "/games/breakout.lua"
                )
            elseif action == "tetris" then
                runProgram(
                    "Tetris",
                    "/games/tetris.lua"
                )
            elseif action == "chess" then
                runProgram(
                    "Chess PvP",
                    "/games/chess.lua"
                )
            elseif action == "back" then
                return
            elseif changed then
                drawGamesScreen(screen)
            end
        end
    end
end

local function rebootComputer()
    ui.drawHeader(APP_TITLE)

    ui.centerText(
        term,
        8,
        "REBOOTING...",
        colors.orange
    )

    sleep(1)
    os.reboot()
end

local function shutdownComputer()
    ui.drawHeader(APP_TITLE)

    ui.centerText(
        term,
        8,
        "SHUTTING DOWN...",
        colors.red
    )

    sleep(1)
    os.shutdown()
end

local function createDashboardScreen()
    local width = term.getSize()
    local margin = 2
    local gap = 2
    local columnWidth = math.max(
        12,
        math.floor((width - margin * 2 - gap) / 2)
    )

    local leftX = margin
    local rightX = leftX + columnWidth + gap
    local rows = {5, 8, 11, 14}

    local screen = Screen.new(term, {
        columns = 2
    })

    local function add(id, label, column, row, background, foreground)
        screen:addButton({
            id = id,
            label = label,
            x = column == 1 and leftX or rightX,
            y = rows[row],
            width = columnWidth,
            height = 2,
            backgroundColor = background,
            textColor = foreground or colors.white,
            selectedBackgroundColor = colors.lightBlue,
            selectedTextColor = colors.black
        })
    end

    add("status", "System Status", 1, 1, colors.gray)
    add("hello", "Hello", 2, 1, colors.gray)
    add("games", "Games", 1, 2, colors.purple)
    add("redstone", "Redstone", 2, 2, colors.red)
    add("automation", "Automation", 1, 3, colors.orange, colors.black)
    add("reboot", "Reboot", 2, 3, colors.brown)
    add("shutdown", "Shutdown", 1, 4, colors.red)
    add("network", "Network", 2, 4, colors.blue)

    return screen
end

local function drawDashboard(screen)
    ui.drawHeader(APP_TITLE)

    ui.centerText(
        term,
        4,
        "DASHBOARD",
        colors.lightGray
    )

    screen:draw()

    local width, height = term.getSize()
    local config = Automation.loadConfig(AUTOMATION_PATH)
    local autoText = config.enabled and "ON" or "OFF"
    local status = string.format(
        "AUTO %s (%d)   VERSION %s",
        autoText,
        #config.rules,
        readVersion()
    )

    if #status > width - 2 then
        status = status:sub(1, width - 2)
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(
        config.enabled and colors.lime or colors.red
    )
    term.setCursorPos(2, math.max(1, height - 2))
    term.write(status)

    ui.resetColors(term)
    ui.drawFooter("MOUSE CLICK  ARROWS  ENTER  SHIFT")
end

local function activateDashboardAction(action)
    if action == "status" then
        showStatus()
    elseif action == "hello" then
        showHello()
    elseif action == "games" then
        showGames()
    elseif action == "redstone" then
        runProgram(
            "Redstone Control",
            "/apps/redstone.lua"
        )
    elseif action == "automation" then
        runProgram(
            "Automation",
            "/apps/automation.lua"
        )
    elseif action == "network" then
        runProgram(
            "Network Control",
            "/apps/network.lua"
        )
    elseif action == "reboot" then
        rebootComputer()
    elseif action == "shutdown" then
        shutdownComputer()
    end
end

local function mainLoop()
    local screen = createDashboardScreen()

    while true do
        drawDashboard(screen)

        local event, a, b, c = os.pullEvent()

        if event == "term_resize" then
            screen = createDashboardScreen()

        elseif event == "key" and a == keys.leftShift then
            ui.clear(term)
            print(APP_TITLE .. " closed.")
            return

        else
            local action, changed = screen:handleEvent(
                event,
                a,
                b,
                c
            )

            if action then
                activateDashboardAction(action)
            elseif changed then
                drawDashboard(screen)
            end
        end
    end
end

parallel.waitForAny(
    mainLoop,
    function()
        automation:run()
    end,
    function()
        network:run()
    end,
    function()
        ip:run()
    end,
    function()
        datagrams:run()
    end
)
