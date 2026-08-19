local Pieces = require("chess.pieces")
local Move = require("chess.move")

local Rules = {}

local knightOffsets = {
    {-2, -1}, {-2, 1},
    {-1, -2}, {-1, 2},
    {1, -2}, {1, 2},
    {2, -1}, {2, 1}
}

local kingOffsets = {
    {-1, -1}, {0, -1}, {1, -1},
    {-1, 0},            {1, 0},
    {-1, 1},  {0, 1},  {1, 1}
}

local bishopDirections = {
    {-1, -1}, {1, -1},
    {-1, 1},  {1, 1}
}

local rookDirections = {
    {0, -1},
    {0, 1},
    {-1, 0},
    {1, 0}
}

function Rules.newState()
    return {
        turn = Pieces.WHITE,
        castling = {
            white = {
                kingSide = true,
                queenSide = true
            },
            black = {
                kingSide = true,
                queenSide = true
            }
        },
        enPassant = nil
    }
end

function Rules.cloneState(state)
    local copy = Rules.newState()

    copy.turn = state.turn
    copy.castling.white.kingSide = state.castling.white.kingSide
    copy.castling.white.queenSide = state.castling.white.queenSide
    copy.castling.black.kingSide = state.castling.black.kingSide
    copy.castling.black.queenSide = state.castling.black.queenSide

    if state.enPassant then
        copy.enPassant = {
            x = state.enPassant.x,
            y = state.enPassant.y,
            pawnX = state.enPassant.pawnX,
            pawnY = state.enPassant.pawnY
        }
    end

    return copy
end

local function sign(value)
    if value < 0 then
        return -1
    elseif value > 0 then
        return 1
    end

    return 0
end

local function lineClear(board, fromX, fromY, toX, toY)
    local stepX = sign(toX - fromX)
    local stepY = sign(toY - fromY)
    local x = fromX + stepX
    local y = fromY + stepY

    while x ~= toX or y ~= toY do
        if board:get(x, y) then
            return false
        end

        x = x + stepX
        y = y + stepY
    end

    return true
end

function Rules.isSquareAttacked(board, targetX, targetY, byColor)
    for y = 1, 8 do
        for x = 1, 8 do
            local piece = board:get(x, y)

            if piece and piece.color == byColor then
                local dx = targetX - x
                local dy = targetY - y
                local absX = math.abs(dx)
                local absY = math.abs(dy)

                if piece.kind == "pawn" then
                    local direction = piece.color == Pieces.WHITE and -1 or 1

                    if dy == direction and absX == 1 then
                        return true
                    end

                elseif piece.kind == "knight" then
                    if (absX == 1 and absY == 2) or
                        (absX == 2 and absY == 1)
                    then
                        return true
                    end

                elseif piece.kind == "bishop" then
                    if absX == absY and absX > 0 and
                        lineClear(board, x, y, targetX, targetY)
                    then
                        return true
                    end

                elseif piece.kind == "rook" then
                    if ((dx == 0 and dy ~= 0) or
                        (dy == 0 and dx ~= 0)) and
                        lineClear(board, x, y, targetX, targetY)
                    then
                        return true
                    end

                elseif piece.kind == "queen" then
                    local diagonal = absX == absY and absX > 0
                    local straight =
                        (dx == 0 and dy ~= 0) or
                        (dy == 0 and dx ~= 0)

                    if (diagonal or straight) and
                        lineClear(board, x, y, targetX, targetY)
                    then
                        return true
                    end

                elseif piece.kind == "king" then
                    if math.max(absX, absY) == 1 then
                        return true
                    end
                end
            end
        end
    end

    return false
end

function Rules.findKing(board, color)
    for y = 1, 8 do
        for x = 1, 8 do
            local piece = board:get(x, y)

            if piece and piece.color == color and piece.kind == "king" then
                return x, y
            end
        end
    end

    return nil, nil
end

function Rules.isInCheck(board, color)
    local kingX, kingY = Rules.findKing(board, color)

    if not kingX then
        return true
    end

    return Rules.isSquareAttacked(
        board,
        kingX,
        kingY,
        Pieces.opposite(color)
    )
end

