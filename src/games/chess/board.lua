local Pieces = require("chess.pieces")

local Board = {}
Board.__index = Board

local backRank = {
    "rook",
    "knight",
    "bishop",
    "queen",
    "king",
    "bishop",
    "knight",
    "rook"
}

function Board.new()
    local self = setmetatable({}, Board)

    self.width = 8
    self.height = 8
    self.cells = {}

    self:reset()

    return self
end

function Board:clear()
    self.cells = {}

    for y = 1, 8 do
        self.cells[y] = {}

        for x = 1, 8 do
            self.cells[y][x] = nil
        end
    end
end

function Board:reset()
    self:clear()

    for x = 1, 8 do
        self.cells[1][x] = Pieces.new(backRank[x], Pieces.BLACK)
        self.cells[2][x] = Pieces.new("pawn", Pieces.BLACK)
        self.cells[7][x] = Pieces.new("pawn", Pieces.WHITE)
        self.cells[8][x] = Pieces.new(backRank[x], Pieces.WHITE)
    end
end

function Board:inBounds(x, y)
    return x >= 1 and x <= 8 and y >= 1 and y <= 8
end

function Board:get(x, y)
    if not self:inBounds(x, y) then
        return nil
    end

    return self.cells[y][x]
end

function Board:set(x, y, piece)
    if not self:inBounds(x, y) then
        return false
    end

    self.cells[y][x] = piece
    return true
end

function Board:clone()
    local copy = setmetatable({}, Board)

    copy.width = 8
    copy.height = 8
    copy.cells = {}

    for y = 1, 8 do
        copy.cells[y] = {}

        for x = 1, 8 do
            copy.cells[y][x] = Pieces.clone(self.cells[y][x])
        end
    end

    return copy
end

return Board
