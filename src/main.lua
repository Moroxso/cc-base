local ui = require("lib.ui")
local Runtime = require("lib.runtime")
local Automation = require("lib.automation")

local APP_TITLE = "BASE CONTROL SYSTEM"
local AUTOMATION_PATH = "/data/automation.json"

local automation = Automation.new(AUTOMATION_PATH)

local mainItems = {
    "System status",
    "Hello",
    "Games",
    "Redstone",
    "Automation",
    "Reboot",
    "Shutdown"
}

local function waitForBack()
    while true do
        local _, key = os.pullEvent("key")

        if key == keys.left then
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

local function drawSelectionMenu(title, items, selected, footer)
    ui.drawHeader(APP_TITLE)

    ui.centerText(
        term,
        5,
        title,
        colors.lightGray
    )

    local _, height = term.getSize()
    local availableRows = math.max(1, height - 7)
    local spacing = 1

    if #items * 2 <= availableRows then
        spacing = 2
    end

    for i, item in ipairs(items) do
        local y = 6 + i * spacing

        if i == selected then
            term.setBackgroundColor(colors.white)
            term.setTextColor(colors.black)
            term.setCursorPos(5, y)
            term.write(" > " .. item .. " ")
        else
            term.setCursorPos(7, y)
            term.setTextColor(colors.lightGray)
            term.write(item)
        end

        ui.resetColors(term)
    end

    ui.drawFooter(footer)
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

    ui.resetColors(term)
    ui.drawFooter("LEFT - Back")

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

    ui.drawFooter("LEFT - Back")

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

    ui.drawFooter("LEFT - Back")
    waitForBack()
end

local function runProgram(name, path)
    ui.clear(term)

    local ok, err = Runtime.run(path)

    if not ok then
        showProgramError(name, err)
    end
end

local function showGames()
    local selected = 1

    local gameItems = {
        "Breakout",
        "Back"
    }

    while true do
        drawSelectionMenu(
            "GAMES",
            gameItems,
            selected,
            "UP/DOWN  ENTER  LEFT"
        )

        local _, key = os.pullEvent("key")

        if key == keys.up then
            selected = selected - 1

            if selected < 1 then
                selected = #gameItems
            end

        elseif key == keys.down then
            selected = selected + 1

            if selected > #gameItems then
                selected = 1
            end

        elseif key == keys.enter then
            if selected == 1 then
                runProgram(
                    "Breakout",
                    "/games/breakout.lua"
                )
            elseif selected == 2 then
                return
            end

        elseif key == keys.left then
            return
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

local function mainLoop()
    local selected = 1

    while true do
        drawSelectionMenu(
            "MAIN MENU",
            mainItems,
            selected,
            "UP/DOWN  ENTER  LEFT"
        )

        local _, key = os.pullEvent("key")

        if key == keys.up then
            selected = selected - 1

            if selected < 1 then
                selected = #mainItems
            end

        elseif key == keys.down then
            selected = selected + 1

            if selected > #mainItems then
                selected = 1
            end

        elseif key == keys.enter then
            if selected == 1 then
                showStatus()
            elseif selected == 2 then
                showHello()
            elseif selected == 3 then
                showGames()
            elseif selected == 4 then
                runProgram(
                    "Redstone Control",
                    "/apps/redstone.lua"
                )
            elseif selected == 5 then
                runProgram(
                    "Automation",
                    "/apps/automation.lua"
                )
            elseif selected == 6 then
                rebootComputer()
            elseif selected == 7 then
                shutdownComputer()
            end

        elseif key == keys.left then
            ui.clear(term)
            print(APP_TITLE .. " closed.")
            return
        end
    end
end

parallel.waitForAny(
    mainLoop,
    function()
        automation:run()
    end
)
