local Router = {}
Router.__index = Router

function Router.new()
    local self = setmetatable({}, Router)

    self.handlers = {}
    self.fallback = nil

    return self
end

local function key(service, messageType)
    return tostring(service) .. "\0" .. tostring(messageType)
end

function Router:register(service, messageType, handler)
    if type(handler) ~= "function" then
        return false
    end

    self.handlers[key(service, messageType)] = handler
    return true
end

function Router:setFallback(handler)
    if handler ~= nil and type(handler) ~= "function" then
        return false
    end

    self.fallback = handler
    return true
end

function Router:dispatch(sender, packet)
    if type(packet) ~= "table" then
        return false, "invalid_packet"
    end

    local handler = self.handlers[key(packet.service, packet.type)]

    if handler then
        local ok, result = pcall(handler, sender, packet)

        if not ok then
            return false, tostring(result)
        end

        return true, result
    end

    if self.fallback then
        local ok, result = pcall(self.fallback, sender, packet)

        if not ok then
            return false, tostring(result)
        end

        return true, result
    end

    return false, "no_route"
end

return Router
