local Board = require("chess.board")
local Pieces = require("chess.pieces")
local Rules = require("chess.rules")

local Game = {}
Game.__index = Game

local promotionKinds = {
    "queen",
    "rook",
    "bishop",
    "knight"
}

function Game.new()
    local self = setmetatable({}, Game)

    self.board = Board.new()
    self.state = Rules.newState()
    self.cursorX = 5
    self.cursorY = 7
    self.selectedX = nil
    self.selectedY = nil
    self.legalMoves = {}
    self.lastMove = nil
    self.lastPromotion = nil
    self.promotionPending = nil
    self.status = "playing"
    self.winner = nil
    self.inCheck = false

    self:evaluatePosition()

    return self
end

function Game:restart()
    self.board:reset()
    self.state = Rules.newState()
    self.cursorX = 5
    self.cursorY = 7
    self.selectedX = nil
    self.selectedY = nil
    self.legalMoves = {}
    self.lastMove = nil
    self.lastPromotion = nil
    self.promotionPending = nil
    self.status = "playing"
    self.winner = nil
    self.inCheck = false

    self:evaluatePosition()
end

function Game:getTurn()
    return self.state.turn
end

function Game:getPromotionKinds()
    return promotionKinds
end

function Game:clearSelection()
    self.selectedX = nil
    self.selectedY = nil
    self.legalMoves = {}
end

function Game:selectPiece(x, y)
    local piece = self.board:get(x, y)

    if not piece or piece.color ~= self.state.turn then
        return false
    end

    self.selectedX = x
    self.selectedY = y
    self.legalMoves = Rules.generateLegalMoves(
        self.board,
        x,
        y,
        self.state
    )

    return true
end

function Game:findMoveTo(x, y)
    for _, move in ipairs(self.legalMoves) do
        if move.toX == x and move.toY == y then
            return move
        end
    end

    return nil
end

function Game:finishMove(move, promotionKind)
    if not Rules.applyMove(
        self.board,
        move,
        self.state,
        promotionKind
    ) then
        return false
    end

    self.lastMove = move
    self.lastPromotion = promotionKind
    self.promotionPending = nil
    self.state.turn = Pieces.opposite(self.state.turn)
    self:clearSelection()
    self:evaluatePosition()

    return true
end

function Game:attemptMove(move)
    if not move then
        return false
    end

    if move.promotion then
        self.promotionPending = move
        return "promotion"
    end

    return self:finishMove(move)
end

function Game:choosePromotion(kind)
    if not self.promotionPending then
        return false
    end

    local valid = false

    for _, candidate in ipairs(promotionKinds) do
        if candidate == kind then
            valid = true
            break
        end
    end

    if not valid then
        return false
    end

    local move = self.promotionPending
    return self:finishMove(move, kind)
end

function Game:selectSquare(x, y)
    if self.promotionPending or self.status ~= "playing" then
        return false
    end

    if not self.board:inBounds(x, y) then
        return false
    end

    self.cursorX = x
    self.cursorY = y

    if self.selectedX then
        if x == self.selectedX and y == self.selectedY then
            self:clearSelection()
            return true
        end

        local move = self:findMoveTo(x, y)

        if move then
            return self:attemptMove(move)
        end

        local piece = self.board:get(x, y)

        if piece and piece.color == self.state.turn then
            return self:selectPiece(x, y)
        end

        self:clearSelection()
        return true
    end

    return self:selectPiece(x, y)
end

function Game:moveCursor(dx, dy)
    if self.promotionPending then
        return false
    end

    self.cursorX = ((self.cursorX - 1 + dx) % 8) + 1
    self.cursorY = ((self.cursorY - 1 + dy) % 8) + 1
    return true
end

function Game:activateCursor()
    if self.status ~= "playing" then
        self:restart()
        return true
    end

    return self:selectSquare(self.cursorX, self.cursorY)
end

function Game:isLegalDestination(x, y)
    return self:findMoveTo(x, y) ~= nil
end

function Game:evaluatePosition()
    local color = self.state.turn

    self.inCheck = Rules.isInCheck(self.board, color)

    if Rules.hasAnyLegalMove(self.board, color, self.state) then
        self.status = "playing"
        self.winner = nil
        return
    end

    if self.inCheck then
        self.status = "checkmate"
        self.winner = Pieces.opposite(color)
    else
        self.status = "stalemate"
        self.winner = nil
    end
end

return Game