local function addTargetMove(moves, board, piece, fromX, fromY, toX, toY, options)
    if not board:inBounds(toX, toY) then
        return false
    end

    local target = board:get(toX, toY)

    if not target then
        table.insert(moves, Move.new(fromX, fromY, toX, toY, options))
        return true
    end

    if target.color ~= piece.color and target.kind ~= "king" then
        table.insert(moves, Move.new(fromX, fromY, toX, toY, options))
    end

    return false
end

local function addSlidingMoves(moves, board, piece, x, y, directions)
    for _, direction in ipairs(directions) do
        local stepX = direction[1]
        local stepY = direction[2]
        local toX = x + stepX
        local toY = y + stepY

        while board:inBounds(toX, toY) do
            local shouldContinue = addTargetMove(
                moves,
                board,
                piece,
                x,
                y,
                toX,
                toY
            )

            if not shouldContinue then
                break
            end

            toX = toX + stepX
            toY = toY + stepY
        end
    end
end

local function addPawnMove(moves, x, y, toX, toY, promotionRow, options)
    options = options or {}
    options.promotion = toY == promotionRow
    table.insert(moves, Move.new(x, y, toX, toY, options))
end

local function addCastlingMoves(moves, board, piece, x, y, state)
    local homeY = piece.color == Pieces.WHITE and 8 or 1

    if x ~= 5 or y ~= homeY then
        return
    end

    local rights = state.castling[piece.color]

    if not rights then
        return
    end

    local enemy = Pieces.opposite(piece.color)

    if Rules.isSquareAttacked(board, 5, homeY, enemy) then
        return
    end

    if rights.kingSide then
        local rook = board:get(8, homeY)

        if rook and rook.color == piece.color and rook.kind == "rook" and
            not board:get(6, homeY) and
            not board:get(7, homeY) and
            not Rules.isSquareAttacked(board, 6, homeY, enemy) and
            not Rules.isSquareAttacked(board, 7, homeY, enemy)
        then
            table.insert(moves, Move.new(
                5,
                homeY,
                7,
                homeY,
                {
                    special = "castle_king",
                    rookFromX = 8,
                    rookToX = 6
                }
            ))
        end
    end

    if rights.queenSide then
        local rook = board:get(1, homeY)

        if rook and rook.color == piece.color and rook.kind == "rook" and
            not board:get(2, homeY) and
            not board:get(3, homeY) and
            not board:get(4, homeY) and
            not Rules.isSquareAttacked(board, 4, homeY, enemy) and
            not Rules.isSquareAttacked(board, 3, homeY, enemy)
        then
            table.insert(moves, Move.new(
                5,
                homeY,
                3,
                homeY,
                {
                    special = "castle_queen",
                    rookFromX = 1,
                    rookToX = 4
                }
            ))
        end
    end
end

function Rules.generatePseudoMoves(board, x, y, state)
    local piece = board:get(x, y)
    local moves = {}

    if not piece then
        return moves
    end

    if piece.kind == "pawn" then
        local direction = piece.color == Pieces.WHITE and -1 or 1
        local startRow = piece.color == Pieces.WHITE and 7 or 2
        local promotionRow = piece.color == Pieces.WHITE and 1 or 8
        local oneY = y + direction

        if board:inBounds(x, oneY) and not board:get(x, oneY) then
            addPawnMove(moves, x, y, x, oneY, promotionRow)

            local twoY = y + direction * 2

            if y == startRow and not board:get(x, twoY) then
                table.insert(moves, Move.new(x, y, x, twoY))
            end
        end

        for _, dx in ipairs({-1, 1}) do
            local toX = x + dx
            local toY = y + direction

            if board:inBounds(toX, toY) then
                local target = board:get(toX, toY)

                if target and target.color ~= piece.color and target.kind ~= "king" then
                    addPawnMove(moves, x, y, toX, toY, promotionRow)

                elseif state.enPassant and
                    state.enPassant.x == toX and
                    state.enPassant.y == toY
                then
                    local victim = board:get(
                        state.enPassant.pawnX,
                        state.enPassant.pawnY
                    )

                    if victim and
                        victim.kind == "pawn" and
                        victim.color ~= piece.color
                    then
                        addPawnMove(
                            moves,
                            x,
                            y,
                            toX,
                            toY,
                            promotionRow,
                            {
                                special = "en_passant",
                                captureX = state.enPassant.pawnX,
                                captureY = state.enPassant.pawnY
                            }
                        )
                    end
                end
            end
        end

    elseif piece.kind == "knight" then
        for _, offset in ipairs(knightOffsets) do
            addTargetMove(
                moves,
                board,
                piece,
                x,
                y,
                x + offset[1],
                y + offset[2]
            )
        end

    elseif piece.kind == "bishop" then
        addSlidingMoves(moves, board, piece, x, y, bishopDirections)

    elseif piece.kind == "rook" then
        addSlidingMoves(moves, board, piece, x, y, rookDirections)

    elseif piece.kind == "queen" then
        addSlidingMoves(moves, board, piece, x, y, bishopDirections)
        addSlidingMoves(moves, board, piece, x, y, rookDirections)

    elseif piece.kind == "king" then
        for _, offset in ipairs(kingOffsets) do
            addTargetMove(
                moves,
                board,
                piece,
                x,
                y,
                x + offset[1],
                y + offset[2]
            )
        end

        addCastlingMoves(moves, board, piece, x, y, state)
    end

    return moves
