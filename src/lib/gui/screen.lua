local Button = require("lib.gui.button")

local Screen = {}
Screen.__index = Screen

function Screen.new(target, options)
    options = options or {}

    local self = setmetatable({}, Screen)

    self.target = target or term
    self.buttons = {}
    self.selectedIndex = 1
    self.columns = math.max(1, options.columns or 1)

    return self
end

function Screen:addButton(options)
    local button = Button.new(options)
    table.insert(self.buttons, button)

    if #self.buttons == 1 then
        self.selectedIndex = 1
        button:setSelected(true)
    end

    return button
end

function Screen:getSelectedButton()
    return self.buttons[self.selectedIndex]
end

function Screen:select(index)
    if #self.buttons == 0 then
        return false
    end

    index = math.max(1, math.min(#self.buttons, index))

    if index == self.selectedIndex then
        return false
    end

    local old = self.buttons[self.selectedIndex]

    if old then
        old:setSelected(false)
    end

    self.selectedIndex = index

    local current = self.buttons[self.selectedIndex]

    if current then
        current:setSelected(true)
    end

    return true
end

function Screen:move(delta)
    return self:select(self.selectedIndex + delta)
end

function Screen:moveVertical(direction)
    return self:move(direction * self.columns)
end

function Screen:moveHorizontal(direction)
    local current = self.selectedIndex
    local target = current + direction

    if target < 1 or target > #self.buttons then
        return false
    end

    local currentRow = math.floor((current - 1) / self.columns)
    local targetRow = math.floor((target - 1) / self.columns)

    if currentRow ~= targetRow then
        return false
    end

    return self:select(target)
end

function Screen:draw()
    for i, button in ipairs(self.buttons) do
        button:setSelected(i == self.selectedIndex)
        button:draw(self.target)
    end
end

function Screen:findButtonAt(x, y)
    for index, button in ipairs(self.buttons) do
        if button.enabled and button:contains(x, y) then
            return index, button
        end
    end

    return nil, nil
end

function Screen:handleEvent(event, a, b, c)
    if event == "mouse_click" then
        local mouseButton = a
        local x = b
        local y = c

        local index, button = self:findButtonAt(x, y)

        if index then
            local changed = self:select(index)

            if mouseButton == 1 then
                return button.id, true
            end

            return nil, changed
        end

    elseif event == "mouse_scroll" then
        local direction = a

        if direction > 0 then
            return nil, self:move(1)
        elseif direction < 0 then
            return nil, self:move(-1)
        end

    elseif event == "key" then
        local key = a

        if key == keys.up then
            return nil, self:moveVertical(-1)
        elseif key == keys.down then
            return nil, self:moveVertical(1)
        elseif key == keys.left then
            return nil, self:moveHorizontal(-1)
        elseif key == keys.right then
            return nil, self:moveHorizontal(1)
        elseif key == keys.enter then
            local button = self:getSelectedButton()

            if button and button.enabled then
                return button.id, false
            end
        end
    end

    return nil, false
end

return Screen
