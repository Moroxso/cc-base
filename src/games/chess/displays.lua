local MonitorRenderer = require("chess.monitor_renderer")

local Displays = {}
Displays.__index = Displays

Displays.CONFIG_PATH = "/data/chess_displays.json"
Displays.TEXT_SCALE = 0.5

local function ensureDir(path)
    local dir = fs.getDir(path)

    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function readConfig()
    if not fs.exists(Displays.CONFIG_PATH) or fs.isDir(Displays.CONFIG_PATH) then
        return {active = {}}
    end

    local file = fs.open(Displays.CONFIG_PATH, "r")
    if not file then return {active = {}} end

    local raw = file.readAll()
    file.close()

    local ok, value = pcall(textutils.unserializeJSON, raw)

    if not ok or type(value) ~= "table" then
        return {active = {}}
    end

    if type(value.active) ~= "table" then
        value.active = {}
    end

    return value
end

local function writeConfig(value)
    ensureDir(Displays.CONFIG_PATH)
    local ok, raw = pcall(textutils.serializeJSON, value)

    if not ok or type(raw) ~= "string" then
        return false
    end

    local tempPath = Displays.CONFIG_PATH .. ".tmp"
    local file = fs.open(tempPath, "w")

    if not file then
        return false
    end

    file.write(raw)
    file.close()

    if fs.exists(Displays.CONFIG_PATH) then
        fs.delete(Displays.CONFIG_PATH)
    end

    fs.move(tempPath, Displays.CONFIG_PATH)
    return true
end

local function isMonitor(name)
    if type(name) ~= "string" or name == "" then
        return false
    end

    local ok, peripheralType = pcall(peripheral.getType, name)
    return ok and peripheralType == "monitor"
end

local function estimateFormat(width, height)
    local blocksWide = math.max(1, math.floor((width / 29) + 0.5))
    local blocksHigh = math.max(1, math.floor((height / 19) + 0.5))

    if blocksWide > 8 or blocksHigh > 8 then
        return "large"
    end

    return tostring(blocksWide) .. "x" .. tostring(blocksHigh)
end

local function probe(name, leavePrepared)
    if not isMonitor(name) then
        return nil
    end

    local monitor = peripheral.wrap(name)
    if not monitor or type(monitor.getSize) ~= "function" then
        return nil
    end

    local previousScale = nil

    if type(monitor.getTextScale) == "function" then
        local ok, value = pcall(monitor.getTextScale)
        if ok then previousScale = value end
    end

    if type(monitor.setTextScale) == "function" then
        pcall(monitor.setTextScale, Displays.TEXT_SCALE)
    end

    local ok, width, height = pcall(monitor.getSize)

    if not leavePrepared and previousScale and type(monitor.setTextScale) == "function" then
        pcall(monitor.setTextScale, previousScale)
    end

    if not ok then
        return nil
    end

    return {
        name = name,
        width = width,
        height = height,
        format = estimateFormat(width, height),
        monitor = monitor
    }
end

function Displays.new()
    local self = setmetatable({}, Displays)
    local config = readConfig()

    self.active = {}
    self.entries = {}

    for name, enabled in pairs(config.active or {}) do
        if enabled == true then
            self.active[tostring(name)] = true
        end
    end

    self:refresh()
    return self
end

function Displays:save()
    return writeConfig({
        version = 1,
        active = self.active
    })
end

function Displays:refresh()
    local entries = {}

    for _, name in ipairs(peripheral.getNames()) do
        if isMonitor(name) then
            local entry = probe(name, self.active[name] == true)

            if entry then
                entry.active = self.active[name] == true
                table.insert(entries, entry)
            end
        end
    end

    table.sort(entries, function(a, b)
        return a.name < b.name
    end)

    self.entries = entries
    return entries
end

function Displays:getEntries()
    return self.entries
end

function Displays:activeCount()
    local count = 0

    for _, entry in ipairs(self.entries) do
        if self.active[entry.name] == true then
            count = count + 1
        end
    end

    return count
end

function Displays:isActive(name)
    return self.active[name] == true
end

function Displays:setActive(name, enabled)
    name = tostring(name or "")

    if name == "" then
        return false, "invalid_monitor_name"
    end

    local entry = probe(name, enabled == true)

    if not entry then
        return false, "monitor_unavailable"
    end

    if enabled then
        self.active[name] = true
    else
        self.active[name] = nil
        local monitor = entry.monitor
        pcall(function()
            monitor.setBackgroundColor(colors.black)
            monitor.setTextColor(colors.white)
            monitor.clear()
            monitor.setCursorPos(1, 1)
        end)
    end

    self:save()
    self:refresh()
    return true
end

function Displays:toggle(name)
    return self:setActive(name, not self:isActive(name))
end

function Displays:clearSelection()
    local names = {}

    for name in pairs(self.active) do
        table.insert(names, name)
    end

    for _, name in ipairs(names) do
        local entry = probe(name, false)

        if entry then
            pcall(function()
                entry.monitor.setBackgroundColor(colors.black)
                entry.monitor.setTextColor(colors.white)
                entry.monitor.clear()
                entry.monitor.setCursorPos(1, 1)
            end)
        end
    end

    self.active = {}
    self:save()
    self:refresh()
    return true
end

function Displays:render(game, options)
    local rendered = 0
    local failed = 0

    self:refresh()

    for _, entry in ipairs(self.entries) do
        if self.active[entry.name] == true then
            local monitor = peripheral.wrap(entry.name)

            if monitor then
                local ok = pcall(function()
                    if type(monitor.setTextScale) == "function" then
                        monitor.setTextScale(Displays.TEXT_SCALE)
                    end

                    MonitorRenderer.draw(monitor, game, options)
                end)

                if ok then
                    rendered = rendered + 1
                else
                    failed = failed + 1
                end
            else
                failed = failed + 1
            end
        end
    end

    return rendered, failed
end

function Displays:clearOutputs()
    for name in pairs(self.active) do
        local monitor = peripheral.wrap(name)

        if monitor then
            pcall(function()
                monitor.setBackgroundColor(colors.black)
                monitor.setTextColor(colors.white)
                monitor.clear()
                monitor.setCursorPos(1, 1)
            end)
        end
    end
end

return Displays
