local KeyRepeat = {}
KeyRepeat.__index = KeyRepeat

local function toSet(values)
    local result = {}

    if type(values) == "table" then
        for _, value in ipairs(values) do
            result[value] = true
        end
    end

    return result
end

function KeyRepeat.new(options)
    options = options or {}

    local self = setmetatable({}, KeyRepeat)

    self.allowed = toSet(options.keys or {})
    self.initialDelay = options.initialDelay or 0.35
    self.repeatDelay = options.repeatDelay or 0.08
    self.activeKey = nil
    self.timerId = nil

    return self
end

function KeyRepeat:isAllowed(key)
    return self.allowed[key] == true
end

function KeyRepeat:cancel()
    self.activeKey = nil
    self.timerId = nil
end

function KeyRepeat:start(key)
    if not self:isAllowed(key) then
        return false
    end

    if self.activeKey == key then
        return true
    end

    self.activeKey = key
    self.timerId = os.startTimer(self.initialDelay)

    return true
end

function KeyRepeat:release(key)
    if self.activeKey == key then
        self:cancel()
        return true
    end

    return false
end

function KeyRepeat:handleEvent(event, a)
    if event == "key" then
        local key = a

        if self:isAllowed(key) then
            self:start(key)
        elseif self.activeKey then
            self:cancel()
        end

    elseif event == "key_up" then
        self:release(a)

    elseif event == "timer" then
        if self.activeKey and a == self.timerId then
            local key = self.activeKey
            self.timerId = os.startTimer(self.repeatDelay)
            return key
        end

    elseif event == "mouse_click" or event == "mouse_drag" then
        if self.activeKey then
            self:cancel()
        end
    end

    return nil
end

return KeyRepeat
