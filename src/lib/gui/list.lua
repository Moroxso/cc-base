local List = {}
List.__index = List

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    elseif value > maxValue then
        return maxValue
    end

    return value
end

function List.new(options)
    options = options or {}

    local self = setmetatable({}, List)

    self.x = options.x or 1
    self.y = options.y or 1
    self.width = math.max(4, options.width or 20)
    self.height = math.max(1, options.height or 6)
    self.items = options.items or {}
    self.selectedIndex = 1
    self.scrollOffset = 0
    self.getLabel = options.getLabel

    self.backgroundColor = options.backgroundColor or colors.black
    self.textColor = options.textColor or colors.white
    self.selectedBackgroundColor = options.selectedBackgroundColor or colors.lightBlue
    self.selectedTextColor = options.selectedTextColor or colors.black
    self.emptyTextColor = options.emptyTextColor or colors.gray

    if #self.items == 0 then
        self.selectedIndex = 0
    end

    return self
end

function List:setItems(items)
    self.items = items or {}

    if #self.items == 0 then
        self.selectedIndex = 0
        self.scrollOffset = 0
    else
        if self.selectedIndex < 1 then
            self.selectedIndex = 1
        end

        self.selectedIndex = math.min(self.selectedIndex, #self.items)
        self:ensureVisible()
    end
end

function List:getSelectedIndex()
    return self.selectedIndex
end

function List:getSelectedItem()
    if self.selectedIndex < 1 then
        return nil
    end

    return self.items[self.selectedIndex]
end

function List:ensureVisible()
    if self.selectedIndex < 1 then
        self.scrollOffset = 0
        return
    end

    if self.selectedIndex <= self.scrollOffset then
        self.scrollOffset = self.selectedIndex - 1
    elseif self.selectedIndex > self.scrollOffset + self.height then
        self.scrollOffset = self.selectedIndex - self.height
    end

    local maxOffset = math.max(0, #self.items - self.height)
    self.scrollOffset = clamp(self.scrollOffset, 0, maxOffset)
end

function List:setSelected(index)
    if #self.items == 0 then
        self.selectedIndex = 0
        return false
    end

    index = clamp(index, 1, #self.items)
    local changed = index ~= self.selectedIndex
    self.selectedIndex = index
    self:ensureVisible()

    return changed
end

function List:move(delta)
    if #self.items == 0 then
        return false
    end

    local index = self.selectedIndex + delta

    if index < 1 then
        index = #self.items
    elseif index > #self.items then
        index = 1
    end

    return self:setSelected(index)
end

function List:findAt(x, y)
    if x < self.x or x >= self.x + self.width then
        return nil
    end

    if y < self.y or y >= self.y + self.height then
        return nil
    end

    local row = y - self.y
    local index = self.scrollOffset + row + 1

    if index > #self.items then
        return nil
    end

    return index
end

function List:handleEvent(event, a, b, c)
    if event == "mouse_click" and a == 1 then
        local index = self:findAt(b, c)

        if index then
            local changed = self:setSelected(index)
            return index, changed
        end

    elseif event == "key" then
        if a == keys.up then
            return self.selectedIndex, self:move(-1)
        elseif a == keys.down then
            return self.selectedIndex, self:move(1)
        end
    end

    return nil, false
end

function List:labelFor(item, index)
    if self.getLabel then
        return tostring(self.getLabel(item, index) or "")
    end

    if type(item) == "table" then
        return tostring(item.label or item.name or ("Item " .. index))
    end

    return tostring(item)
end

function List:draw(target)
    target = target or term

    for row = 0, self.height - 1 do
        local index = self.scrollOffset + row + 1
        local y = self.y + row
        local selected = index == self.selectedIndex
        local background = selected and self.selectedBackgroundColor or self.backgroundColor
        local foreground = selected and self.selectedTextColor or self.textColor

        target.setBackgroundColor(background)
        target.setTextColor(foreground)
        target.setCursorPos(self.x, y)
        target.write(string.rep(" ", self.width))

        if index <= #self.items then
            local label = self:labelFor(self.items[index], index)

            if #label > self.width - 2 then
                label = label:sub(1, math.max(1, self.width - 5)) .. "..."
            end

            target.setCursorPos(self.x + 1, y)
            target.write(label)
        end
    end

    if #self.items == 0 then
        local text = "No items"

        if #text > self.width - 2 then
            text = text:sub(1, math.max(1, self.width - 2))
        end

        target.setBackgroundColor(self.backgroundColor)
        target.setTextColor(self.emptyTextColor)
        target.setCursorPos(self.x + 1, self.y)
        target.write(text)
    end
end

return List
