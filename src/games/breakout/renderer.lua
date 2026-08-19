local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(display)
    local self = setmetatable({}, Renderer)

    self.display = display
    self.width, self.height = display.getSize()
    self.color = not display.isColor or display.isColor()

    return self
end

function Renderer:setTextColor(color)
    if self.color then
        self.display.setTextColor(color)
    else
        self.display.setTextColor(colors.white)
    end
end

function Renderer:centerText(y, text, color)
    self:setTextColor(color or colors.white)

    local x = math.floor(
        (self.width - #text) / 2
    ) + 1

    if x < 1 then
        x = 1
    end

    self.display.setCursorPos(x, y)
    self.display.write(text)
end

function Renderer:drawHUD(score, lives)
    self:setTextColor(colors.yellow)
    self.display.setCursorPos(2, 1)
    self.display.write("SCORE: " .. tostring(score))

    local livesText = "LIVES: " .. tostring(lives)
    local livesX = self.width - #livesText

    if livesX < 1 then
        livesX = 1
    end

    self.display.setCursorPos(livesX, 1)
    self.display.write(livesText)
end

function Renderer:drawBricks(bricks)
    for _, brick in ipairs(bricks.items) do
        if brick.alive then
            self:setTextColor(brick.color)
            self.display.setCursorPos(brick.x, brick.y)
            self.display.write(
                string.rep("#", brick.width)
            )
        end
    end
end

function Renderer:drawPaddle(paddle)
    self:setTextColor(colors.lime)
    self.display.setCursorPos(paddle.x, paddle.y)
    self.display.write(
        string.rep("=", paddle.width)
    )
end

function Renderer:drawBall(ball)
    self:setTextColor(colors.white)
    self.display.setCursorPos(ball.x, ball.y)
    self.display.write("O")
end

function Renderer:draw(score, lives, paused, ball, paddle, bricks)
    self.display.setBackgroundColor(colors.black)
    self:setTextColor(colors.white)
    self.display.clear()

    self:drawHUD(score, lives)
    self:drawBricks(bricks)
    self:drawPaddle(paddle)
    self:drawBall(ball)

    if paused then
        self:centerText(
            math.floor(self.height / 2),
            "PAUSED",
            colors.yellow
        )
    end
end

function Renderer:showResult(result, score)
    self.display.setBackgroundColor(colors.black)
    self.display.clear()

    if result == "win" then
        self:centerText(
            math.floor(self.height / 2),
            "YOU WIN!",
            colors.lime
        )
    elseif result == "lose" then
        self:centerText(
            math.floor(self.height / 2),
            "GAME OVER",
            colors.red
        )
    else
        return
    end

    self:centerText(
        math.floor(self.height / 2) + 2,
        "SCORE: " .. tostring(score),
        colors.white
    )
end

function Renderer:clear()
    self.display.setBackgroundColor(colors.black)
    self:setTextColor(colors.white)
    self.display.clear()
    self.display.setCursorPos(1, 1)
end

return Renderer
