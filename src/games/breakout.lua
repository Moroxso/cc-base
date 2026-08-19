local Ball = require("breakout.ball")
local Paddle = require("breakout.paddle")
local Bricks = require("breakout.bricks")
local Renderer = require("breakout.renderer")

local monitor = peripheral.find("monitor")

local function resetTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function chooseDisplay()
    if not monitor then
        return term, false
    end

    local options = {
        "Computer",
        "Monitor"
    }

    local selected = 1

    while true do
        resetTerminal()

        print("BREAKOUT v4")
        print("")
        print("Select display:")
        print("")

        for i, name in ipairs(options) do
            if i == selected then
                term.setBackgroundColor(colors.white)
                term.setTextColor(colors.black)
                print(" > " .. name .. " ")
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.white)
            else
                print("   " .. name)
            end
        end

        print("")
        print("UP/DOWN - select")
        print("ENTER   - start")
        print("SHIFT   - cancel")

        local _, key = os.pullEvent("key")

        if key == keys.up then
            selected = selected - 1

            if selected < 1 then
                selected = #options
            end

        elseif key == keys.down then
            selected = selected + 1

            if selected > #options then
                selected = 1
            end

        elseif key == keys.enter then
            if selected == 1 then
                return term, false
            end

            return monitor, true

        elseif key == keys.leftShift then
            return nil, false
        end
    end
end

local display, usingMonitor = chooseDisplay()

if not display then
    resetTerminal()
    print("Breakout cancelled.")
    return
end

if usingMonitor then
    monitor.setTextScale(0.5)
end

local width, height = display.getSize()

if width < 20 or height < 12 then
    resetTerminal()
    error(
        "Display is too small: " ..
        width .. "x" .. height
    )
end

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

local renderer = Renderer.new(display)

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

        elseif usingMonitor and event == "monitor_touch" then
            local touchX = b

            if touchX < width / 2 then
                paddle:move(-3)
            else
                paddle:move(3)
            end
        end
    end
end

resetTerminal()

if usingMonitor then
    print("BREAKOUT v4")
    print("")
    print("Display: MONITOR")
    print("")
    print("LEFT / RIGHT - move")
    print("ENTER        - pause")
    print("LEFT SHIFT   - exit")
    print("")
    print("Monitor touch:")
    print("left/right half")
else
    print("BREAKOUT v4")
    print("")
    print("Display: COMPUTER")
    print("")
    print("LEFT / RIGHT - move")
    print("ENTER        - pause")
    print("LEFT SHIFT   - exit")
    sleep(1.5)
end

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

resetTerminal()
print("Breakout closed.")
print("Score: " .. score)
