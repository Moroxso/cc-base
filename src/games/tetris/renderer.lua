local Pieces = require("tetris.pieces")

local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(target)
    local self = setmetatable({}, Renderer)

    self.target = target or term
    self.boardX = 2
    self.boardY = 2
    self.cellWidth = 2

    return self
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

function Renderer:drawCell(boardX, boardY, color)
    local x = self.boardX + (boardX - 1) * self.cellWidth
    local y = self.boardY + boardY - 1

    self.target.setCursorPos(x, y)
    self.target.setBackgroundColor(color or colors.black)
    self.target.write(string.rep(" ", self.cellWidth))
end

function Renderer:drawBorder(board)
    local left = self.boardX - 1
    local right = self.boardX + board.width * self.cellWidth
    local top = self.boardY - 1
    local bottom = self.boardY + board.height

    self.target.setBackgroundColor(colors.black)
    self.target.setTextColor(colors.lightGray)

    self.target.setCursorPos(left, top)
    self.target.write("+" .. string.rep("-", board.width * self.cellWidth) .. "+")

    for y = self.boardY, self.boardY + board.height - 1 do
        self.target.setCursorPos(left, y)
        self.target.write("|")
        self.target.setCursorPos(right, y)
        self.target.write("|")
    end

    self.target.setCursorPos(left, bottom)
    self.target.write("+" .. string.rep("-", board.width * self.cellWidth) .. "+")
end

function Renderer:drawBoard(game)
    local board = game.board

    for y = 1, board.height do
        for x = 1, board.width do
            self:drawCell(x, y, board:get(x, y))
        end
    end

    if game.current and not game.gameOver then
        local color = Pieces.getColor(game.current.kind)
        local cells = Pieces.getCells(
            game.current.kind,
            game.current.rotation
        )

        for _, cell in ipairs(cells) do
            local x = game.current.x + cell[1]
            local y = game.current.y + cell[2]

            if y >= 1 and y <= board.height then
                self:drawCell(x, y, color)
            end
        end
    end

    self:drawBorder(board)
end

function Renderer:write(x, y, text, color)
    self.target.setBackgroundColor(colors.black)
    self.target.setTextColor(color or colors.white)
    self.target.setCursorPos(x, y)
    self.target.write(tostring(text))
end

function Renderer:drawPreview(kind, x, y)
    self:write(x, y, "NEXT", colors.lightGray)

    for row = 0, 3 do
        self.target.setCursorPos(x, y + 1 + row)
        self.target.setBackgroundColor(colors.black)
        self.target.write(string.rep(" ", 10))
    end

    local color = Pieces.getColor(kind)
    local cells = Pieces.getCells(kind, 1)

    for _, cell in ipairs(cells) do
        self.target.setCursorPos(
            x + cell[1] * 2,
            y + 1 + cell[2]
        )
        self.target.setBackgroundColor(color)
        self.target.write("  ")
    end

    self:resetColors()
end

function Renderer:drawOverlay(game)
    local text
    local color

    if game.gameOver then
        text = "GAME OVER"
        color = colors.red
    elseif game.paused then
        text = "PAUSED"
        color = colors.yellow
    else
        return
    end

    local width = game.board.width * self.cellWidth
    local x = self.boardX + math.floor((width - #text) / 2)
    local y = self.boardY + math.floor(game.board.height / 2)

    self.target.setBackgroundColor(colors.black)
    self.target.setTextColor(color)
    self.target.setCursorPos(x, y)
    self.target.write(text)
    self:resetColors()
end

function Renderer:draw(game, buttons)
    self:clear()
    self:drawBoard(game)

    local infoX = self.boardX + game.board.width * self.cellWidth + 4

    self:write(infoX, 2, "TETRIS", colors.cyan)
    self:write(infoX, 4, "Score: " .. game.score, colors.white)
    self:write(infoX, 5, "Lines: " .. game.lines, colors.white)
    self:write(infoX, 6, "Level: " .. game.level, colors.white)
    self:drawPreview(game.nextKind, infoX, 8)

    for _, button in ipairs(buttons or {}) do
        button:draw(self.target)
    end

    self:write(infoX, 18, "CTRL pause", colors.lightGray)

    local width, height = self.target.getSize()
    local footer = "LEFT/RIGHT move  UP rotate  DOWN soft  ENTER drop  SHIFT back"

    if #footer > width then
        footer = "ARROWS  ENTER drop  CTRL pause  SHIFT back"
    end

    self.target.setBackgroundColor(colors.gray)
    self.target.setTextColor(colors.white)
    self.target.setCursorPos(1, height)
    self.target.write(string.rep(" ", width))

    local footerX = math.max(1, math.floor((width - #footer) / 2) + 1)
    self.target.setCursorPos(footerX, height)
    self.target.write(footer:sub(1, width))

    self:drawOverlay(game)
    self:resetColors()
end

return Renderer
