local Automation = require("lib.automation")
local Button = require("lib.gui.button")
local Toggle = require("lib.gui.toggle")
local Slider = require("lib.gui.slider")
local TabBar = require("lib.gui.tabbar")
local List = require("lib.gui.list")
local KeyRepeat = require("lib.input.key_repeat")

local CONFIG_PATH = "/data/automation.json"

local sides = {
    "left",
    "right",
    "front",
    "back",
    "top",
    "bottom"
}

local operators = {
    ">=",
    ">",
    "<=",
    "<",
    "==",
    "!="
}

local actionModes = {
    {
        value = "hold",
        label = "HOLD"
    },
    {
        value = "pulse",
        label = "PULSE"
    },
    {
        value = "delay",
        label = "DELAY"
    }
}

local config = Automation.loadConfig(CONFIG_PATH)
local confirmDelete = false
local formFocus = 1

local form = {
    inputIndex = 1,
    operatorIndex = 1,
    threshold = 1,
    outputIndex = 2,
    actionIndex = 1,
    outputValue = 15,
    seconds = 5
}

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

    term.setBackgroundColor(colors.purple)
    term.setTextColor(colors.white)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    centerText(
        2,
        "AUTOMATION CONTROL",
        colors.white,
        colors.purple
    )
end

local function drawFooter(text)
    local width, height = term.getSize()

    text = text or "MOUSE CLICK  ARROWS  ENTER  SHIFT BACK"

    if #text > width then
        text = "MOUSE  ARROWS  ENTER  SHIFT"
    end

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))

    local x = math.max(
        1,
        math.floor((width - #text) / 2) + 1
    )

    term.setCursorPos(x, height)
    term.write(text:sub(1, width))
    resetColors()
end

local function writeLine(x, y, width, text, color)
    text = tostring(text or "")

    if #text > width then
        text = text:sub(1, width)
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(color or colors.white)
    term.setCursorPos(x, y)
    term.write(text)
    term.write(string.rep(" ", math.max(0, width - #text)))
    resetColors()
end

local function saveConfig()
    local ok, err = Automation.saveConfig(
        CONFIG_PATH,
        config
    )

    if not ok then
        clear()
        drawHeader()
        centerText(9, "SAVE ERROR", colors.red)
        centerText(11, tostring(err), colors.white)
        sleep(2)
        return false
    end

    os.queueEvent("automation_reload")
    config = Automation.loadConfig(CONFIG_PATH)
    return true
end

local function makeRuleName(rule)
    local base = string.format(
        "%s%s%d -> %s=%d",
        rule.inputSide:upper(),
        rule.operator,
        rule.threshold,
        rule.outputSide:upper(),
        rule.outputValue
    )

    if rule.actionMode == "pulse" then
        return base .. " PULSE " .. tostring(rule.seconds) .. "s"
    elseif rule.actionMode == "delay" then
        return base .. " AFTER " .. tostring(rule.seconds) .. "s"
    end

    return base
end

local function cycle(value, count, delta)
    value = value + delta

    while value < 1 do
        value = value + count
    end

    while value > count do
        value = value - count
    end

    return value
end

local function resetForm()
    form.inputIndex = 1
    form.operatorIndex = 1
    form.threshold = 1
    form.outputIndex = 2
    form.actionIndex = 1
    form.outputValue = 15
    form.seconds = 5
    formFocus = 1
end

local width, height = term.getSize()

if width < 48 or height < 18 then
    clear()
    error("Terminal is too small for graphical Automation UI")
end

local tabBar = TabBar.new({
    x = 1,
    y = 4,
    width = width,
    tabs = {
        {id = "rules", label = "RULES"},
        {id = "add", label = "ADD RULE"},
        {id = "status", label = "STATUS"}
    },
    selectedIndex = 1,
    backgroundColor = colors.gray,
    textColor = colors.white,
    selectedBackgroundColor = colors.lightBlue,
    selectedTextColor = colors.black
})

local ruleList = List.new({
    x = 2,
    y = 6,
    width = width - 3,
    height = 7,
    items = config.rules,
    getLabel = function(rule)
        local prefix = rule.enabled and "ON  " or "OFF "
        return prefix .. rule.name
    end
})

local ruleToggle = Toggle.new({
    id = "rule-toggle",
    label = "Rule",
    x = 2,
    y = 14,
    width = 15,
    height = 2
})

local deleteButton = Button.new({
    id = "delete-rule",
    label = "Delete",
    x = 19,
    y = 14,
    width = 16,
    height = 2,
    backgroundColor = colors.red,
    textColor = colors.white,
    selectedBackgroundColor = colors.orange,
    selectedTextColor = colors.black
})

local inputButton = Button.new({
    id = "input-side",
    label = "Input: LEFT",
    x = 2,
    y = 6,
    width = 18,
    height = 2,
    backgroundColor = colors.gray
})

local operatorButton = Button.new({
    id = "operator",
    label = "Cond: >=",
    x = 22,
    y = 6,
    width = 14,
    height = 2,
    backgroundColor = colors.gray
})

local thresholdSlider = Slider.new({
    id = "threshold",
    label = "Input value",
    x = 2,
    y = 9,
    width = 34,
    min = 0,
    max = 15,
    step = 1,
    value = form.threshold
})

local outputButton = Button.new({
    id = "output-side",
    label = "Output: RIGHT",
    x = 2,
    y = 12,
    width = 18,
    height = 1,
    backgroundColor = colors.gray
})

local actionButton = Button.new({
    id = "action-mode",
    label = "Action: HOLD",
    x = 22,
    y = 12,
    width = 26,
    height = 1,
    backgroundColor = colors.gray
})

local outputSlider = Slider.new({
    id = "output-value",
    label = "Output",
    x = 2,
    y = 14,
    width = 22,
    min = 0,
    max = 15,
    step = 1,
    value = form.outputValue
})

local secondsSlider = Slider.new({
    id = "seconds",
    label = "Seconds",
    x = 27,
    y = 14,
    width = 22,
    min = 1,
    max = 60,
    step = 1,
    value = form.seconds
})

local createButton = Button.new({
    id = "create",
    label = "CREATE RULE",
    x = 2,
    y = 17,
    width = 20,
    height = 1,
    backgroundColor = colors.green,
    textColor = colors.black
})

local resetButton = Button.new({
    id = "reset",
    label = "RESET",
    x = 24,
    y = 17,
    width = 12,
    height = 1,
    backgroundColor = colors.gray
})

local engineToggle = Toggle.new({
    id = "engine",
    label = "Engine",
    x = 2,
    y = 6,
    width = 18,
    height = 2,
    value = config.enabled
})

local focusControls = {
    "input",
    "operator",
    "threshold",
    "output",
    "action",
    "outputValue",
    "seconds",
    "create",
    "reset"
}

local keyRepeat = KeyRepeat.new({
    keys = {
        keys.left,
        keys.right
    },
    initialDelay = 0.35,
    repeatDelay = 0.08
})

local function currentActionMode()
    return actionModes[form.actionIndex].value
end

local function syncFormControls()
    inputButton.label = "Input: " .. sides[form.inputIndex]:upper()
    operatorButton.label = "Cond: " .. operators[form.operatorIndex]
    outputButton.label = "Output: " .. sides[form.outputIndex]:upper()
    actionButton.label = "Action: " .. actionModes[form.actionIndex].label

    thresholdSlider:setValue(form.threshold)
    outputSlider:setValue(form.outputValue)
    secondsSlider:setValue(form.seconds)
    secondsSlider:setEnabled(currentActionMode() ~= "hold")

    inputButton:setSelected(false)
    operatorButton:setSelected(false)
    thresholdSlider:setSelected(false)
    outputButton:setSelected(false)
    actionButton:setSelected(false)
    outputSlider:setSelected(false)
    secondsSlider:setSelected(false)
    createButton:setSelected(false)
    resetButton:setSelected(false)

    local focus = focusControls[formFocus]

    if focus == "input" then
        inputButton:setSelected(true)
    elseif focus == "operator" then
        operatorButton:setSelected(true)
    elseif focus == "threshold" then
        thresholdSlider:setSelected(true)
    elseif focus == "output" then
        outputButton:setSelected(true)
    elseif focus == "action" then
        actionButton:setSelected(true)
    elseif focus == "outputValue" then
        outputSlider:setSelected(true)
    elseif focus == "seconds" then
        secondsSlider:setSelected(true)
    elseif focus == "create" then
        createButton:setSelected(true)
    elseif focus == "reset" then
        resetButton:setSelected(true)
    end
end

local function moveFormFocus(delta)
    local count = #focusControls

    repeat
        formFocus = cycle(formFocus, count, delta)
    until focusControls[formFocus] ~= "seconds" or currentActionMode() ~= "hold"
end

local function adjustFocused(delta)
    local focus = focusControls[formFocus]

    if focus == "input" then
        form.inputIndex = cycle(form.inputIndex, #sides, delta)
    elseif focus == "operator" then
        form.operatorIndex = cycle(form.operatorIndex, #operators, delta)
    elseif focus == "threshold" then
        form.threshold = math.max(0, math.min(15, form.threshold + delta))
    elseif focus == "output" then
        form.outputIndex = cycle(form.outputIndex, #sides, delta)
    elseif focus == "action" then
        form.actionIndex = cycle(form.actionIndex, #actionModes, delta)
    elseif focus == "outputValue" then
        form.outputValue = math.max(0, math.min(15, form.outputValue + delta))
    elseif focus == "seconds" and currentActionMode() ~= "hold" then
        form.seconds = math.max(1, math.min(60, form.seconds + delta))
    end

    syncFormControls()
end

local function createRule()
    local rule = {
        enabled = true,
        inputSide = sides[form.inputIndex],
        operator = operators[form.operatorIndex],
        threshold = form.threshold,
        outputSide = sides[form.outputIndex],
        outputValue = form.outputValue,
        actionMode = currentActionMode(),
        seconds = currentActionMode() == "hold" and 1 or form.seconds
    }

    rule.name = makeRuleName(rule)
    table.insert(config.rules, rule)

    if saveConfig() then
        ruleList:setItems(config.rules)
        ruleList:setSelected(#config.rules)
        resetForm()
        tabBar:setSelected(1)
    end
end

local function getSelectedRule()
    return config.rules[ruleList:getSelectedIndex()]
end

local function syncRuleControls()
    ruleList:setItems(config.rules)

    local rule = getSelectedRule()
    local hasRule = rule ~= nil

    ruleToggle:setEnabled(hasRule)
    deleteButton:setEnabled(hasRule)

    if rule then
        ruleToggle:setValue(rule.enabled)
    else
        ruleToggle:setValue(false)
    end

    deleteButton.label = confirmDelete and "CONFIRM DELETE" or "Delete"
end

local function toggleSelectedRule()
    local rule = getSelectedRule()

    if not rule then
        return
    end

    rule.enabled = not rule.enabled
    confirmDelete = false
    saveConfig()
    syncRuleControls()
end

local function deleteSelectedRule()
    local index = ruleList:getSelectedIndex()

    if index < 1 or not config.rules[index] then
        return
    end

    if not confirmDelete then
        confirmDelete = true
        syncRuleControls()
        return
    end

    table.remove(config.rules, index)
    confirmDelete = false
    saveConfig()
    ruleList:setItems(config.rules)
    syncRuleControls()
end

local function drawRules()
    syncRuleControls()
    ruleList:draw(term)
    ruleToggle:draw(term)
    deleteButton:draw(term)

    local rule = getSelectedRule()

    if rule then
        local details = string.format(
            "%s %s %d | %s=%d | %s",
            rule.inputSide:upper(),
            rule.operator,
            rule.threshold,
            rule.outputSide:upper(),
            rule.outputValue,
            rule.actionMode:upper()
        )

        writeLine(2, 17, width - 3, details, colors.lightGray)
    else
        writeLine(2, 17, width - 3, "Create a rule from ADD RULE tab.", colors.lightGray)
    end
end

local function drawAdd()
    syncFormControls()

    inputButton:draw(term)
    operatorButton:draw(term)
    thresholdSlider:draw(term)
    outputButton:draw(term)
    actionButton:draw(term)
    outputSlider:draw(term)
    secondsSlider:draw(term)

    local previewRule = {
        inputSide = sides[form.inputIndex],
        operator = operators[form.operatorIndex],
        threshold = form.threshold,
        outputSide = sides[form.outputIndex],
        outputValue = form.outputValue,
        actionMode = currentActionMode(),
        seconds = form.seconds
    }

    writeLine(
        2,
        16,
        width - 3,
        makeRuleName(previewRule),
        colors.lightGray
    )

    createButton:draw(term)
    resetButton:draw(term)
end

local function drawStatus()
    engineToggle:setValue(config.enabled)
    engineToggle:draw(term)

    local enabledRules = 0

    for _, rule in ipairs(config.rules) do
        if rule.enabled then
            enabledRules = enabledRules + 1
        end
    end

    writeLine(
        22,
        6,
        width - 23,
        "Rules: " .. tostring(#config.rules),
        colors.white
    )

    writeLine(
        22,
        7,
        width - 23,
        "Enabled: " .. tostring(enabledRules),
        colors.lime
    )

    writeLine(2, 9, width - 3, "SIDE      INPUT   IN   OUT", colors.lightGray)

    for i, side in ipairs(sides) do
        local analogInput = redstone.getAnalogInput(side)
        local analogOutput = redstone.getAnalogOutput(side)
        local digitalInput = redstone.getInput(side)

        local row = string.format(
            "%-9s %-6s %2d   %2d",
            side:upper(),
            digitalInput and "ON" or "OFF",
            analogInput,
            analogOutput
        )

        writeLine(
            2,
            9 + i,
            width - 3,
            row,
            digitalInput and colors.lime or colors.white
        )
    end

    writeLine(
        2,
        17,
        width - 3,
        "Automation service updates outputs in background.",
        colors.lightGray
    )
end

local function draw()
    clear()
    drawHeader()
    tabBar.width = width
    tabBar:draw(term)

    local tab = tabBar:getSelected()

    if tab and tab.id == "rules" then
        drawRules()
        drawFooter("CLICK RULE  ENTER TOGGLE  DELETE BUTTON  SHIFT BACK")
    elseif tab and tab.id == "add" then
        drawAdd()
        drawFooter("CLICK CONTROLS  HOLD LEFT/RIGHT  ENTER  SHIFT BACK")
    elseif tab and tab.id == "status" then
        drawStatus()
        drawFooter("CLICK ENGINE TOGGLE  SHIFT BACK")
    end

    resetColors()
end

local function handleRulesEvent(event, a, b, c)
    if event == "mouse_click" and a == 1 then
        local oldIndex = ruleList:getSelectedIndex()
        local index = ruleList:findAt(b, c)

        if index then
            ruleList:setSelected(index)

            if oldIndex ~= index then
                confirmDelete = false
            end

            return true
        end

        if ruleToggle:contains(b, c) then
            toggleSelectedRule()
            return true
        end

        if deleteButton:contains(b, c) then
            deleteSelectedRule()
            return true
        end

    elseif event == "key" then
        if a == keys.up then
            confirmDelete = false
            ruleList:move(-1)
            return true
        elseif a == keys.down then
            confirmDelete = false
            ruleList:move(1)
            return true
        elseif a == keys.enter then
            toggleSelectedRule()
            return true
        elseif a == keys.right then
            deleteSelectedRule()
            return true
        end
    end

    return false
end

local function handleAddPointer(x, y)
    if inputButton:contains(x, y) then
        form.inputIndex = cycle(form.inputIndex, #sides, 1)
        formFocus = 1
        return true
    elseif operatorButton:contains(x, y) then
        form.operatorIndex = cycle(form.operatorIndex, #operators, 1)
        formFocus = 2
        return true
    elseif thresholdSlider:handlePointer(x, y) then
        form.threshold = thresholdSlider:getValue()
        formFocus = 3
        return true
    elseif outputButton:contains(x, y) then
        form.outputIndex = cycle(form.outputIndex, #sides, 1)
        formFocus = 4
        return true
    elseif actionButton:contains(x, y) then
        form.actionIndex = cycle(form.actionIndex, #actionModes, 1)
        formFocus = 5
        return true
    elseif outputSlider:handlePointer(x, y) then
        form.outputValue = outputSlider:getValue()
        formFocus = 6
        return true
    elseif secondsSlider.enabled and secondsSlider:handlePointer(x, y) then
        form.seconds = secondsSlider:getValue()
        formFocus = 7
        return true
    elseif createButton:contains(x, y) then
        formFocus = 8
        createRule()
        return true
    elseif resetButton:contains(x, y) then
        resetForm()
        return true
    end

    return false
end

local function handleAddEvent(event, a, b, c)
    local repeatedKey = keyRepeat:handleEvent(event, a)

    if repeatedKey == keys.left then
        adjustFocused(-1)
        return true
    elseif repeatedKey == keys.right then
        adjustFocused(1)
        return true
    end

    if event == "mouse_click" and a == 1 then
        local changed = handleAddPointer(b, c)
        syncFormControls()
        return changed

    elseif event == "key" then
        if a == keys.up then
            moveFormFocus(-1)
            syncFormControls()
            return true
        elseif a == keys.down then
            moveFormFocus(1)
            syncFormControls()
            return true
        elseif a == keys.left then
            adjustFocused(-1)
            return true
        elseif a == keys.right then
            adjustFocused(1)
            return true
        elseif a == keys.enter then
            local focus = focusControls[formFocus]

            if focus == "create" then
                createRule()
            elseif focus == "reset" then
                resetForm()
            elseif focus == "input" or
                focus == "operator" or
                focus == "output" or
                focus == "action"
            then
                adjustFocused(1)
            end

            return true
        end
    end

    return false
end

local function handleStatusEvent(event, a, b, c)
    if event == "mouse_click" and a == 1 then
        if engineToggle:contains(b, c) then
            config.enabled = not config.enabled
            saveConfig()
            engineToggle:setValue(config.enabled)
            return true
        end

    elseif event == "key" and a == keys.enter then
        config.enabled = not config.enabled
        saveConfig()
        engineToggle:setValue(config.enabled)
        return true
    end

    return false
end

draw()

local refreshTimer = os.startTimer(0.25)

while true do
    local event, a, b, c = os.pullEvent()
    local redraw = false

    if event == "key" and a == keys.leftShift then
        break
    end

    if event == "term_resize" then
        width, height = term.getSize()

        if width < 48 or height < 18 then
            clear()
            error("Terminal is too small for graphical Automation UI")
        end

        tabBar.width = width
        ruleList.width = width - 3
        redraw = true

    elseif event == "mouse_click" and a == 1 then
        local tabIndex = tabBar:findAt(b, c)

        if tabIndex then
            tabBar:setSelected(tabIndex)
            confirmDelete = false
            keyRepeat:cancel()
            redraw = true
        else
            local tab = tabBar:getSelected()

            if tab and tab.id == "rules" then
                redraw = handleRulesEvent(event, a, b, c)
            elseif tab and tab.id == "add" then
                redraw = handleAddEvent(event, a, b, c)
            elseif tab and tab.id == "status" then
                redraw = handleStatusEvent(event, a, b, c)
            end
        end

    elseif event == "timer" and a == refreshTimer then
        config = Automation.loadConfig(CONFIG_PATH)
        ruleList:setItems(config.rules)
        redraw = true
        refreshTimer = os.startTimer(0.25)

        local tab = tabBar:getSelected()

        if tab and tab.id == "add" then
            handleAddEvent(event, a, b, c)
        end

    else
        local tab = tabBar:getSelected()

        if tab and tab.id == "rules" then
            redraw = handleRulesEvent(event, a, b, c)
        elseif tab and tab.id == "add" then
            redraw = handleAddEvent(event, a, b, c)
        elseif tab and tab.id == "status" then
            redraw = handleStatusEvent(event, a, b, c)
        end
    end

    if redraw then
        draw()
    end
end

keyRepeat:cancel()
clear()
print("Automation closed.")
