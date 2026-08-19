local Pieces = {}

Pieces.WHITE = "white"
Pieces.BLACK = "black"

local symbols = {
    pawn = "P",
    knight = "N",
    bishop = "B",
    rook = "R",
    queen = "Q",
    king = "K"
}

function Pieces.new(kind, color)
    return {
        kind = kind,
        color = color
    }
end

function Pieces.clone(piece)
    if not piece then
        return nil
    end

    return {
        kind = piece.kind,
        color = piece.color
    }
end

function Pieces.opposite(color)
    if color == Pieces.WHITE then
        return Pieces.BLACK
    end

    return Pieces.WHITE
end

function Pieces.symbol(piece)
    if not piece then
        return " "
    end

    local symbol = symbols[piece.kind] or "?"

    if piece.color == Pieces.BLACK then
        return symbol:lower()
    end

    return symbol
end

function Pieces.name(piece)
    if not piece then
        return "Empty"
    end

    return piece.color .. " " .. piece.kind
end

return Pieces
