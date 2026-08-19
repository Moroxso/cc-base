local sides = {
    "left",
    "right",
    "front",
    "back",
    "top",
    "bottom"
}

local selected = 1

local function resetColors()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function clear()
    resetColors()
    term.clear()
    term.setCursorPos(1, 1)
end

local function centerText(y, text, color)
    local width = term.getSize()

    if color then
        term.setTextColor(color)
    end

    local x = math.floor((width - #text) / 2) + 1
    term.setCursorPos(x, y)
    term.write(text)

    resetColors()
end

local function padRight(text, width)
    text = tostring(text)

    if #text >= width then
        return text:sub(1, width)
    end

    return text .. string.rep(" ", width - #text)
end

local function drawHeader()
    local width = term.getSize()

    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    centerText(2, "REDSTONE CONTROL", colors.white)
    resetColors()
end

local function drawFooter()
    local width, height = term.getSize()

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))

    local footer = "UP/DOWN  LEFT/RIGHT  ENTER  SHIFT"
    local x = math.max(1, math.floor((width - #footer) / 2) + 1)

    term.setCursorPos(x, height)
    term.write(footer:sub(1, width))

    resetColors()
end

local function getSideState(side)
    return {
        digitalInput = redstone.getInput(side),
        analogInput = redstone.getAnalogInput(side),
        analogOutput = redstone.getAnalogOutput(side)
    }
end

local function draw()
    clear()
    drawHeader()

    term.setCursorPos(3, 5)
    term.setTextColor(colors.lightGray)
    term.write("SIDE      INPUT       IN   OUT")

    for i, side in ipairs(sides) do
        local state = getSideState(side)
        local y = 6 + i

        if i == selected then
            term.setBackgroundColor(colors.white)
            term.setTextColor(colors.black)
        else
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
        end

        local inputText = state.digitalInput and "ON" or "OFF"
        local row =
            (i == selected and "> " or "  ") ..
            padRight(side:upper(), 8) ..
            padRight(inputText, 12) ..
            padRight(state.analogInput, 5) ..
            padRight(state.analogOutput, 4)

        term.setCursorPos(2, y)
        term.write(row)
        resetColors()
    end

    local currentSide = sides[selected]
    local currentOutput = redstone.getAnalogOutput(currentSide)

    term.setCursorPos(3, 14)
    term.setTextColor(colors.cyan)
    term.write("Selected: " .. currentSide:upper())

    term.setCursorPos(3, 15)
    term.setTextColor(
        currentOutput > 0 and colors.lime or colors.red
    )
    term.write(
        "Output: " ..
        (currentOutput > 0 and "ON" or "OFF") ..
        " (" .. currentOutput .. "/15)"
    )

    term.setCursorPos(3, 17)
    term.setTextColor(colors.lightGray)
    term.write("ENTER: toggle  LEFT/RIGHT: level")

    resetColors()
    drawFooter()
end

local function changeAnalogOutput(delta)
    local side = sides[selected]
    local current = redstone.getAnalogOutput(side)
    local nextValue = math.max(0, math.min(15, current + delta))

    redstone.setAnalogOutput(side, nextValue)
end

local function toggleOutput()
    local side = sides[selected]
    local current = redstone.getAnalogOutput(side)

    if current > 0 then
        redstone.setAnalogOutput(side, 0)
    else
        redstone.setAnalogOutput(side, 15)
    end
end

while true do
    draw()

    local event, key = os.pullEvent()

    if event == "key" then
        if key == keys.up then
            selected = selected - 1

            if selected < 1 then
                selected = #sides
            end

        elseif key == keys.down then
            selected = selected + 1

            if selected > #sides then
                selected = 1
            end

        elseif key == keys.left then
            changeAnalogOutput(-1)

        elseif key == keys.right then
            changeAnalogOutput(1)

        elseif key == keys.enter then
            toggleOutput()

        elseif key == keys.leftShift then
            break
        end
    end
end

clear()
print("Redstone Control closed.")
