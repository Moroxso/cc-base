local Move = {}

local files = {
    "a",
    "b",
    "c",
    "d",
    "e",
    "f",
    "g",
    "h"
}

function Move.new(fromX, fromY, toX, toY, options)
    options = options or {}

    return {
        fromX = fromX,
        fromY = fromY,
        toX = toX,
        toY = toY,
        promotion = options.promotion == true,
        special = options.special,
        captureX = options.captureX,
        captureY = options.captureY,
        rookFromX = options.rookFromX,
        rookToX = options.rookToX
    }
end

function Move.squareName(x, y)
    if x < 1 or x > 8 or y < 1 or y > 8 then
        return "??"
    end

    return files[x] .. tostring(9 - y)
end

function Move.toText(move)
    if not move then
        return "-"
    end

    if move.special == "castle_king" then
        return "O-O"
    elseif move.special == "castle_queen" then
        return "O-O-O"
    end

    local text = Move.squareName(move.fromX, move.fromY) ..
        "-" .. Move.squareName(move.toX, move.toY)

    if move.promotion then
        text = text .. "=?"
    end

    return text
end

return Move
