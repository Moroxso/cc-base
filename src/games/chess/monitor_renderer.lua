local Pieces = require("chess.pieces")
local Move = require("chess.move")

local MonitorRenderer = {}

local files = {"a", "b", "c", "d", "e", "f", "g", "h"}

-- Do not scale terminal sprites by repeating characters. On large monitors
-- that turns one ASCII stroke into 2-4 identical strokes and visually
-- duplicates the piece. Instead choose a hand-drawn glyph for the cell size.
local compactSprites = {
    pawn = {" o ", " ^ "},
    knight = {"/> ", "/_ "},
    bishop = {"/\\ ", "<> "},
    rook = {"[#]", "|_|"},
    queen = {"*^*", "\\_/"},
    king = {" + ", "/_\\"}
}

local mediumSprites = {
    pawn = {
        "  (o)  ",
        "   |   ",
        "  /|\\  ",
        " /___\\ "
    },
    knight = {
        "  /^>  ",
        " /  )_ ",
        "|    / ",
        " \\__/  "
    },
    bishop = {
        "  /\\   ",
        " <  >  ",
        "  ||   ",
        " _||_  "
    },
    rook = {
        "_|_|_|_",
        "|_____|"," 
        " |   | ",
        "_|___|_"
    },
    queen = {
        "* ^ ^ *",
        " \\___/ ",
        "  | |  ",
        " _|_|_ "
    },
    king = {
        "   +   ",
        "  /|\\  ",
        "  \\|/  ",
        " _/ \\_ "
    }
}

local largeSprites = {
    pawn = {
        "   (o)   ",
        "  /   \\  ",
        "  \\___/  ",
        "    |    ",
        "   /|\\   ",
        "  /___\\  "
    },
    knight = {
        "   /^>   ",
        "  /  )__ ",
        " /      |",
        "|     __/",
        " \\___/   ",
        "  /___\\  "
    },
    bishop = {
        "    /\\   ",
        "   /  \\  ",
        "  < () > ",
        "    ||   ",
        "   /  \\  ",
        " _/___\\_ "
    },
    rook = {
        " _|_|_|_ ",
        " |_____| ",
        "  |   |  ",
        "  |   |  ",
        " _|   |_ ",
        "|_______|"
    },
    queen = {
        "*  ^ ^  *",
        " \\     / ",
        "  \\___/  ",
        "   | |   ",
        "  /   \\  ",
        "_/_____\\_"
    },
    king = {
        "    +    ",
        "   +++   ",
        "   /|\\   ",
        "   \\|/   ",
        "  /   \\  ",
        "_/_____\\_"
    }
}

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function write(target, x, y, text, foreground, background, maxWidth)
    local width, height = target.getSize()

    if y < 1 or y > height or x > width then
        return
    end

    x = math.max(1, x)
    text = tostring(text or "")

    if maxWidth then
        text = text:sub(1, math.max(0, maxWidth))
    elseif x + #text - 1 > width then
        text = text:sub(1, math.max(0, width - x + 1))
    end

    target.setBackgroundColor(background or colors.black)
    target.setTextColor(foreground or colors.white)
    target.setCursorPos(x, y)
    target.write(text)
end

local function fill(target, x, y, width, height, background)
    local targetWidth, targetHeight = target.getSize()
    local left = clamp(x, 1, targetWidth)
    local top = clamp(y, 1, targetHeight)
    local right = clamp(x + width - 1, 1, targetWidth)
    local bottom = clamp(y + height - 1, 1, targetHeight)

    target.setBackgroundColor(background)

    for row = top, bottom do
        target.setCursorPos(left, row)
        target.write(string.rep(" ", math.max(0, right - left + 1)))
    end
end

