local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(monitor)
    local self = setmetatable({}, Renderer)

    self.monitor = monitor
    self.width, self.height = monitor.getSize()

    return self
end

function Renderer:centerText(y, text, color)
    self.monitor.setTextColor(color or colors.white)

    local x = math.floor(
        (self.width - #text) / 2
    ) + 1

    self.monitor.setCursorPos(x, y)
    self.monitor.write(text)
end

function Renderer:drawHUD(score, lives)
    self.monitor.setTextColor(colors.yellow)
    self.monitor.setCursorPos(2, 1)
    self.monitor.write("SCORE: " .. tostring(score))

    local livesText = "LIVES: " .. tostring(lives)

    self.monitor.setCursorPos(
        self.width - #livesText,
        1
    )

    self.monitor.write(livesText)
end

function Renderer:drawBricks(bricks)
    for _, brick in ipairs(bricks.items) do
        if brick.alive then
            self.monitor.setTextColor(brick.color)
            self.monitor.setCursorPos(brick.x, brick.y)
            self.monitor.write(
                string.rep("#", brick.width)
            )
        end
    end
end

function Renderer:drawPaddle(paddle)
    self.monitor.setTextColor(colors.lime)
    self.monitor.setCursorPos(paddle.x, paddle.y)
    self.monitor.write(
        string.rep("=", paddle.width)
    )
end

function Renderer:drawBall(ball)
    self.monitor.setTextColor(colors.white)
    self.monitor.setCursorPos(ball.x, ball.y)
    self.monitor.write("O")
end

function Renderer:draw(score, lives, paused, ball, paddle, bricks)
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.setTextColor(colors.white)
    self.monitor.clear()

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
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.clear()

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
    self.monitor.setBackgroundColor(colors.black)
    self.monitor.setTextColor(colors.white)
    self.monitor.clear()
end

return Renderer
