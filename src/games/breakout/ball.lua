local Ball = {}
Ball.__index = Ball

function Ball.new(x, y, dx, dy)
    local self = setmetatable({}, Ball)

    self.x = x
    self.y = y
    self.dx = dx or 1
    self.dy = dy or -1

    return self
end

function Ball:reset(x, y, dx, dy)
    self.x = x
    self.y = y
    self.dx = dx or 1
    self.dy = dy or -1
end

function Ball:nextPosition()
    return self.x + self.dx, self.y + self.dy
end

function Ball:setPosition(x, y)
    self.x = x
    self.y = y
end

function Ball:bounceX()
    self.dx = -self.dx
end

function Ball:bounceY()
    self.dy = -self.dy
end

function Ball:setDX(value)
    self.dx = value
end

function Ball:setDY(value)
    self.dy = value
end

return Ball