local function centered(target, y, text, foreground, background, left, width)
    local targetWidth = target.getSize()
    left = left or 1
    width = width or targetWidth
    text = tostring(text or "")
    local x = left + math.max(0, math.floor((width - #text) / 2))
    write(target, x, y, text, foreground, background, width)
end

local function squareBackground(game, x, y)
    local background = ((x + y) % 2 == 0) and colors.lightGray or colors.gray

    if game.lastMove and
        ((game.lastMove.fromX == x and game.lastMove.fromY == y) or
         (game.lastMove.toX == x and game.lastMove.toY == y))
    then
        background = colors.blue
    end

    return background
end

local function maxRowWidth(rows)
    local width = 0

    for _, text in ipairs(rows or {}) do
        width = math.max(width, #text)
    end

    return width
end

local function drawRows(target, rows, x, y, cellWidth, cellHeight, foreground, background)
    local spriteWidth = maxRowWidth(rows)
    local spriteHeight = #rows
    local px = x + math.max(0, math.floor((cellWidth - spriteWidth) / 2))
    local py = y + math.max(0, math.floor((cellHeight - spriteHeight) / 2))

    for row, text in ipairs(rows) do
        if row <= cellHeight and py + row - 1 < y + cellHeight then
            write(target, px, py + row - 1, text, foreground, background, cellWidth)
        end
    end
end

local function chooseSprite(piece, cellWidth, cellHeight)
    local kind = piece.kind

    if cellWidth >= 9 and cellHeight >= 6 and largeSprites[kind] then
        return largeSprites[kind]
    end

    if cellWidth >= 7 and cellHeight >= 4 and mediumSprites[kind] then
        return mediumSprites[kind]
    end

    if cellWidth >= 4 and cellHeight >= 2 then
        return Pieces.sprite(piece)
    end

    if cellWidth >= 3 and cellHeight >= 2 and compactSprites[kind] then
        return compactSprites[kind]
    end

    return nil
end

local function drawPiece(target, piece, x, y, cellWidth, cellHeight, background)
    local foreground = piece.color == Pieces.WHITE and colors.white or colors.black
    local sprite = chooseSprite(piece, cellWidth, cellHeight)

    if sprite then
        drawRows(target, sprite, x, y, cellWidth, cellHeight, foreground, background)
        return
    end

    local symbol = Pieces.symbol(piece):upper()
    local px = x + math.floor((cellWidth - 1) / 2)
    local py = y + math.floor((cellHeight - 1) / 2)
    write(target, px, py, symbol, foreground, background)
end

local function statusText(game)
    if game.status == "checkmate" then
        return "CHECKMATE " .. tostring(game.winner or "?"):upper() .. " WINS"
    elseif game.status == "stalemate" then
        return "STALEMATE"
    elseif game.inCheck then
        return "CHECK"
    end

    return "PLAY"
end

local function drawStatusPanel(target, x, y, width, game, options)
    local turn = tostring(game:getTurn() or "?"):upper()
    local last = Move.toText(game.lastMove)

    if game.lastPromotion then
        last = last:gsub("=%?", "=" .. game.lastPromotion:sub(1, 1):upper())
    end

    write(target, x, y, "TOURNAMENT DISPLAY", colors.yellow, colors.black, width)
    write(target, x, y + 2, "TURN: " .. turn, colors.cyan, colors.black, width)
    write(target, x, y + 3, "STATUS: " .. statusText(game), game.inCheck and colors.red or colors.lime, colors.black, width)
    write(target, x, y + 5, "LAST: " .. last, colors.lightGray, colors.black, width)

    if options.mode == "NETWORK" then
        write(target, x, y + 7, "MODE: NETWORK", colors.cyan, colors.black, width)
        write(target, x, y + 8, "NET: " .. tostring(options.networkState or "ONLINE"):upper(), options.networkState == "DISCONNECTED" and colors.red or colors.lime, colors.black, width)
        write(target, x, y + 9, "MOVE: #" .. tostring(options.moveNo or 0), colors.lightGray, colors.black, width)
    else
        write(target, x, y + 7, "MODE: LOCAL", colors.cyan, colors.black, width)
    end
end

function MonitorRenderer.draw(target, game, options)
    options = type(options) == "table" and options or {}
    local width, height = target.getSize()

    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    target.clear()

    if width < 18 or height < 12 then
        centered(target, math.max(1, math.floor(height / 2)), "CHESS DISPLAY TOO SMALL", colors.red)
        return false, "monitor_too_small"
    end

    local ratio = width / math.max(1, height)
    local wide = width >= 70 and height >= 25 and ratio >= 1.45
    local panelWidth = wide and clamp(math.floor(width * 0.24), 22, 32) or 0
    local boardRegionWidth = wide and (width - panelWidth - 2) or width
    local reserveBottom = (not wide and height >= 30) and math.min(9, math.floor(height * 0.14)) or 0
    local cellHeight = math.floor((height - 3 - reserveBottom) / 8)
    cellHeight = math.max(1, cellHeight)
    local cellWidth = math.floor((boardRegionWidth - 2) / 8)
    cellWidth = math.max(2, math.min(cellWidth, cellHeight * 2))

    local boardWidth = cellWidth * 8
    local boardHeight = cellHeight * 8
    local boardX = math.max(2, math.floor((boardRegionWidth - boardWidth) / 2) + 1)
    local boardY = 3
    local title = tostring(options.title or "CHESS TOURNAMENT")

    fill(target, 1, 1, width, 1, colors.purple)
    centered(target, 1, title, colors.white, colors.purple)

    for column = 1, 8 do
        local x = boardX + (column - 1) * cellWidth
        centered(target, 2, files[column], colors.lightGray, colors.black, x, cellWidth)
    end

    for row = 1, 8 do
        local y = boardY + (row - 1) * cellHeight
        write(target, math.max(1, boardX - 1), y, tostring(9 - row), colors.lightGray)

        for column = 1, 8 do
            local x = boardX + (column - 1) * cellWidth
            local background = squareBackground(game, column, row)
            fill(target, x, y, cellWidth, cellHeight, background)

            local piece = game.board:get(column, row)
            if piece then
                drawPiece(target, piece, x, y, cellWidth, cellHeight, background)
            end
        end
    end

    if wide then
        drawStatusPanel(target, boardRegionWidth + 2, 3, panelWidth, game, options)
    elseif reserveBottom > 0 then
        local statusY = math.min(height - reserveBottom + 1, boardY + boardHeight + 1)
        local last = Move.toText(game.lastMove)
        write(target, 2, statusY, "TURN: " .. tostring(game:getTurn()):upper() .. "   " .. statusText(game), colors.cyan, colors.black, width - 2)
        write(target, 2, statusY + 1, "LAST: " .. last, colors.lightGray, colors.black, width - 2)
        if options.mode == "NETWORK" then
            write(target, 2, statusY + 2, "NETWORK " .. tostring(options.networkState or "ONLINE"):upper() .. "   MOVE #" .. tostring(options.moveNo or 0), colors.lime, colors.black, width - 2)
        end
    end

    local footer = "TURN " .. tostring(game:getTurn()):upper() .. " | " .. statusText(game)
    if options.mode == "NETWORK" then
        footer = footer .. " | #" .. tostring(options.moveNo or 0)
    end
    centered(target, height, footer, colors.white, colors.gray)

    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    return true
end

return MonitorRenderer
