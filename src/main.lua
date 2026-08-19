local selected = 1

local menuItems = {
    "System status",
    "Hello",
    "Reboot",
    "Shutdown"
}

local function resetColors()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function centerText(y, text, textColor, backgroundColor)
    local width = term.getSize()

    term.setCursorPos(
        math.floor((width - #text) / 2) + 1,
        y
    )

    if backgroundColor then
        term.setBackgroundColor(backgroundColor)
    end

    if textColor then
        term.setTextColor(textColor)
    end

    term.write(text)
end

local function drawHeader()
    resetColors()
    term.clear()

    local width = term.getSize()

    term.setBackgroundColor(colors.blue)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    centerText(
        2,
        "BASE CONTROL SYSTEM",
        colors.white,
        colors.blue
    )

    resetColors()
end

local function drawFooter(text)
    local width, height = term.getSize()

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)

    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))

    centerText(
        height,
        text,
        colors.white,
        colors.gray
    )

    resetColors()
end

local function drawMenu()
    drawHeader()

    centerText(
        5,
        "MAIN MENU",
        colors.lightGray
    )

    for i, item in ipairs(menuItems) do
        local y = 6 + i * 2

        if i == selected then
            term.setBackgroundColor(colors.white)
            term.setTextColor(colors.black)

            term.setCursorPos(5, y)
            term.write(" > " .. item .. " ")

            resetColors()
        else
            term.setCursorPos(7, y)
            term.setTextColor(colors.lightGray)
            term.write(item)

            resetColors()
        end
    end

    drawFooter("UP/DOWN  ENTER  ESC")
end

local function waitForBack()
    while true do
        local event, key = os.pullEvent("key")

        if key == keys.left then
            return
        end
    end
end

local function showStatus()
    drawHeader()

    centerText(
        5,
        "SYSTEM STATUS",
        colors.cyan
    )

    term.setCursorPos(4, 8)
    term.setTextColor(colors.lime)
    term.write("STATUS: ONLINE")

    resetColors()

    term.setCursorPos(4, 10)
    term.write(
        "Computer ID: " ..
        os.getComputerID()
    )

    local label = os.getComputerLabel()

    term.setCursorPos(4, 11)

    if label then
        term.write("Computer name: " .. label)
    else
        term.write("Computer name: NOT SET")
    end

    local width, height = term.getSize()

    term.setCursorPos(4, 13)
    term.write(
        "Terminal: " ..
        width ..
        "x" ..
        height
    )

    drawFooter("LEFT - Back")

    waitForBack()
end

local function showHello()
    drawHeader()

    centerText(
        8,
        "Hello!",
        colors.lime
    )

    centerText(
        10,
        "BASE_MAIN is online.",
        colors.white
    )

    drawFooter("LEFT - Back")

    waitForBack()
end

local function rebootComputer()
    drawHeader()

    centerText(
        8,
        "REBOOTING...",
        colors.orange
    )

    sleep(1)

    os.reboot()
end

local function shutdownComputer()
    drawHeader()

    centerText(
        8,
        "SHUTTING DOWN...",
        colors.red
    )

    sleep(1)

    os.shutdown()
end

while true do
    drawMenu()

    local event, key = os.pullEvent("key")

    if key == keys.up then

        selected = selected - 1

        if selected < 1 then
            selected = #menuItems
        end

    elseif key == keys.down then

        selected = selected + 1

        if selected > #menuItems then
            selected = 1
        end

    elseif key == keys.enter then

        if selected == 1 then
            showStatus()

        elseif selected == 2 then
            showHello()

        elseif selected == 3 then
            rebootComputer()

        elseif selected == 4 then
            shutdownComputer()
        end

    elseif key == keys.escape then

        resetColors()
        term.clear()
        term.setCursorPos(1, 1)

        print("BASE CONTROL SYSTEM closed.")

        break
    end
end