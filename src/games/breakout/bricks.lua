local Bricks = {}
Bricks.__index = Bricks

local DEFAULT_COLORS = {
    colors.red,
    colors.orange,
    colors.yellow,
    colors.lime
}

function Bricks.new(fieldWidth, fieldHeight, brickWidth)
    local self = setmetatable({}, Bricks)

    self.fieldWidth = fieldWidth
    self.fieldHeight = fieldHeight
    self.brickWidth = brickWidth or 4
    self.rows = math.max(
        1,
        math.min(4, fieldHeight - 8)
    )
    self.colors = DEFAULT_COLORS
    self.items = {}
    self.count = 0

    self:reset()

    return self
end

function Bricks:reset()
    self.items = {}
    self.count = 0

    local startY = 3

    for row = 1, self.rows do
        local y = startY + row - 1
        local x = 2

        while x + self.brickWidth - 1 < self.fieldWidth do
            table.insert(
                self.items,
                {
                    x = x,
                    y = y,
                    width = self.brickWidth - 1,
                    alive = true,
                    color = self.colors[
                        ((row - 1) % #self.colors) + 1
                    ]
                }
            )

            self.count = self.count + 1
            x = x + self.brickWidth
        end
    end
end

function Bricks:getAt(x, y)
    for _, brick in ipairs(self.items) do
        if brick.alive
            and y == brick.y
            and x >= brick.x
            and x < brick.x + brick.width
        then
            return brick
        end
    end

    return nil
end

function Bricks:hitAt(x, y)
    local brick = self:getAt(x, y)

    if not brick then
        return false
    end

    brick.alive = false
    self.count = self.count - 1

    return true
end

function Bricks:isEmpty()
    return self.count <= 0
end

return Bricks
