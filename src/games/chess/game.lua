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

local pieceCodes = {
    pawn = "p",
    knight = "n",
    bishop = "b",
    rook = "r",
    queen = "q",
    king = "k"
}

local codePieces = {
    p = "pawn",
    n = "knight",
    b = "bishop",
    r = "rook",
    q = "queen",
    k = "king"
}

local function validPromotion(kind)
    for _, candidate in ipairs(promotionKinds) do
        if candidate == kind then
            return true
        end
    end

    return false
end

local function validSquareCoordinate(value)
    return type(value) == "number" and
        value == math.floor(value) and
        value >= 1 and value <= 8
end

local function copyMove(move)
    if type(move) ~= "table" then
        return nil
    end

    return {
        fromX = move.fromX,
        fromY = move.fromY,
        toX = move.toX,
        toY = move.toY,
        promotion = move.promotion == true,
        special = move.special,
        captureX = move.captureX,
        captureY = move.captureY,
        rookFromX = move.rookFromX,
        rookToX = move.rookToX
    }
end

local function encodePiece(piece)
    if not piece then
        return "."
    end

    local color = piece.color == Pieces.WHITE and "w" or "b"
    return color .. tostring(pieceCodes[piece.kind] or "?")
end

local function decodePiece(code)
    if code == "." then
        return nil
    end

    if type(code) ~= "string" or #code ~= 2 then
        return nil, "bad_piece_code"
    end

    local colorCode = code:sub(1, 1)
    local kindCode = code:sub(2, 2)
    local color = colorCode == "w" and Pieces.WHITE or
        (colorCode == "b" and Pieces.BLACK or nil)
    local kind = codePieces[kindCode]

    if not color or not kind then
        return nil, "bad_piece_code"
    end

    return Pieces.new(kind, color)
end

local function hashString(content)
    local hash = 5381

    for index = 1, #content do
        hash = (hash * 33 + string.byte(content, index)) % 4294967296
    end

    return string.format("%08x", hash)
end

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

    self.cursorX = x
    self.cursorY = y
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
    self.cursorX = move.toX
    self.cursorY = move.toY
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
    if not self.promotionPending or not validPromotion(kind) then
        return false
    end

    local move = self.promotionPending
    return self:finishMove(move, kind)
end

function Game:applyMoveCoordinates(fromX, fromY, toX, toY, promotionKind)
    if self.status ~= "playing" or self.promotionPending then
        return false, "game_not_ready"
    end

    if not validSquareCoordinate(fromX) or
        not validSquareCoordinate(fromY) or
        not validSquareCoordinate(toX) or
        not validSquareCoordinate(toY)
    then
        return false, "square_out_of_bounds"
    end

    local piece = self.board:get(fromX, fromY)

    if not piece or piece.color ~= self.state.turn then
        return false, "wrong_turn_or_piece"
    end

    local legalMoves = Rules.generateLegalMoves(
        self.board,
        fromX,
        fromY,
        self.state
    )
    local selectedMove = nil

    for _, move in ipairs(legalMoves) do
        if move.toX == toX and move.toY == toY then
            selectedMove = move
            break
        end
    end

    if not selectedMove then
        return false, "illegal_move"
    end

    if selectedMove.promotion then
        if not validPromotion(promotionKind) then
            return false, "promotion_required"
        end
    else
        promotionKind = nil
    end

    if not self:finishMove(selectedMove, promotionKind) then
        return false, "move_apply_failed"
    end

    return true
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

function Game:clickSquare(x, y)
    if self.promotionPending or self.status ~= "playing" then
        return false
    end

    if not self.board:inBounds(x, y) then
        return false
    end

    self.cursorX = x
    self.cursorY = y

    local piece = self.board:get(x, y)

    if piece and piece.color == self.state.turn then
        return self:selectPiece(x, y)
    end

    if self.selectedX then
        local move = self:findMoveTo(x, y)

        if move then
            return self:attemptMove(move)
        end

        self:clearSelection()
        return true
    end

    return false
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

