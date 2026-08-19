local Board = require("tetris.board")
local Pieces = require("tetris.pieces")

local Game = {}
Game.__index = Game

local SCORE_TABLE = {
    [1] = 100,
    [2] = 300,
    [3] = 500,
    [4] = 800
}

function Game.new(width, height)
    local self = setmetatable({}, Game)

    self.board = Board.new(width or 10, height or 16)
    self.score = 0
    self.lines = 0
    self.level = 1
    self.gameOver = false
    self.paused = false
    self.current = nil
    self.bag = {}
    self.nextKind = self:drawKind()

    self:spawnPiece()

    return self
end

function Game:refillBag()
    self.bag = Pieces.createBag()
end

function Game:drawKind()
    if #self.bag == 0 then
        self:refillBag()
    end

    return table.remove(self.bag, 1)
end

function Game:getDropInterval()
    return math.max(0.12, 0.70 - (self.level - 1) * 0.05)
end

function Game:spawnPiece()
    local kind = self.nextKind or self:drawKind()
    self.nextKind = self:drawKind()

    self.current = {
        kind = kind,
        rotation = 1,
        x = math.floor(self.board.width / 2) - 1,
        y = 0
    }

    if not self:canPlaceCurrent() then
        self.gameOver = true
    end
end

function Game:getCurrentCells(rotation)
    if not self.current then
        return {}
    end

    return Pieces.getCells(
        self.current.kind,
        rotation or self.current.rotation
    )
end

function Game:canPlaceCurrent(x, y, rotation)
    if not self.current then
        return false
    end

    return self.board:canPlace(
        self:getCurrentCells(rotation),
        x or self.current.x,
        y or self.current.y
    )
end

function Game:getGhostY()
    if not self.current or self.gameOver then
        return nil
    end

    local ghostY = self.current.y

    while self:canPlaceCurrent(
        self.current.x,
        ghostY + 1,
        self.current.rotation
    ) do
        ghostY = ghostY + 1
    end

    return ghostY
end

function Game:move(dx, dy)
    if self.gameOver or self.paused or not self.current then
        return false
    end

    local nextX = self.current.x + dx
    local nextY = self.current.y + dy

    if self:canPlaceCurrent(nextX, nextY) then
        self.current.x = nextX
        self.current.y = nextY
        return true
    end

    return false
end

function Game:rotate()
    if self.gameOver or self.paused or not self.current then
        return false
    end

    local nextRotation = self.current.rotation % 4 + 1
    local kicks = {0, -1, 1, -2, 2}

    for _, offset in ipairs(kicks) do
        local nextX = self.current.x + offset

        if self:canPlaceCurrent(nextX, self.current.y, nextRotation) then
            self.current.x = nextX
            self.current.rotation = nextRotation
            return true
        end
    end

    return false
end

function Game:lockPiece()
    if not self.current then
        return
    end

    local color = Pieces.getColor(self.current.kind)
    local placed = self.board:place(
        self:getCurrentCells(),
        self.current.x,
        self.current.y,
        color
    )

    if not placed then
        self.gameOver = true
        return
    end

    local cleared = self.board:clearLines()

    if cleared > 0 then
        self.lines = self.lines + cleared
        self.level = math.floor(self.lines / 10) + 1
        self.score = self.score + (SCORE_TABLE[cleared] or 0) * self.level
    end

    self:spawnPiece()
end

function Game:stepDown()
    if self.gameOver or self.paused then
        return false
    end

    if self:move(0, 1) then
        return true
    end

    self:lockPiece()
    return false
end

function Game:softDrop()
    if self:move(0, 1) then
        self.score = self.score + 1
        return true
    end

    self:lockPiece()
    return false
end

function Game:hardDrop()
    if self.gameOver or self.paused then
        return 0
    end

    local distance = 0

    while self:move(0, 1) do
        distance = distance + 1
    end

    self.score = self.score + distance * 2
    self:lockPiece()

    return distance
end

function Game:togglePause()
    if self.gameOver then
        return false
    end

    self.paused = not self.paused
    return true
end

function Game:restart()
    self.board:clear()
    self.score = 0
    self.lines = 0
    self.level = 1
    self.gameOver = false
    self.paused = false
    self.current = nil
    self.bag = {}
    self.nextKind = self:drawKind()
    self:spawnPiece()
end

return Game
