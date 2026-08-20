local Runtime = require("lib.runtime")
local Screen = require("lib.gui.screen")

local width, height = term.getSize()

if width < 48 or height < 18 then
    error("Terminal is too small for Chess menu")
end

local running = true

local function resetColors()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function drawHeader()
    term.setBackgroundColor(colors.purple)
    term.setTextColor(colors.white)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    local title = "CHESS"
    term.setCursorPos(math.max(1, math.floor((width - #title) / 2) + 1), 2)
    term.write(title)
    resetColors()
end

local function makeScreen()
    local buttonWidth = math.min(30, width - 10)
    local x = math.max(2, math.floor((width - buttonWidth) / 2) + 1)
    local screen = Screen.new(term, {columns = 1})

    screen:addButton({
        id = "local",
        label = "Local PvP",
        x = x,
        y = 6,
        width = buttonWidth,
        height = 2,
        backgroundColor = colors.brown,
        textColor = colors.white
    })

    screen:addButton({
        id = "network",
        label = "Network PvP",
        x = x,
        y = 10,
        width = buttonWidth,
        height = 2,
        backgroundColor = colors.blue,
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

local screen = makeScreen()
local message = "Choose local board or CCTP multiplayer."

local function draw()
    resetColors()
    term.clear()
    drawHeader()
    screen:draw()

    term.setCursorPos(2, 17)
    term.setTextColor(colors.lightGray)
    term.write(message:sub(1, width - 2))

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))
    local footer = "MOUSE CLICK  UP/DOWN  ENTER  SHIFT back"
    term.setCursorPos(math.max(1, math.floor((width - #footer) / 2) + 1), height)
    term.write(footer:sub(1, width))
    resetColors()
end

local function launch(path, name)
    local ok, err = Runtime.run(path)

    if not ok then
        message = name .. " failed: " .. tostring(err)
    else
        message = "Choose local board or CCTP multiplayer."
    end
end

draw()

while running do
    local event, a, b, c = os.pullEvent()

    if event == "key" and a == keys.leftShift then
        running = false
    elseif event == "term_resize" then
        width, height = term.getSize()

        if width < 48 or height < 18 then
            running = false
        else
            screen = makeScreen()
            draw()
        end
    else
        local action, changed = screen:handleEvent(event, a, b, c)

        if action == "local" then
            launch("/games/chess_local.lua", "Local Chess")
            draw()
        elseif action == "network" then
            launch("/games/chess_net.lua", "Network Chess")
            draw()
        elseif action == "back" then
            running = false
        elseif changed then
            draw()
        end
    end
end

resetColors()
term.clear()
term.setCursorPos(1, 1)
print("Chess menu closed.")
