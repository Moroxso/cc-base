local Paddle = {}
Paddle.__index = Paddle

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end

    if value > maxValue then
        return maxValue
    end

    return value
end

function Paddle.new(x, y, width, fieldWidth)
    local self = setmetatable({}, Paddle)

    self.x = x
    self.y = y
    self.width = width
    self.minX = 2
    self.maxX = fieldWidth - width

    return self
end

function Paddle:move(amount)
    self.x = clamp(
        self.x + amount,
        self.minX,
        self.maxX
    )
end

function Paddle:contains(x)
    return x >= self.x
        and x < self.x + self.width
end

function Paddle:center()
    return self.x + self.width / 2
end

return Paddle
