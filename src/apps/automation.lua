package.path = package.path .. ";/?.lua;/?/init.lua"

local Automation = require("lib.automation")

local CONFIG_PATH = "/data/automation.json"

local sides = {
    "left",
    "right",
    "front",
    "back",
    "top",
    "bottom"
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

local function centerText(y, text, color)
    local width = term.getSize()

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

local function drawHeader(title)
    local width = term.getSize()

    term.setBackgroundColor(colors.purple)
    term.setTextColor(colors.white)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    centerText(2, title, colors.white)
    resetColors()
end

local function drawFooter(text)
    local width, height = term.getSize()

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

local function saveConfig(config)
    local ok, err = Automation.saveConfig(
        CONFIG_PATH,
        config
    )

    if not ok then
        clear()
        print("SAVE ERROR")
        print("")
        print(tostring(err))
        sleep(2)
        return false
    end

    os.queueEvent("automation_reload")
    return true
end

local function chooseFromList(title, items)
    local selected = 1

    while true do
        clear()
        drawHeader(title)

        for i, item in ipairs(items) do
            local y = 5 + i

            if i == selected then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
                term.setCursorPos(4, y)
                term.write(" > " .. tostring(item) .. " ")
                resetColors()
            else
                term.setCursorPos(6, y)
                term.write(tostring(item))
            end
        end

        drawFooter("UP/DOWN  ENTER  SHIFT")

        local _, key = os.pullEvent("key")

        if key == keys.up then
            selected = selected - 1

            if selected < 1 then
                selected = #items
            end

        elseif key == keys.down then
            selected = selected + 1

            if selected > #items then
                selected = 1
            end

        elseif key == keys.enter then
            return selected

        elseif key == keys.leftShift then
            return nil
        end
    end
end

local function chooseLevel(title, initial)
    local value = initial or 0

    while true do
        clear()
        drawHeader(title)

        centerText(
            8,
            tostring(value) .. " / 15",
            colors.cyan
        )

        local barWidth = 15
        local bar = string.rep("#", value) ..
            string.rep("-", barWidth - value)

        centerText(10, "[" .. bar .. "]", colors.white)

        drawFooter("LEFT/RIGHT  ENTER  SHIFT")

        local _, key = os.pullEvent("key")

        if key == keys.left then
            value = math.max(0, value - 1)

        elseif key == keys.right then
            value = math.min(15, value + 1)

        elseif key == keys.enter then
            return value

        elseif key == keys.leftShift then
            return nil
        end
    end
end

local function addRule(config)
    local inputIndex = chooseFromList(
        "INPUT SIDE",
        sides
    )

    if not inputIndex then
        return
    end

    local threshold = chooseLevel(
        "INPUT THRESHOLD",
        1
    )

    if threshold == nil then
        return
    end

    local outputIndex = chooseFromList(
        "OUTPUT SIDE",
        sides
    )

    if not outputIndex then
        return
    end

    local outputValue = chooseLevel(
        "OUTPUT LEVEL",
        15
    )

    if outputValue == nil then
        return
    end

    local inputSide = sides[inputIndex]
    local outputSide = sides[outputIndex]

    local rule = {
        name = string.format(
            "%s>=%d -> %s=%d",
            inputSide:upper(),
            threshold,
            outputSide:upper(),
            outputValue
        ),
        enabled = true,
        inputSide = inputSide,
        threshold = threshold,
        outputSide = outputSide,
        outputValue = outputValue
    }

    table.insert(config.rules, rule)

    if saveConfig(config) then
        clear()
        drawHeader("AUTOMATION")
        centerText(8, "RULE CREATED", colors.lime)
        centerText(10, rule.name, colors.white)
        sleep(1.5)
    end
end

local function confirmDelete(rule)
    local selected = 2
    local options = {
        "Delete",
        "Cancel"
    }

    while true do
        clear()
        drawHeader("DELETE RULE")
        centerText(5, rule.name, colors.orange)

        for i, item in ipairs(options) do
            local y = 8 + i * 2

            if i == selected then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
                term.setCursorPos(5, y)
                term.write(" > " .. item .. " ")
                resetColors()
            else
                term.setCursorPos(7, y)
                term.write(item)
            end
        end

        drawFooter("UP/DOWN  ENTER  SHIFT")

        local _, key = os.pullEvent("key")

        if key == keys.up then
            selected = math.max(1, selected - 1)
        elseif key == keys.down then
            selected = math.min(#options, selected + 1)
        elseif key == keys.enter then
            return selected == 1
        elseif key == keys.leftShift then
            return false
        end
    end
end

local function manageRules(config)
    local selected = 1

    while true do
        if #config.rules == 0 then
            clear()
            drawHeader("RULES")
            centerText(8, "NO RULES", colors.lightGray)
            centerText(10, "Create one from Automation menu.", colors.white)
            drawFooter("SHIFT - Back")

            local _, key = os.pullEvent("key")

            if key == keys.leftShift then
                return
            end
        else
            if selected > #config.rules then
                selected = #config.rules
            end

            clear()
            drawHeader("RULES")

            local _, height = term.getSize()
            local maxVisible = math.max(1, height - 8)
            local first = 1

            if selected > maxVisible then
                first = selected - maxVisible + 1
            end

            local last = math.min(
                #config.rules,
                first + maxVisible - 1
            )

            local row = 5

            for i = first, last do
                local rule = config.rules[i]
                local prefix = rule.enabled and "ON " or "OFF"
                local text = prefix .. " " .. rule.name

                if i == selected then
                    term.setBackgroundColor(colors.white)
                    term.setTextColor(colors.black)
                    term.setCursorPos(2, row)
                    term.write("> " .. text)
                    resetColors()
                else
                    term.setCursorPos(4, row)
                    term.setTextColor(
                        rule.enabled and colors.lime or colors.gray
                    )
                    term.write(text)
                    resetColors()
                end

                row = row + 1
            end

            term.setCursorPos(2, height - 2)
            term.setTextColor(colors.lightGray)
            term.write("ENTER toggle  RIGHT delete")
            resetColors()

            drawFooter("UP/DOWN  ENTER  RIGHT  SHIFT")

            local _, key = os.pullEvent("key")

            if key == keys.up then
                selected = selected - 1

                if selected < 1 then
                    selected = #config.rules
                end

            elseif key == keys.down then
                selected = selected + 1

                if selected > #config.rules then
                    selected = 1
                end

            elseif key == keys.enter then
                local rule = config.rules[selected]
                rule.enabled = not rule.enabled
                saveConfig(config)

            elseif key == keys.right then
                local rule = config.rules[selected]

                if confirmDelete(rule) then
                    table.remove(config.rules, selected)
                    saveConfig(config)

                    if selected > #config.rules then
                        selected = math.max(1, #config.rules)
                    end
                end

            elseif key == keys.leftShift then
                return
            end
        end
    end
end

local function drawMain(config, selected)
    clear()
    drawHeader("AUTOMATION")

    local items = {
        "Engine: " .. (config.enabled and "ON" or "OFF"),
        "Add rule",
        "Rules: " .. tostring(#config.rules),
        "Back"
    }

    for i, item in ipairs(items) do
        local y = 5 + i * 2

        if i == selected then
            term.setBackgroundColor(colors.white)
            term.setTextColor(colors.black)
            term.setCursorPos(5, y)
            term.write(" > " .. item .. " ")
            resetColors()
        else
            term.setCursorPos(7, y)

            if i == 1 then
                term.setTextColor(
                    config.enabled and colors.lime or colors.red
                )
            end

            term.write(item)
            resetColors()
        end
    end

    term.setCursorPos(3, 15)
    term.setTextColor(colors.lightGray)
    term.write("Rule condition: input >= threshold")

    term.setCursorPos(3, 16)
    term.write("Matching rules use highest output.")

    resetColors()
    drawFooter("UP/DOWN  ENTER  SHIFT")
end

local selected = 1
local config = Automation.loadConfig(CONFIG_PATH)

while true do
    config = Automation.loadConfig(CONFIG_PATH)
    drawMain(config, selected)

    local _, key = os.pullEvent("key")

    if key == keys.up then
        selected = selected - 1

        if selected < 1 then
            selected = 4
        end

    elseif key == keys.down then
        selected = selected + 1

        if selected > 4 then
            selected = 1
        end

    elseif key == keys.enter then
        if selected == 1 then
            config.enabled = not config.enabled
            saveConfig(config)

        elseif selected == 2 then
            addRule(config)

        elseif selected == 3 then
            manageRules(config)

        elseif selected == 4 then
            break
        end

    elseif key == keys.leftShift then
        break
    end
end

clear()
print("Automation closed.")
