local Button = require("lib.gui.button")
local Toggle = require("lib.gui.toggle")
local Slider = require("lib.gui.slider")

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

local function centerText(y, text, color, background)
    local width = term.getSize()

    if background then
        term.setBackgroundColor(background)
    end

    if color then
        term.setTextColor(color)
    end

    local x = math.max(
        1,
        math.floor((width - #text) / 2) + 1
    )

    term.setCursorPos(x, y)
    term.write(text:sub(1, width))
    resetColors()
end

local function drawHeader()
    local width = term.getSize()

    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    centerText(
        2,
        "REDSTONE CONTROL",
        colors.white,
        colors.red
    )
end

local function drawFooter()
    local width, height = term.getSize()
    local text = "MOUSE  UP/DOWN side  LEFT/RIGHT level  ENTER toggle  SHIFT back"

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))

    if #text > width then
        text = "MOUSE  ARROWS  ENTER  SHIFT"
    end

    local x = math.max(
        1,
        math.floor((width - #text) / 2) + 1
    )

    term.setCursorPos(x, height)
    term.write(text:sub(1, width))
    resetColors()
end

local function getSideState(side)
    return {
        digitalInput = redstone.getInput(side),
        analogInput = redstone.getAnalogInput(side),
        analogOutput = redstone.getAnalogOutput(side)
    }
end

local function createLayout()
    local width, height = term.getSize()

    if width < 42 or height < 18 then
        return nil, "Terminal is too small for graphical Redstone UI"
    end

    local buttonWidth = 10
    local gap = 2
    local leftX = 2
    local rightX = leftX + buttonWidth + gap
    local rows = {5, 8, 11}

    local sideButtons = {}

    for i, side in ipairs(sides) do
        local column = ((i - 1) % 2) + 1
        local row = math.floor((i - 1) / 2) + 1

        local button = Button.new({
            id = side,
            label = side:upper(),
            x = column == 1 and leftX or rightX,
            y = rows[row],
            width = buttonWidth,
            height = 2,
            backgroundColor = colors.gray,
            textColor = colors.white,
            selectedBackgroundColor = colors.lightBlue,
            selectedTextColor = colors.black
        })

        table.insert(sideButtons, button)
    end

    local detailX = rightX + buttonWidth + 3
    local detailWidth = math.max(12, width - detailX - 1)

    local outputToggle = Toggle.new({
        id = "output-toggle",
        label = "Output",
        x = detailX,
        y = 10,
        width = math.min(detailWidth, 18),
        height = 2
    })

    local outputSlider = Slider.new({
        id = "output-level",
        label = "Level",
        x = detailX,
        y = 13,
        width = detailWidth,
        min = 0,
        max = 15,
        step = 1,
        value = 0
    })

    return {
        width = width,
        height = height,
        sideButtons = sideButtons,
        detailX = detailX,
        detailWidth = detailWidth,
        toggle = outputToggle,
        slider = outputSlider
    }
end

local function selectSide(layout, index)
    index = math.max(1, math.min(#sides, index))
    selected = index

    for i, button in ipairs(layout.sideButtons) do
        button:setSelected(i == selected)
    end
end

local function syncControls(layout)
    local side = sides[selected]
    local output = redstone.getAnalogOutput(side)

    layout.toggle:setValue(output > 0)
    layout.slider:setValue(output)
end

local function setOutput(layout, value)
    local side = sides[selected]
    value = math.max(0, math.min(15, math.floor(value + 0.5)))

    redstone.setAnalogOutput(side, value)
    syncControls(layout)
end

local function toggleOutput(layout)
    local side = sides[selected]
    local current = redstone.getAnalogOutput(side)

    if current > 0 then
        setOutput(layout, 0)
    else
        setOutput(layout, 15)
    end
end

local function drawSideButtons(layout)
    for i, button in ipairs(layout.sideButtons) do
        local state = getSideState(sides[i])

        if i ~= selected then
            if state.analogInput > 0 then
                button.backgroundColor = colors.green
                button.textColor = colors.black
            else
                button.backgroundColor = colors.gray
                button.textColor = colors.white
            end
        end

        button:setSelected(i == selected)
        button:draw(term)
    end
end

local function drawDetail(layout)
    local side = sides[selected]
    local state = getSideState(side)
    local x = layout.detailX
    local maxWidth = layout.detailWidth

    local function writeLine(y, text, color)
        text = tostring(text)

        if #text > maxWidth then
            text = text:sub(1, maxWidth)
        end

        term.setBackgroundColor(colors.black)
        term.setTextColor(color or colors.white)
        term.setCursorPos(x, y)
        term.write(text)
        term.write(string.rep(" ", math.max(0, maxWidth - #text)))
    end

    writeLine(5, "SELECTED: " .. side:upper(), colors.cyan)
    writeLine(
        7,
        "Input: " .. (state.digitalInput and "ON" or "OFF"),
        state.digitalInput and colors.lime or colors.red
    )
    writeLine(8, "Analog in: " .. tostring(state.analogInput) .. "/15", colors.white)

    syncControls(layout)
    layout.toggle:draw(term)
    layout.slider:draw(term)

    writeLine(16, "Automation may override output.", colors.lightGray)
end

local function draw(layout)
    clear()
    drawHeader()

    term.setCursorPos(2, 4)
    term.setTextColor(colors.lightGray)
    term.write("SIDES")

    drawSideButtons(layout)
    drawDetail(layout)
    drawFooter()
    resetColors()
end

local function handleMouse(layout, event, a, b, c)
    if event == "mouse_click" then
        local mouseButton = a
        local x = b
        local y = c

        if mouseButton ~= 1 then
            return false
        end

        for i, button in ipairs(layout.sideButtons) do
            if button:contains(x, y) then
                selectSide(layout, i)
                return true
            end
        end

        if layout.toggle:contains(x, y) then
            toggleOutput(layout)
            return true
        end

        if layout.slider:handlePointer(x, y) then
            setOutput(layout, layout.slider:getValue())
            return true
        end

    elseif event == "mouse_drag" then
        local mouseButton = a
        local x = b
        local y = c

        if mouseButton == 1 and layout.slider:handlePointer(x, y) then
            setOutput(layout, layout.slider:getValue())
            return true
        end

    elseif event == "mouse_scroll" then
        local direction = a

        if direction > 0 then
            selectSide(layout, math.min(#sides, selected + 1))
        elseif direction < 0 then
            selectSide(layout, math.max(1, selected - 1))
        end

        return true
    end

    return false
end

local layout, layoutError = createLayout()

if not layout then
    clear()
    error(layoutError)
end

selectSide(layout, selected)
draw(layout)

local refreshTimer = os.startTimer(0.25)

while true do
    local event, a, b, c = os.pullEvent()
    local redraw = false

    if event == "term_resize" then
        layout, layoutError = createLayout()

        if not layout then
            clear()
            error(layoutError)
        end

        selectSide(layout, selected)
        redraw = true

    elseif event == "key" then
        local key = a

        if key == keys.up then
            selected = selected - 1

            if selected < 1 then
                selected = #sides
            end

            selectSide(layout, selected)
            redraw = true

        elseif key == keys.down then
            selected = selected + 1

            if selected > #sides then
                selected = 1
            end

            selectSide(layout, selected)
            redraw = true

        elseif key == keys.left then
            local current = redstone.getAnalogOutput(sides[selected])
            setOutput(layout, current - 1)
            redraw = true

        elseif key == keys.right then
            local current = redstone.getAnalogOutput(sides[selected])
            setOutput(layout, current + 1)
            redraw = true

        elseif key == keys.enter then
            toggleOutput(layout)
            redraw = true

        elseif key == keys.leftShift then
            break
        end

    elseif event == "redstone" then
        redraw = true

    elseif event == "timer" and a == refreshTimer then
        redraw = true
        refreshTimer = os.startTimer(0.25)

    else
        redraw = handleMouse(layout, event, a, b, c)
    end

    if redraw then
        draw(layout)
    end
end

clear()
print("Redstone Control closed.")
