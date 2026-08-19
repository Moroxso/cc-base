local monitor = peripheral.find("monitor")

if not monitor then
    error("Monitor not found")
end

monitor.setTextScale(0.5)

local width, height = monitor.getSize()

-- =========================
-- GAME SETTINGS
-- =========================

local tick = 0.10

local running = true
local paused = false
local result = nil

local score = 0
local lives = 3

-- =========================
-- PADDLE
-- =========================

local paddleWidth = math.max(
    7,
    math.floor(width / 7)
)

local paddleY = height - 1

local paddleX = math.floor(
    (width - paddleWidth) / 2
)

-- =========================
-- BALL
-- =========================

local ballX = math.floor(width / 2)
local ballY = paddleY - 2

local ballDX = 1
local ballDY = -1

-- =========================
-- BRICKS
-- =========================

local bricks = {}

local brickWidth = 4
local brickRows = math.min(4, height - 8)

local bricksLeft = 0

-- =========================
-- HELPERS
-- =========================

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end

    if value > maxValue then
        return maxValue
    end

    return value
end

local function centerText(y, text, color)
    monitor.setTextColor(color or colors.white)

    local x = math.floor(
        (width - #text) / 2
    ) + 1

    monitor.setCursorPos(x, y)
    monitor.write(text)
end

-- =========================
-- BRICKS
-- =========================

local brickColors = {
    colors.red,
    colors.orange,
    colors.yellow,
    colors.lime
}

local function createBricks()
    bricks = {}
    bricksLeft = 0

    local startY = 3

    for row = 1, brickRows do
        local y = startY + row - 1

        local x = 2

        while x + brickWidth - 1 < width do
            table.insert(
                bricks,
                {
                    x = x,
                    y = y,
                    width = brickWidth - 1,
                    alive = true,
                    color =
                        brickColors[
                            ((row - 1) % #brickColors) + 1
                        ]
                }
            )

            bricksLeft = bricksLeft + 1

            x = x + brickWidth
        end
    end
end

-- =========================
-- BALL RESET
-- =========================

local function resetBall()
    ballX = math.floor(width / 2)
    ballY = paddleY - 2

    ballDX = 1
    ballDY = -1
end

-- =========================
-- PADDLE MOVEMENT
-- =========================

local function movePaddle(amount)
    paddleX = paddleX + amount

    paddleX = clamp(
        paddleX,
        2,
        width - paddleWidth
    )
end

-- =========================
-- BRICK COLLISION
-- =========================

local function getBrickAt(x, y)
    for _, brick in ipairs(bricks) do
        if brick.alive then
            if
                y == brick.y
                and x >= brick.x
                and x < brick.x + brick.width
            then
                return brick
            end
        end
    end

    return nil
end

-- =========================
-- DRAWING
-- =========================

local function drawHUD()
    monitor.setTextColor(colors.yellow)

    monitor.setCursorPos(2, 1)

    monitor.write(
        "SCORE: " ..
        tostring(score)
    )

    local livesText =
        "LIVES: " ..
        tostring(lives)

    monitor.setCursorPos(
        width - #livesText,
        1
    )

    monitor.write(livesText)
end

local function drawBricks()
    for _, brick in ipairs(bricks) do
        if brick.alive then
            monitor.setTextColor(
                brick.color
            )

            monitor.setCursorPos(
                brick.x,
                brick.y
            )

            monitor.write(
                string.rep(
                    "#",
                    brick.width
                )
            )
        end
    end
end

local function drawPaddle()
    monitor.setTextColor(colors.lime)

    monitor.setCursorPos(
        paddleX,
        paddleY
    )

    monitor.write(
        string.rep(
            "=",
            paddleWidth
        )
    )
end

local function drawBall()
    monitor.setTextColor(colors.white)

    monitor.setCursorPos(
        ballX,
        ballY
    )

    monitor.write("O")
end

local function drawPause()
    if paused then
        centerText(
            math.floor(height / 2),
            "PAUSED",
            colors.yellow
        )
    end
end

local function draw()
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)

    monitor.clear()

    drawHUD()
    drawBricks()
    drawPaddle()
    drawBall()
    drawPause()
end

-- =========================
-- BALL PHYSICS
-- =========================

local function moveBall()
    local nextX =
        ballX + ballDX

    local nextY =
        ballY + ballDY

    -- LEFT WALL

    if nextX <= 1 then
        ballDX = 1
        nextX = ballX + ballDX
    end

    -- RIGHT WALL

    if nextX >= width then
        ballDX = -1
        nextX = ballX + ballDX
    end

    -- TOP WALL

    if nextY <= 2 then
        ballDY = 1
        nextY = ballY + ballDY
    end

    -- BRICK COLLISION

    local brick =
        getBrickAt(
            nextX,
            nextY
        )

    if brick then
        brick.alive = false

        bricksLeft =
            bricksLeft - 1

        score =
            score + 10

        ballDY =
            -ballDY

        nextY =
            ballY + ballDY

        if bricksLeft <= 0 then
            result = "win"
            running = false
            return
        end
    end

    -- PADDLE COLLISION

    if
        ballDY > 0
        and nextY >= paddleY
    then
        if
            nextX >= paddleX
            and nextX <
                paddleX + paddleWidth
        then

            ballDY = -1

            local paddleCenter =
                paddleX +
                paddleWidth / 2

            if nextX <
                paddleCenter - 1
            then
                ballDX = -1

            elseif nextX >
                paddleCenter + 1
            then
                ballDX = 1
            end

            nextY =
                paddleY - 1

        else
            -- BALL MISSED

            lives =
                lives - 1

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

    ballX = nextX
    ballY = nextY
end

-- =========================
-- GAME LOOP
-- =========================

local function gameLoop()
    while running do
        if not paused then
            moveBall()
        end

        draw()

        sleep(tick)
    end
end

-- =========================
-- INPUT LOOP
-- =========================

local function inputLoop()
    while running do
        local event, a, b, c =
            os.pullEvent()

        if event == "key" then

            if a == keys.left then
                movePaddle(-3)

            elseif a == keys.right then
                movePaddle(3)

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
                movePaddle(-3)
            else
                movePaddle(3)
            end
        end
    end
end

-- =========================
-- START SCREEN
-- =========================

term.clear()
term.setCursorPos(1, 1)

print("BREAKOUT v2")
print("")
print("LEFT / RIGHT - move")
print("ENTER        - pause")
print("LEFT SHIFT   - exit")
print("")
print("Monitor touch:")
print("left/right half")

createBricks()
resetBall()
draw()

-- =========================
-- RUN
-- =========================

parallel.waitForAny(
    gameLoop,
    inputLoop
)

-- =========================
-- END SCREEN
-- =========================

monitor.setBackgroundColor(colors.black)
monitor.clear()

if result == "win" then
    centerText(
        math.floor(height / 2),
        "YOU WIN!",
        colors.lime
    )

    centerText(
        math.floor(height / 2) + 2,
        "SCORE: " .. score,
        colors.white
    )

    sleep(3)

elseif result == "lose" then
    centerText(
        math.floor(height / 2),
        "GAME OVER",
        colors.red
    )

    centerText(
        math.floor(height / 2) + 2,
        "SCORE: " .. score,
        colors.white
    )

    sleep(3)
end

monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.white)
monitor.clear()

term.clear()
term.setCursorPos(1, 1)

print("Breakout closed.")
print("Score: " .. score)