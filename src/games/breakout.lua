local Ball = require("breakout.ball")
local Paddle = require("breakout.paddle")
local Bricks = require("breakout.bricks")
local Renderer = require("breakout.renderer")

local monitor = peripheral.find("monitor")

if not monitor then
    error("Monitor not found")
end

monitor.setTextScale(0.5)

local width, height = monitor.getSize()

local tick = 0.10
local running = true
local paused = false
local result = nil
local score = 0
local lives = 3

local paddleWidth = math.max(
    7,
    math.floor(width / 7)
)

local paddleY = height - 1
local paddleX = math.floor(
    (width - paddleWidth) / 2
)

local paddle = Paddle.new(
    paddleX,
    paddleY,
    paddleWidth,
    width
)

local ball = Ball.new(
    math.floor(width / 2),
    paddleY - 2,
    1,
    -1
)

local bricks = Bricks.new(
    width,
    height,
    4
)

local renderer = Renderer.new(monitor)

local function resetBall()
    ball:reset(
        math.floor(width / 2),
        paddleY - 2,
        1,
        -1
    )
end

local function moveBall()
    local nextX, nextY = ball:nextPosition()

    if nextX <= 1 then
        ball:setDX(1)
        nextX, nextY = ball:nextPosition()
    elseif nextX >= width then
        ball:setDX(-1)
        nextX, nextY = ball:nextPosition()
    end

    if nextY <= 2 then
        ball:setDY(1)
        nextX, nextY = ball:nextPosition()
    end

    if bricks:hitAt(nextX, nextY) then
        score = score + 10
        ball:bounceY()
        nextX, nextY = ball:nextPosition()

        if bricks:isEmpty() then
            result = "win"
            running = false
            return
        end
    end

    if ball.dy > 0 and nextY >= paddle.y then
        if paddle:contains(nextX) then
            ball:setDY(-1)

            local paddleCenter = paddle:center()

            if nextX < paddleCenter - 1 then
                ball:setDX(-1)
            elseif nextX > paddleCenter + 1 then
                ball:setDX(1)
            end

            nextX = ball.x + ball.dx
            nextY = paddle.y - 1
        else
            lives = lives - 1

            if lives <= 0 then
                result = "lose"
                running = false
                return
            end

            resetBall()
            sleep(0.5)
            return
        end
    end

    ball:setPosition(nextX, nextY)
end

local function gameLoop()
    while running do
        if not paused then
            moveBall()
        end

        renderer:draw(
            score,
            lives,
            paused,
            ball,
            paddle,
            bricks
        )

        sleep(tick)
    end
end

local function inputLoop()
    while running do
        local event, a, b = os.pullEvent()

        if event == "key" then
            if a == keys.left then
                paddle:move(-3)
            elseif a == keys.right then
                paddle:move(3)
            elseif a == keys.enter then
                paused = not paused
            elseif a == keys.leftShift then
                result = "exit"
                running = false
                return
            end
        elseif event == "monitor_touch" then
            local touchX = b

            if touchX < width / 2 then
                paddle:move(-3)
            else
                paddle:move(3)
            end
        end
    end
end

term.clear()
term.setCursorPos(1, 1)

print("BREAKOUT v3")
print("")
print("LEFT / RIGHT - move")
print("ENTER        - pause")
print("LEFT SHIFT   - exit")
print("")
print("Monitor touch:")
print("left/right half")

renderer:draw(
    score,
    lives,
    paused,
    ball,
    paddle,
    bricks
)

parallel.waitForAny(
    gameLoop,
    inputLoop
)

renderer:showResult(result, score)

if result == "win" or result == "lose" then
    sleep(3)
end

renderer:clear()

term.clear()
term.setCursorPos(1, 1)

print("Breakout closed.")
print("Score: " .. score)
