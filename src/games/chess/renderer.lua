local Pieces = require("chess.pieces")
local Move = require("chess.move")

local Renderer = {}
Renderer.__index = Renderer

local fileNames = {
    "a", "b", "c", "d", "e", "f", "g", "h"
}

local function formatClock(milliseconds)
    milliseconds = math.max(0, math.floor(tonumber(milliseconds) or 0))
    local totalSeconds = math.ceil(milliseconds / 1000)
    local minutes = math.floor(totalSeconds / 60)
    local seconds = totalSeconds % 60
    return string.format("%02d:%02d", minutes, seconds)
end

local function scoreText(value)
    value = tonumber(value) or 0

    if value == math.floor(value) then
        return tostring(math.floor(value))
    end

    return string.format("%.1f", value)
end

local function shortName(value, maximum)
    value = tostring(value or "?")
    maximum = maximum or 10

    if #value > maximum then
        return value:sub(1, maximum)
    end

    return value
end

function Renderer.new(target)
    local self = setmetatable({}, Renderer)

    self.target = target or term
    self.boardX = 2
    self.boardY = 3
    self.cellWidth = 4
    self.cellHeight = 2
    self.panelX = 36
    self.flipped = false
    self.title = "CHESS PVP"
    self.networkInfo = nil

    return self
end

function Renderer:setFlipped(flipped)
    self.flipped = flipped == true
end

function Renderer:setTitle(title)
    self.title = tostring(title or "CHESS PVP")
end

function Renderer:setNetworkInfo(info)
    self.networkInfo = type(info) == "table" and info or nil
end

function Renderer:resetColors()
    self.target.setBackgroundColor(colors.black)
    self.target.setTextColor(colors.white)
end

function Renderer:clear()
    self:resetColors()
    self.target.clear()
    self.target.setCursorPos(1, 1)
end

function Renderer:write(x, y, text, color, background)
    self.target.setBackgroundColor(background or colors.black)
    self.target.setTextColor(color or colors.white)
    self.target.setCursorPos(x, y)
    self.target.write(tostring(text))
end