end

local function disableRookRight(state, color, x, y)
    local homeY = color == Pieces.WHITE and 8 or 1

    if y ~= homeY then
        return
    end

    if x == 1 then
        state.castling[color].queenSide = false
    elseif x == 8 then
        state.castling[color].kingSide = false
    end
end

function Rules.applyMove(board, move, state, promotionKind)
    local piece = board:get(move.fromX, move.fromY)

    if not piece then
        return false
    end

    local capturedX = move.toX
    local capturedY = move.toY

    if move.special == "en_passant" then
        capturedX = move.captureX
        capturedY = move.captureY
    end

    local captured = board:get(capturedX, capturedY)

    if piece.kind == "king" then
        state.castling[piece.color].kingSide = false
        state.castling[piece.color].queenSide = false

    elseif piece.kind == "rook" then
        disableRookRight(
            state,
            piece.color,
            move.fromX,
            move.fromY
        )
    end

    if captured and captured.kind == "rook" then
        disableRookRight(
            state,
            captured.color,
            capturedX,
            capturedY
        )
    end

    state.enPassant = nil

    board:set(move.fromX, move.fromY, nil)

    if move.special == "en_passant" then
        board:set(move.captureX, move.captureY, nil)
    end

    board:set(move.toX, move.toY, piece)

    if move.special == "castle_king" or move.special == "castle_queen" then
        local rook = board:get(move.rookFromX, move.fromY)
        board:set(move.rookFromX, move.fromY, nil)
        board:set(move.rookToX, move.fromY, rook)
    end

    if move.promotion and piece.kind == "pawn" then
        piece.kind = promotionKind or "queen"
    end

    if piece.kind == "pawn" and math.abs(move.toY - move.fromY) == 2 then
        state.enPassant = {
            x = move.toX,
            y = math.floor((move.toY + move.fromY) / 2),
            pawnX = move.toX,
            pawnY = move.toY
        }
    end

    return true
end

function Rules.generateLegalMoves(board, x, y, state)
    local piece = board:get(x, y)
    local legal = {}

    if not piece then
        return legal
    end

    local pseudo = Rules.generatePseudoMoves(board, x, y, state)

    for _, move in ipairs(pseudo) do
        local boardCopy = board:clone()
        local stateCopy = Rules.cloneState(state)

        Rules.applyMove(boardCopy, move, stateCopy, "queen")

        if not Rules.isInCheck(boardCopy, piece.color) then
            table.insert(legal, move)
        end
    end

    return legal
end

function Rules.hasAnyLegalMove(board, color, state)
    for y = 1, 8 do
        for x = 1, 8 do
            local piece = board:get(x, y)

            if piece and piece.color == color then
                local moves = Rules.generateLegalMoves(board, x, y, state)

                if #moves > 0 then
                    return true
                end
            end
        end
    end

    return false
end

return Rules
