local ui = require("lib.ui")
local Runtime = require("lib.runtime")
local Automation = require("lib.automation")
local Screen = require("lib.gui.screen")
local PackageManager = require("lib.package.manager")
local ServiceSupervisor = require("lib.system.service_supervisor")
local NetworkService = require("lib.net.service")
local IPService = require("lib.net.ip_service")
local DatagramService = require("lib.net.datagram_service")
local StreamService = require("lib.net.stream_service")
local SecurityService = require("lib.security.service")
local Address = require("lib.net.address")

local APP_TITLE = "BASE CONTROL SYSTEM"
local AUTOMATION_PATH = "/data/automation.json"

local automation = Automation.new(AUTOMATION_PATH)
local packages = PackageManager.new()
local network = NetworkService.new()
local ip = IPService.new()
local datagrams = DatagramService.new()
local streams = StreamService.new()
local security = SecurityService.new()
local supervisor = ServiceSupervisor.new()

local function registerService(spec)
    local ok, err = supervisor:register(spec)

    if not ok then
        error(err, 0)
    end
end

registerService({
    id = "automation",
    label = "Automation",
    instance = automation,
    restartPolicy = "always"
})

registerService({
    id = "network",
    label = "Network Core",
    instance = network,
    restartPolicy = "always"
})

registerService({
    id = "ip",
    label = "CCIP",
    instance = ip,
    restartPolicy = "always",
    dependencies = {"network"}
})

registerService({
    id = "datagrams",
    label = "CCDP",
    instance = datagrams,
    restartPolicy = "always",
    dependencies = {"ip"}
})

registerService({
    id = "streams",
    label = "CCTP",
    instance = streams,
    restartPolicy = "always",
    dependencies = {"ip"}
})

registerService({
    id = "security",
    label = "Security",
    instance = security,
    restartPolicy = "always"
})

local packageRecoveryError = nil

do
    local recovered, recoveryError = packages:recoverPending()

    if not recovered then
        packageRecoveryError = recoveryError
    end

    local reconciled, reconcileError = packages:reconcileCurrentInstallation()

    if not reconciled and not packageRecoveryError then
        packageRecoveryError = reconcileError
    end
end

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

    if height >= 19 then
        term.setCursorPos(4, 17)

        if packageRecoveryError then
            term.setTextColor(colors.orange)
            term.write("Packages: RECOVERY NEEDED")
        else
            local pending = packages:pendingTransaction()

            if pending then
                term.setTextColor(colors.orange)
                term.write("Packages: TRANSACTION PENDING")
            else
                term.setTextColor(colors.lime)
                term.write("Packages: READY")
            end
        end
    end

    if height >= 20 then
        local serviceSummary = supervisor:summary()

        term.setCursorPos(4, 18)

        if serviceSummary.failed > 0 then
            term.setTextColor(colors.red)
        elseif serviceSummary.restarting > 0 or serviceSummary.starting > 0 then
            term.setTextColor(colors.orange)
        elseif serviceSummary.running == serviceSummary.total then
            term.setTextColor(colors.lime)
        else
            term.setTextColor(colors.orange)
        end

        term.write(string.format(
            "Services: %d/%d RUNNING",
            serviceSummary.running,
            serviceSummary.total
        ))
    end

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

local function installedGames()
    local installed = packages:listInstalled()

    if not installed then
        return {}
    end

    local result = {}

    for _, installedItem in ipairs(installed) do
        local packageItem = packages:getPackage(installedItem.id)

        if packageItem
            and packageItem.type == "game"
            and packageItem.entrypoint
            and fs.exists("/" .. packageItem.entrypoint)
            and not fs.isDir("/" .. packageItem.entrypoint)
        then
            result[#result + 1] = {
                id = packageItem.id,
                label = packageItem.name,
                path = "/" .. packageItem.entrypoint
            }
        end
    end

    table.sort(result, function(a, b)
        return a.label < b.label
    end)

    return result
end

local GAME_COLORS = {
    colors.blue,
    colors.cyan,
    colors.brown,
    colors.purple,
    colors.green,
    colors.orange
}

local function createGamesScreen()
    local games = installedGames()
    local width, height = term.getSize()
    local buttonWidth = math.min(28, math.max(18, width - 12))
    local x = math.max(2, math.floor((width - buttonWidth) / 2) + 1)
    local screen = Screen.new(term, {
        columns = 1
    })
    local actions = {}
    local y = 5
    local maxGameY = math.max(5, height - 7)

    for index, game in ipairs(games) do
        if y <= maxGameY then
            local actionId = "package-game-" .. tostring(index)
            local background = GAME_COLORS[
                ((index - 1) % #GAME_COLORS) + 1
            ]

            screen:addButton({
                id = actionId,
                label = game.label,
                x = x,
                y = y,
                width = buttonWidth,
                height = 2,
                backgroundColor = background,
                textColor = background == colors.cyan
                    and colors.black
                    or colors.white
            })

            actions[actionId] = game
            y = y + 3
        end
    end

    local backY = math.min(math.max(8, y), math.max(8, height - 4))

    screen:addButton({
        id = "back",
        label = "Back",
        x = x,
        y = backY,
        width = buttonWidth,
        height = 2,
        backgroundColor = colors.gray,
        textColor = colors.white
    })

    return screen, actions, #games
end

local function drawGamesScreen(screen, gameCount)
    ui.drawHeader(APP_TITLE)

    ui.centerText(
        term,
        4,
        "GAMES",
        colors.lightGray
    )

    if gameCount == 0 then
        ui.centerText(
            term,
            7,
            "No games installed.",
            colors.orange
        )
        ui.centerText(
            term,
            9,
            "Use: pkg install game.<name>",
            colors.lightGray
        )
    end

    screen:draw()
    ui.drawFooter("MOUSE CLICK  UP/DOWN  ENTER  LEFT/SHIFT")
end

local function showGames()
    local screen, actions, gameCount = createGamesScreen()

    while true do
        drawGamesScreen(screen, gameCount)

        local event, a, b, c = os.pullEvent()

        if event == "term_resize" then
            screen, actions, gameCount = createGamesScreen()
        elseif event == "key" and (a == keys.left or a == keys.leftShift) then
            return
        else
            local action, changed = screen:handleEvent(event, a, b, c)

            if action == "back" then
                return
            elseif action and actions[action] then
                local game = actions[action]
                runProgram(game.label, game.path)
                screen, actions, gameCount = createGamesScreen()
            elseif changed then
                drawGamesScreen(screen, gameCount)
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

local function runMainLoop()
    local ok, err = pcall(mainLoop)
    supervisor:stop()

    if not ok then
        error(err, 0)
    end
end

parallel.waitForAny(
    runMainLoop,
    function()
        supervisor:run()
    end
)
