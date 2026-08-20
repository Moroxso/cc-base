local Button = require("lib.gui.button")

local DisplayMenu = {}
DisplayMenu.__index = DisplayMenu

local function resetColors(target)
    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
end

local function writeLine(target, x, y, text, color, width)
    local targetWidth = target.getSize()
    width = width or (targetWidth - x + 1)
    text = tostring(text or ""):sub(1, math.max(0, width))

    target.setBackgroundColor(colors.black)
    target.setTextColor(color or colors.white)
    target.setCursorPos(x, y)
    target.write(text .. string.rep(" ", math.max(0, width - #text)))
    resetColors(target)
end

local function makeButton(id, label, x, y, width, background, foreground)
    return Button.new({
        id = id,
        label = label,
        x = x,
        y = y,
        width = width,
        height = 1,
        backgroundColor = background,
        textColor = foreground or colors.white
    })
end

function DisplayMenu.new(target, manager)
    local self = setmetatable({}, DisplayMenu)

    self.target = target or term
    self.manager = manager
    self.visible = false
    self.selected = 1
    self.top = 1
    self.message = "ENTER/click toggles a monitor for spectator output."
    self.refreshButton = makeButton("refresh", "Refresh", 2, 14, 12, colors.blue)
    self.clearButton = makeButton("clear", "Disable All", 15, 14, 14, colors.orange, colors.black)
    self.backButton = makeButton("back", "Back", 30, 14, 20, colors.red)

    return self
end

function DisplayMenu:open()
    self.visible = true
    self.manager:refresh()
    local entries = self.manager:getEntries()

    if #entries == 0 then
        self.selected = 1
        self.top = 1
        self.message = "No monitor peripherals detected."
    else
        self.selected = math.max(1, math.min(self.selected, #entries))
        self.message = "Select one or several monitors. Active selection is persistent."
    end
end

function DisplayMenu:close()
    self.visible = false
end

function DisplayMenu:isOpen()
    return self.visible == true
end

function DisplayMenu:refresh()
    self.manager:refresh()
    local entries = self.manager:getEntries()

    if #entries == 0 then
        self.selected = 1
        self.top = 1
    else
        self.selected = math.max(1, math.min(self.selected, #entries))
    end
end

function DisplayMenu:keepVisible()
    local entries = self.manager:getEntries()
    local visibleRows = 7

    if #entries == 0 then
        self.top = 1
        return
    end

    if self.selected < self.top then
        self.top = self.selected
    elseif self.selected > self.top + visibleRows - 1 then
        self.top = self.selected - visibleRows + 1
    end

    self.top = math.max(1, math.min(self.top, math.max(1, #entries - visibleRows + 1)))
end

function DisplayMenu:moveSelection(delta)
    local entries = self.manager:getEntries()

    if #entries == 0 then
        return false
    end

    self.selected = self.selected + delta

    if self.selected < 1 then
        self.selected = #entries
    elseif self.selected > #entries then
        self.selected = 1
    end

    self:keepVisible()
    return true
end

function DisplayMenu:toggleSelected()
    local entries = self.manager:getEntries()
    local entry = entries[self.selected]

    if not entry then
        self.message = "No monitor selected."
        return false
    end

    local ok, err = self.manager:toggle(entry.name)

    if ok then
        self.message = self.manager:isActive(entry.name) and
            ("Added " .. entry.name .. " to spectator output.") or
            ("Removed " .. entry.name .. " from spectator output.")
    else
        self.message = "Monitor toggle failed: " .. tostring(err)
    end

    self:refresh()
    return ok
end

function DisplayMenu:draw()
    local target = self.target
    local width, height = target.getSize()

    resetColors(target)
    target.clear()

    target.setBackgroundColor(colors.purple)
    target.setTextColor(colors.white)

    for y = 1, 3 do
        target.setCursorPos(1, y)
        target.write(string.rep(" ", width))
    end

    local title = "CHESS SPECTATOR DISPLAYS"
    target.setCursorPos(math.max(1, math.floor((width - #title) / 2) + 1), 2)
    target.write(title:sub(1, width))
    resetColors(target)

    local entries = self.manager:getEntries()
    writeLine(
        target,
        2,
        4,
        "DETECTED: " .. tostring(#entries) .. "   ACTIVE: " .. tostring(self.manager:activeCount()),
        colors.cyan,
        width - 2
    )

    self:keepVisible()

    for row = 1, 7 do
        local index = self.top + row - 1
        local entry = entries[index]
        local y = 4 + row

        target.setCursorPos(2, y)

        if entry then
            local active = self.manager:isActive(entry.name)
            local label = string.format(
                "[%s] %-13s %-5s %dx%d",
                active and "X" or " ",
                entry.name:sub(1, 13),
                tostring(entry.format or "auto"):sub(1, 5),
                tonumber(entry.width) or 0,
                tonumber(entry.height) or 0
            )
            label = label:sub(1, width - 3)

            if index == self.selected then
                target.setBackgroundColor(colors.lightBlue)
                target.setTextColor(colors.black)
            else
                target.setBackgroundColor(colors.black)
                target.setTextColor(active and colors.lime or colors.white)
            end

            target.write(label .. string.rep(" ", math.max(0, width - 3 - #label)))
            resetColors(target)
        else
            writeLine(target, 2, y, "", colors.white, width - 3)
        end
    end

    self.refreshButton:draw(target)
    self.clearButton:setEnabled(self.manager:activeCount() > 0)
    self.clearButton:draw(target)
    self.backButton:draw(target)

    writeLine(target, 2, 16, "AUTO layout targets 1x1, 5x4, 2x4, 4x2 and other sizes.", colors.yellow, width - 2)
    writeLine(target, 2, 17, self.message, colors.gray, width - 2)

    target.setBackgroundColor(colors.gray)
    target.setTextColor(colors.white)
    target.setCursorPos(1, height)
    target.write(string.rep(" ", width))
    local footer = "UP/DOWN select  ENTER toggle  CTRL refresh  SHIFT back"
    target.setCursorPos(math.max(1, math.floor((width - #footer) / 2) + 1), height)
    target.write(footer:sub(1, width))
    resetColors(target)
end

function DisplayMenu:rowAt(x, y)
    local width = self.target.getSize()

    if x < 2 or x > width - 1 or y < 5 or y > 11 then
        return nil
    end

    local index = self.top + (y - 5)
    local entries = self.manager:getEntries()

    if index < 1 or index > #entries then
        return nil
    end

    return index
end

function DisplayMenu:handleEvent(event, a, b, c)
    if not self.visible then
        return false, false
    end

    local changed = false
    local closed = false

    if event == "mouse_click" and (a == 1 or a == 0) then
        local index = self:rowAt(b, c)

        if index then
            self.selected = index
            changed = self:toggleSelected() or true
        elseif self.refreshButton:contains(b, c) then
            self:refresh()
            self.message = "Monitor list refreshed."
            changed = true
        elseif self.clearButton:contains(b, c) and self.clearButton.enabled then
            self.manager:clearSelection()
            self:refresh()
            self.message = "All spectator outputs disabled."
            changed = true
        elseif self.backButton:contains(b, c) then
            self:close()
            closed = true
            changed = true
        end

    elseif event == "key" then
        if a == keys.up then
            changed = self:moveSelection(-1)
        elseif a == keys.down then
            changed = self:moveSelection(1)
        elseif a == keys.enter then
            changed = self:toggleSelected() or true
        elseif a == keys.leftCtrl then
            self:refresh()
            self.message = "Monitor list refreshed."
            changed = true
        elseif a == keys.leftShift then
            self:close()
            closed = true
            changed = true
        end

    elseif event == "peripheral" or event == "peripheral_detach" then
        self:refresh()
        self.message = "Monitor topology changed; list refreshed."
        changed = true
    end

    return changed, closed
end

return DisplayMenu
