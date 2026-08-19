local TabBar = {}
TabBar.__index = TabBar

function TabBar.new(options)
    options = options or {}

    local self = setmetatable({}, TabBar)

    self.x = options.x or 1
    self.y = options.y or 1
    self.width = math.max(1, options.width or 20)
    self.tabs = options.tabs or {}
    self.selectedIndex = math.max(1, options.selectedIndex or 1)

    self.backgroundColor = options.backgroundColor or colors.gray
    self.textColor = options.textColor or colors.white
    self.selectedBackgroundColor = options.selectedBackgroundColor or colors.lightBlue
    self.selectedTextColor = options.selectedTextColor or colors.black

    if self.selectedIndex > #self.tabs and #self.tabs > 0 then
        self.selectedIndex = #self.tabs
    end

    return self
end

function TabBar:setSelected(index)
    if #self.tabs == 0 then
        return false
    end

    index = math.max(1, math.min(#self.tabs, index))

    if index == self.selectedIndex then
        return false
    end

    self.selectedIndex = index
    return true
end

function TabBar:getSelected()
    return self.tabs[self.selectedIndex], self.selectedIndex
end

function TabBar:getTabBounds(index)
    if #self.tabs == 0 then
        return nil
    end

    local baseWidth = math.floor(self.width / #self.tabs)
    local remainder = self.width - baseWidth * #self.tabs
    local x = self.x

    for i = 1, #self.tabs do
        local tabWidth = baseWidth

        if i <= remainder then
            tabWidth = tabWidth + 1
        end

        if i == index then
            return x, tabWidth
        end

        x = x + tabWidth
    end

    return nil
end

function TabBar:findAt(x, y)
    if y ~= self.y then
        return nil
    end

    for i = 1, #self.tabs do
        local tabX, tabWidth = self:getTabBounds(i)

        if x >= tabX and x < tabX + tabWidth then
            return i
        end
    end

    return nil
end

function TabBar:handleEvent(event, a, b, c)
    if event == "mouse_click" and a == 1 then
        local index = self:findAt(b, c)

        if index then
            local changed = self:setSelected(index)
            return self.tabs[index], changed
        end

    elseif event == "key" then
        if a == keys.left then
            return self.tabs[self.selectedIndex], self:setSelected(self.selectedIndex - 1)
        elseif a == keys.right then
            return self.tabs[self.selectedIndex], self:setSelected(self.selectedIndex + 1)
        end
    end

    return nil, false
end

function TabBar:draw(target)
    target = target or term

    for i, tab in ipairs(self.tabs) do
        local tabX, tabWidth = self:getTabBounds(i)
        local selected = i == self.selectedIndex
        local background = selected and self.selectedBackgroundColor or self.backgroundColor
        local foreground = selected and self.selectedTextColor or self.textColor
        local label = tostring(tab.label or tab.id or ("Tab " .. i))

        if #label > tabWidth - 2 then
            label = label:sub(1, math.max(1, tabWidth - 2))
        end

        target.setBackgroundColor(background)
        target.setTextColor(foreground)
        target.setCursorPos(tabX, self.y)
        target.write(string.rep(" ", tabWidth))

        local textX = tabX + math.floor((tabWidth - #label) / 2)
        target.setCursorPos(textX, self.y)
        target.write(label)
    end
end

return TabBar
