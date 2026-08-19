local Game = require("tetris.game")
local Renderer = require("tetris.renderer")
local Button = require("lib.gui.button")
local KeyRepeat = require("lib.input.key_repeat")

local width, height = term.getSize()

if width < 46 or height < 19 then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    error("Terminal is too small for Tetris (need at least 46x19)")
end

local game = Game.new(10, 16)
local renderer = Renderer.new(term)

local infoX = 26

local pauseButton = Button.new({
    id = "pause",
    label = "Pause",
    x = infoX,
    y = 13,
    width = 20,
    height = 1,
    backgroundColor = colors.orange,
    textColor = colors.black,
    selectedBackgroundColor = colors.yellow,
    selectedTextColor = colors.black
})

local restartButton = Button.new({
    id = "restart",
    label = "Restart",
    x = infoX,
    y = 15,
    width = 20,
    height = 1,
    backgroundColor = colors.blue,
    textColor = colors.white
})

local backButton = Button.new({
    id = "back",
    label = "Back",
    x = infoX,
    y = 17,
    width = 20,
    height = 1,
    backgroundColor = colors.red,
    textColor = colors.white
})

local buttons = {
    pauseButton,
    restartButton,
    backButton
}

local keyRepeat = KeyRepeat.new({
    keys = {
        keys.left,
        keys.right,
        keys.down
    },
    initialDelay = 0.22,
    repeatDelay = 0.06
})

local gravityTimer = nil
local running = true

local function scheduleGravity()
    gravityTimer = os.startTimer(game:getDropInterval())
end

local function syncButtonLabels()
    if game.paused then
        pauseButton.label = "Resume"
    else
        pauseButton.label = "Pause"
    end
end

local function redraw()
    syncButtonLabels()
    renderer:draw(game, buttons)
end

local function restartGame()
    game:restart()
    keyRepeat:cancel()
    scheduleGravity()
end

local function processMovementKey(key, repeated)
    if key == keys.left then
        game:move(-1, 0)

    elseif key == keys.right then
        game:move(1, 0)

    elseif key == keys.down then
        local before = game.current
        game:softDrop()

        if game.current ~= before then
            scheduleGravity()
        end

    elseif not repeated and key == keys.up then
        game:rotate()

    elseif not repeated and key == keys.enter then
        game:hardDrop()
        scheduleGravity()

    elseif not repeated and key == keys.leftCtrl then
        if game:togglePause() then
            keyRepeat:cancel()
            scheduleGravity()
        end

    elseif not repeated and key == keys.leftShift then
        running = false
    end
end

local function handleMouse(button, x, y)
    if button ~= 1 then
        return false
    end

    if pauseButton:contains(x, y) then
        if game:togglePause() then
            keyRepeat:cancel()
            scheduleGravity()
        end
        return true
    end

    if restartButton:contains(x, y) then
        restartGame()
        return true
    end

    if backButton:contains(x, y) then
        running = false
        return true
    end

    return false
end

scheduleGravity()
redraw()

while running do
    local event, a, b, c = os.pullEvent()
    local redrawNeeded = false

    if event == "key" then
        processMovementKey(a, false)
        keyRepeat:handleEvent(event, a)
        redrawNeeded = true

    elseif event == "key_up" then
        keyRepeat:handleEvent(event, a)

    elseif event == "timer" then
        local repeatedKey = keyRepeat:handleEvent(event, a)

        if repeatedKey then
            processMovementKey(repeatedKey, true)
            redrawNeeded = true
        end

        if a == gravityTimer then
            if not game.paused and not game.gameOver then
                game:stepDown()
            end

            scheduleGravity()
            redrawNeeded = true
        end

    elseif event == "mouse_click" then
        keyRepeat:cancel()
        redrawNeeded = handleMouse(a, b, c)

    elseif event == "term_resize" then
        local newWidth, newHeight = term.getSize()

        if newWidth < 46 or newHeight < 19 then
            running = false
        else
            redrawNeeded = true
        end
    end

    if redrawNeeded and running then
        redraw()
    end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Tetris closed.")
