local Board = {}
Board.__index = Board

function Board.new(width, height)
    local self = setmetatable({}, Board)

    self.width = width or 10
    self.height = height or 16
    self.cells = {}

    self:clear()

    return self
end

function Board:clear()
    self.cells = {}

    for y = 1, self.height do
        self.cells[y] = {}

        for x = 1, self.width do
            self.cells[y][x] = nil
        end
    end
end

function Board:get(x, y)
    if x < 1 or x > self.width or y < 1 or y > self.height then
        return nil
    end

    return self.cells[y][x]
end

function Board:isOccupied(x, y)
    if x < 1 or x > self.width or y > self.height then
        return true
    end

    if y < 1 then
        return false
    end

    return self.cells[y][x] ~= nil
end

function Board:canPlace(cells, originX, originY)
    for _, cell in ipairs(cells) do
        local x = originX + cell[1]
        local y = originY + cell[2]

        if self:isOccupied(x, y) then
            return false
        end
    end

    return true
end

function Board:place(cells, originX, originY, color)
    local aboveTop = false

    for _, cell in ipairs(cells) do
        local x = originX + cell[1]
        local y = originY + cell[2]

        if y < 1 then
            aboveTop = true
        elseif x >= 1 and x <= self.width and y <= self.height then
            self.cells[y][x] = color
        end
    end

    return not aboveTop
end

function Board:isRowFull(y)
    for x = 1, self.width do
        if self.cells[y][x] == nil then
            return false
        end
    end

    return true
end

function Board:clearLines()
    local cleared = 0
    local targetY = self.height

    for sourceY = self.height, 1, -1 do
        if self:isRowFull(sourceY) then
            cleared = cleared + 1
        else
            if targetY ~= sourceY then
                self.cells[targetY] = self.cells[sourceY]
            end

            targetY = targetY - 1
        end
    end

    while targetY >= 1 do
        self.cells[targetY] = {}

        for x = 1, self.width do
            self.cells[targetY][x] = nil
        end

        targetY = targetY - 1
    end

    return cleared
end

return Board
