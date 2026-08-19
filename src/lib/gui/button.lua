local Button = {}
Button.__index = Button

local function fill(target, x, y, width, height, background)
    target.setBackgroundColor(background)

    local line = string.rep(" ", width)

    for row = y, y + height - 1 do
        target.setCursorPos(x, row)
        target.write(line)
    end
end

function Button.new(options)
    options = options or {}

    local self = setmetatable({}, Button)

    self.id = options.id
    self.label = tostring(options.label or "Button")
    self.x = options.x or 1
    self.y = options.y or 1
    self.width = math.max(1, options.width or (#self.label + 4))
    self.height = math.max(1, options.height or 1)
    self.enabled = options.enabled ~= false
    self.selected = options.selected == true

    self.backgroundColor = options.backgroundColor or colors.gray
    self.textColor = options.textColor or colors.white
    self.selectedBackgroundColor = options.selectedBackgroundColor or colors.lightBlue
    self.selectedTextColor = options.selectedTextColor or colors.black
    self.disabledBackgroundColor = options.disabledBackgroundColor or colors.black
    self.disabledTextColor = options.disabledTextColor or colors.gray

    return self
end

function Button:setSelected(value)
    self.selected = value == true
end

function Button:setEnabled(value)
    self.enabled = value == true
end

function Button:contains(x, y)
    return
        x >= self.x and
        x < self.x + self.width and
        y >= self.y and
        y < self.y + self.height
end

function Button:draw(target)
    target = target or term

    local background
    local foreground

    if not self.enabled then
        background = self.disabledBackgroundColor
        foreground = self.disabledTextColor
    elseif self.selected then
        background = self.selectedBackgroundColor
        foreground = self.selectedTextColor
    else
        background = self.backgroundColor
        foreground = self.textColor
    end

    fill(
        target,
        self.x,
        self.y,
        self.width,
        self.height,
        background
    )

    local label = self.label

    if #label > self.width - 2 then
        label = label:sub(1, math.max(1, self.width - 2))
    end

    local textX = self.x + math.floor((self.width - #label) / 2)
    local textY = self.y + math.floor((self.height - 1) / 2)

    target.setBackgroundColor(background)
    target.setTextColor(foreground)
    target.setCursorPos(textX, textY)
    target.write(label)
end

return Button