function Game:exportState()
    local cells = {}

    for y = 1, 8 do
        for x = 1, 8 do
            table.insert(cells, encodePiece(self.board:get(x, y)))
        end
    end

    local state = {
        turn = self.state.turn,
        castling = {
            white = {
                kingSide = self.state.castling.white.kingSide == true,
                queenSide = self.state.castling.white.queenSide == true
            },
            black = {
                kingSide = self.state.castling.black.kingSide == true,
                queenSide = self.state.castling.black.queenSide == true
            }
        },
        enPassant = nil
    }

    if self.state.enPassant then
        state.enPassant = {
            x = self.state.enPassant.x,
            y = self.state.enPassant.y,
            pawnX = self.state.enPassant.pawnX,
            pawnY = self.state.enPassant.pawnY
        }
    end

    return {
        version = 1,
        cells = cells,
        state = state,
        lastMove = copyMove(self.lastMove),
        lastPromotion = self.lastPromotion
    }
end

function Game:importState(snapshot)
    if type(snapshot) ~= "table" or snapshot.version ~= 1 or
        type(snapshot.cells) ~= "table" or #snapshot.cells ~= 64 or
        type(snapshot.state) ~= "table"
    then
        return false, "invalid_snapshot"
    end

    local turn = snapshot.state.turn

    if turn ~= Pieces.WHITE and turn ~= Pieces.BLACK then
        return false, "invalid_snapshot_turn"
    end

    local board = Board.new()
    board:clear()
    local index = 1

    for y = 1, 8 do
        for x = 1, 8 do
            local piece, err = decodePiece(snapshot.cells[index])

            if err then
                return false, err
            end

            board:set(x, y, piece)
            index = index + 1
        end
    end

    local state = Rules.newState()
    state.turn = turn
    local castling = snapshot.state.castling or {}
    local white = castling.white or {}
    local black = castling.black or {}
    state.castling.white.kingSide = white.kingSide == true
    state.castling.white.queenSide = white.queenSide == true
    state.castling.black.kingSide = black.kingSide == true
    state.castling.black.queenSide = black.queenSide == true

    if type(snapshot.state.enPassant) == "table" then
        local ep = snapshot.state.enPassant
        local ex = tonumber(ep.x)
        local ey = tonumber(ep.y)
        local px = tonumber(ep.pawnX)
        local py = tonumber(ep.pawnY)

        if not validSquareCoordinate(ex) or
            not validSquareCoordinate(ey) or
            not validSquareCoordinate(px) or
            not validSquareCoordinate(py)
        then
            return false, "invalid_snapshot_en_passant"
        end

        state.enPassant = {
            x = ex,
            y = ey,
            pawnX = px,
            pawnY = py
        }
    end

    self.board = board
    self.state = state
    self.cursorX = 5
    self.cursorY = turn == Pieces.WHITE and 7 or 2
    self.selectedX = nil
    self.selectedY = nil
    self.legalMoves = {}
    self.lastMove = copyMove(snapshot.lastMove)
    self.lastPromotion = validPromotion(snapshot.lastPromotion) and snapshot.lastPromotion or nil
    self.promotionPending = nil
    self.status = "playing"
    self.winner = nil
    self.inCheck = false
    self:evaluatePosition()

    return true
end

function Game:positionSignature()
    local parts = {}

    for y = 1, 8 do
        for x = 1, 8 do
            table.insert(parts, encodePiece(self.board:get(x, y)))
        end
    end

    table.insert(parts, self.state.turn == Pieces.WHITE and "W" or "B")

    local castling = self.state.castling
    table.insert(parts, castling.white.kingSide and "K" or "-")
    table.insert(parts, castling.white.queenSide and "Q" or "-")
    table.insert(parts, castling.black.kingSide and "k" or "-")
    table.insert(parts, castling.black.queenSide and "q" or "-")

    if self.state.enPassant then
        table.insert(parts, string.format(
            "e%d,%d,%d,%d",
            self.state.enPassant.x,
            self.state.enPassant.y,
            self.state.enPassant.pawnX,
            self.state.enPassant.pawnY
        ))
    else
        table.insert(parts, "e-")
    end

    return hashString(table.concat(parts, "|"))
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