function Renderer:drawHeader()
    local width = self.target.getSize()
    local text = self.title

    self.target.setBackgroundColor(colors.purple)
    self.target.setTextColor(colors.white)
    self.target.setCursorPos(1, 1)
    self.target.write(string.rep(" ", width))

    local x = math.max(1, math.floor((width - #text) / 2) + 1)
    self.target.setCursorPos(x, 1)
    self.target.write(text:sub(1, width))
    self:resetColors()
end

function Renderer:getSquareBackground(game, x, y)
    local background

    if (x + y) % 2 == 0 then
        background = colors.lightGray
    else
        background = colors.gray
    end

    if game.lastMove and
        ((game.lastMove.fromX == x and game.lastMove.fromY == y) or
         (game.lastMove.toX == x and game.lastMove.toY == y))
    then
        background = colors.blue
    end

    if game:isLegalDestination(x, y) then
        if game.board:get(x, y) then
            background = colors.orange
        else
            background = colors.lime
        end
    end

    if game.cursorX == x and game.cursorY == y then
        background = colors.lightBlue
    end

    if game.selectedX == x and game.selectedY == y then
        background = colors.yellow
    end

    return background
end

function Renderer:drawPiece(screenX, screenY, piece, background)
    local sprite = Pieces.sprite(piece)
    local foreground = piece.color == Pieces.WHITE and colors.white or colors.black

    for row = 1, self.cellHeight do
        self.target.setBackgroundColor(background)
        self.target.setTextColor(foreground)
        self.target.setCursorPos(screenX, screenY + row - 1)
        self.target.write(sprite[row] or string.rep(" ", self.cellWidth))
    end
end

function Renderer:screenToBoard(screenColumn, screenRow)
    local x = self.flipped and (9 - screenColumn) or screenColumn
    local y = self.flipped and (9 - screenRow) or screenRow
    return x, y
end

function Renderer:drawBoard(game)
    for screenColumn = 1, 8 do
        local boardX = self.flipped and (9 - screenColumn) or screenColumn
        local screenX = self.boardX + (screenColumn - 1) * self.cellWidth
        self:write(
            screenX + 1,
            2,
            fileNames[boardX],
            colors.lightGray
        )
    end

    for screenRow = 1, 8 do
        local boardY = self.flipped and (9 - screenRow) or screenRow
        local screenY = self.boardY + (screenRow - 1) * self.cellHeight

        self:write(
            1,
            screenY,
            tostring(9 - boardY),
            colors.lightGray
        )

        for screenColumn = 1, 8 do
            local boardX = self.flipped and (9 - screenColumn) or screenColumn
            local screenX = self.boardX + (screenColumn - 1) * self.cellWidth
            local background = self:getSquareBackground(game, boardX, boardY)
            local piece = game.board:get(boardX, boardY)

            for row = 0, self.cellHeight - 1 do
                self.target.setBackgroundColor(background)
                self.target.setTextColor(colors.black)
                self.target.setCursorPos(screenX, screenY + row)
                self.target.write(string.rep(" ", self.cellWidth))
            end

            if piece then
                self:drawPiece(screenX, screenY, piece, background)
            elseif game:isLegalDestination(boardX, boardY) then
                self.target.setBackgroundColor(background)
                self.target.setTextColor(colors.black)
                self.target.setCursorPos(screenX + 1, screenY)
                self.target.write("**")
            end
        end
    end

    self:resetColors()
end

function Renderer:drawLocalPanel(game)
    local x = self.panelX
    local turn = game:getTurn():upper()

    self:write(x, 3, "TURN: " .. turn, colors.cyan)

    if game.status == "checkmate" then
        self:write(x, 5, "CHECKMATE", colors.red)
        self:write(
            x,
            6,
            "WIN: " .. tostring(game.winner):upper(),
            colors.yellow
        )
    elseif game.status == "stalemate" then
        self:write(x, 5, "STALEMATE", colors.yellow)
    elseif game.inCheck then
        self:write(x, 5, "CHECK", colors.red)
    else
        self:write(x, 5, "STATUS: PLAY", colors.lime)
    end

    local selected = "-"

    if game.selectedX then
        selected = Move.squareName(game.selectedX, game.selectedY)
    end

    self:write(x, 7, "Selected: " .. selected, colors.white)

    local last = Move.toText(game.lastMove)

    if game.lastPromotion then
        last = last:gsub("=%?", "=" .. game.lastPromotion:sub(1, 1):upper())
    end

    self:write(x, 8, "Last: " .. last, colors.lightGray)

    if game.status ~= "playing" then
        self:write(x, 12, "New Game button", colors.lightGray)
    elseif not game.promotionPending then
        self:write(x, 12, "Click piece -> move", colors.lightGray)
    end
end

function Renderer:drawNetworkPanel(game)
    local x = self.panelX
    local info = self.networkInfo or {}
    local tournament = type(info.tournament) == "table" and info.tournament or nil

    if not tournament then
        self:write(x, 3, "TURN: " .. game:getTurn():upper(), colors.cyan)
        self:write(
            x,
            5,
            game.inCheck and "CHECK" or "STATUS: PLAY",
            game.inCheck and colors.red or colors.lime
        )
        self:write(
            x,
            9,
            info.spectator and "VIEW: SPECTATOR" or
                ("YOU: " .. tostring(info.localColor or "?"):upper()),
            colors.yellow
        )
        self:write(
            x,
            10,
            "NET: " .. tostring(info.state or "?"):upper(),
            info.connected == false and colors.red or colors.lime
        )
        self:write(x, 11, "MOVE: #" .. tostring(info.moveNo or 0), colors.lightGray)
        return
    end

    local whiteClock = formatClock(tournament.whiteMs)
    local blackClock = formatClock(tournament.blackMs)
    local whiteName = shortName(tournament.whiteName, 9)
    local blackName = shortName(tournament.blackName, 9)
    local stateColor = info.connected == false and colors.red or colors.lime
    local status = "PLAY"
    local statusColor = colors.lime

    if tournament.finished then
        if tournament.result == "timeout" then
            status = "TIMEOUT"
            statusColor = colors.red
        elseif tournament.result == "checkmate" then
            status = "CHECKMATE"
            statusColor = colors.red
        else
            status = tostring(tournament.result or "FINISHED"):upper()
            statusColor = colors.yellow
        end
    elseif game.inCheck then
        status = "CHECK"
        statusColor = colors.red
    elseif game.status == "stalemate" then
        status = "STALEMATE"
        statusColor = colors.yellow
    end

    self:write(x, 3, "W " .. whiteClock, tournament.activeColor == Pieces.WHITE and colors.yellow or colors.white)
    self:write(x, 4, "B " .. blackClock, tournament.activeColor == Pieces.BLACK and colors.yellow or colors.white)
    self:write(x, 5, "W:" .. whiteName, colors.white)
    self:write(x, 6, "B:" .. blackName, colors.lightGray)
    self:write(
        x,
        7,
        "S " .. scoreText(tournament.whiteScore) .. "-" .. scoreText(tournament.blackScore) ..
            " G" .. tostring(tournament.gameNo or 1),
        colors.cyan
    )
    self:write(
        x,
        8,
        info.spectator and "VIEW: SPEC" or
            ("YOU: " .. tostring(info.localColor or "?"):upper()),
        colors.yellow
    )
    self:write(x, 9, "NET: " .. tostring(info.state or "?"):upper(), stateColor)
    self:write(x, 10, "MOVE: #" .. tostring(info.moveNo or 0), colors.lightGray)
    self:write(x, 11, status, statusColor)

    if tournament.finished then
        local winner = tournament.winner and tostring(tournament.winner):upper() or "DRAW"
        self:write(x, 12, "RESULT: " .. winner, colors.yellow)
    elseif info.spectator then
        self:write(x, 12, "Read-only view", colors.lightGray)
    elseif game:getTurn() ~= info.localColor then
        self:write(x, 12, "Waiting opponent", colors.orange)
    else
        self:write(x, 12, "Your move", colors.lightGray)
    end
end

function Renderer:drawPanel(game)
    if self.networkInfo then
        self:drawNetworkPanel(game)
    else
        self:drawLocalPanel(game)
    end
end

function Renderer:drawPromotion(game, promotionButtons)
    if not game.promotionPending then
        return
    end

    self:write(self.panelX, 7, "PROMOTE PAWN:", colors.yellow)

    for _, button in ipairs(promotionButtons or {}) do
        button:draw(self.target)
    end
end

function Renderer:drawFooter()
    local width, height = self.target.getSize()
    local footer

    if self.networkInfo and self.networkInfo.spectator then
        footer = "SPECTATOR  MOUSE controls  SHIFT back"
    elseif self.networkInfo then
        footer = "MOUSE click  ARROWS cursor  ENTER select  CTRL new game  SHIFT back"
    else
        footer = "MOUSE click  ARROWS cursor  ENTER select  CTRL restart  SHIFT back"
    end

    if #footer > width then
        footer = self.networkInfo and self.networkInfo.spectator and
            "SPECTATOR  SHIFT back" or
            "MOUSE  ARROWS  ENTER  CTRL new  SHIFT back"
    end

    self.target.setBackgroundColor(colors.gray)
    self.target.setTextColor(colors.white)
    self.target.setCursorPos(1, height)
    self.target.write(string.rep(" ", width))

    local x = math.max(1, math.floor((width - #footer) / 2) + 1)
    self.target.setCursorPos(x, height)
    self.target.write(footer:sub(1, width))
    self:resetColors()
end

function Renderer:screenToSquare(x, y)
    if y < self.boardY or y >= self.boardY + 8 * self.cellHeight then
        return nil, nil
    end

    if x < self.boardX or x >= self.boardX + 8 * self.cellWidth then
        return nil, nil
    end

    local screenColumn = math.floor((x - self.boardX) / self.cellWidth) + 1
    local screenRow = math.floor((y - self.boardY) / self.cellHeight) + 1

    return self:screenToBoard(screenColumn, screenRow)
end

function Renderer:draw(game, controls)
    self:clear()
    self:drawHeader()
    self:drawBoard(game)
    self:drawPanel(game)

    if controls then
        if controls.restart then
            controls.restart:draw(self.target)
        end

        if controls.back then
            controls.back:draw(self.target)
        end

        self:drawPromotion(game, controls.promotions)
    end

    self:drawFooter()
    self:resetColors()
end

return Renderer
