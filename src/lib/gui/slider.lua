local Slider = {}
Slider.__index = Slider

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    elseif value > maxValue then
        return maxValue
    end

    return value
end

function Slider.new(options)
    options = options or {}

    local self = setmetatable({}, Slider)

    self.id = options.id
    self.label = tostring(options.label or "Value")
    self.x = options.x or 1
    self.y = options.y or 1
    self.width = math.max(8, options.width or 20)
    self.min = tonumber(options.min) or 0
    self.max = tonumber(options.max) or 15
    self.step = tonumber(options.step) or 1
    self.value = tonumber(options.value) or self.min
    self.enabled = options.enabled ~= false
    self.selected = options.selected == true

    self.trackColor = options.trackColor or colors.gray
    self.fillColor = options.fillColor or colors.lime
    self.textColor = options.textColor or colors.white
    self.selectedTextColor = options.selectedTextColor or colors.yellow
    self.disabledColor = options.disabledColor or colors.lightGray

    self:setValue(self.value)

    return self
end

function Slider:setSelected(value)
    self.selected = value == true
end

function Slider:setEnabled(value)
    self.enabled = value == true
end

function Slider:setValue(value)
    value = tonumber(value) or self.min
    value = clamp(value, self.min, self.max)

    if self.step > 0 then
        local steps = math.floor(((value - self.min) / self.step) + 0.5)
        value = self.min + steps * self.step
        value = clamp(value, self.min, self.max)
    end

    local changed = value ~= self.value
    self.value = value
    return changed
end

function Slider:getValue()
    return self.value
end

function Slider:change(delta)
    if not self.enabled then
        return false
    end

    return self:setValue(self.value + delta * self.step)
end

function Slider:contains(x, y)
    return
        x >= self.x and
        x < self.x + self.width and
        y >= self.y and
        y <= self.y + 1
end

function Slider:valueFromX(x)
    local trackStart = self.x + 1
    local trackWidth = math.max(1, self.width - 2)
    local localX = clamp(x - trackStart, 0, trackWidth - 1)
    local ratio = localX / math.max(1, trackWidth - 1)
    local value = self.min + (self.max - self.min) * ratio

    return value
end

function Slider:handlePointer(x, y)
    if not self.enabled or not self:contains(x, y) then
        return false
    end

    if y == self.y + 1 then
        return self:setValue(self:valueFromX(x))
    end

    return false
end

function Slider:draw(target)
    target = target or term

    local labelColor

    if not self.enabled then
        labelColor = self.disabledColor
    elseif self.selected then
        labelColor = self.selectedTextColor
    else
        labelColor = self.textColor
    end

    local valueText = tostring(self.value)
    local labelText = self.label .. ": " .. valueText

    if #labelText > self.width then
        labelText = labelText:sub(1, self.width)
    end

    target.setBackgroundColor(colors.black)
    target.setTextColor(labelColor)
    target.setCursorPos(self.x, self.y)
    target.write(labelText .. string.rep(" ", math.max(0, self.width - #labelText)))

    local trackWidth = math.max(1, self.width - 2)
    local ratio = 0

    if self.max > self.min then
        ratio = (self.value - self.min) / (self.max - self.min)
    end

    local filled = math.floor(ratio * trackWidth + 0.5)
    filled = clamp(filled, 0, trackWidth)

    target.setCursorPos(self.x, self.y + 1)
    target.setBackgroundColor(colors.black)
    target.setTextColor(labelColor)
    target.write("[")

    if filled > 0 then
        target.setTextColor(self.enabled and self.fillColor or self.disabledColor)
        target.write(string.rep("#", filled))
    end

    if filled < trackWidth then
        target.setTextColor(self.enabled and self.trackColor or self.disabledColor)
        target.write(string.rep("-", trackWidth - filled))
    end

    target.setTextColor(labelColor)
    target.write("]")
end

return Slider
