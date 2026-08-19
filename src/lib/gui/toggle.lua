local Toggle = {}
Toggle.__index = Toggle

local function fill(target, x, y, width, height, background)
    target.setBackgroundColor(background)

    local line = string.rep(" ", width)

    for row = y, y + height - 1 do
        target.setCursorPos(x, row)
        target.write(line)
    end
end

function Toggle.new(options)
    options = options or {}

    local self = setmetatable({}, Toggle)

    self.id = options.id
    self.label = tostring(options.label or "Toggle")
    self.x = options.x or 1
    self.y = options.y or 1
    self.width = math.max(7, options.width or 14)
    self.height = math.max(1, options.height or 2)
    self.value = options.value == true
    self.enabled = options.enabled ~= false
    self.selected = options.selected == true

    self.onColor = options.onColor or colors.green
    self.offColor = options.offColor or colors.red
    self.textColor = options.textColor or colors.white
    self.selectedColor = options.selectedColor or colors.lightBlue
    self.disabledColor = options.disabledColor or colors.gray

    return self
end

function Toggle:setValue(value)
    local nextValue = value == true
    local changed = nextValue ~= self.value
    self.value = nextValue
    return changed
end

function Toggle:getValue()
    return self.value
end

function Toggle:toggle()
    if not self.enabled then
        return false
    end

    self.value = not self.value
    return true
end

function Toggle:setSelected(value)
    self.selected = value == true
end

function Toggle:setEnabled(value)
    self.enabled = value == true
end

function Toggle:contains(x, y)
    return
        x >= self.x and
        x < self.x + self.width and
        y >= self.y and
        y < self.y + self.height
end

function Toggle:draw(target)
    target = target or term

    local background

    if not self.enabled then
        background = self.disabledColor
    elseif self.selected then
        background = self.selectedColor
    elseif self.value then
        background = self.onColor
    else
        background = self.offColor
    end

    fill(
        target,
        self.x,
        self.y,
        self.width,
        self.height,
        background
    )

    local stateText = self.value and "ON" or "OFF"
    local text = self.label .. ": " .. stateText

    if #text > self.width - 2 then
        text = text:sub(1, math.max(1, self.width - 2))
    end

    local textX = self.x + math.floor((self.width - #text) / 2)
    local textY = self.y + math.floor((self.height - 1) / 2)

    target.setBackgroundColor(background)
    target.setTextColor(self.textColor)
    target.setCursorPos(textX, textY)
    target.write(text)
end

return Toggle
