local Game = require("chess.game")
local Renderer = require("chess.renderer")
local Displays = require("chess.displays")
local DisplayMenu = require("chess.display_menu")
local Button = require("lib.gui.button")

local width, height = term.getSize()

if width < 51 or height < 19 then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    error("Terminal is too small for Chess (need at least 51x19)")
end

local game = Game.new()
local renderer = Renderer.new(term)
local displays = Displays.new()
local displayMenu = DisplayMenu.new(term, displays)
local running = true
local promotionIndex = 1

local restartButton = Button.new({
    id = "restart",
    label = "New Game",
    x = 36,
    y = 14,
    width = 15,
    height = 1,
    backgroundColor = colors.blue,
    textColor = colors.white
})

local displayButton = Button.new({
    id = "displays",
    label = "Displays",
    x = 36,
    y = 15,
    width = 15,
    height = 1,
    backgroundColor = colors.purple,
    textColor = colors.white
})

local backButton = Button.new({
    id = "back",
    label = "Back",
    x = 36,
    y = 16,
    width = 15,
    height = 1,
    backgroundColor = colors.red,
    textColor = colors.white
})

local promotionKinds = {
    "queen",
    "rook",
    "bishop",
    "knight"
}

local promotionButtons = {
    Button.new({
        id = "queen",
        label = "Queen",
        x = 35,
        y = 9,
        width = 8,
        height = 1,
        backgroundColor = colors.gray
    }),
    Button.new({
        id = "rook",
        label = "Rook",
        x = 44,
        y = 9,
        width = 8,
        height = 1,
        backgroundColor = colors.gray
    }),
    Button.new({
        id = "bishop",
        label = "Bishop",
        x = 35,
        y = 11,
        width = 8,
        height = 1,
        backgroundColor = colors.gray
    }),
    Button.new({
        id = "knight",
        label = "Knight",
        x = 44,
        y = 11,
        width = 8,
        height = 1,
        backgroundColor = colors.gray
    })
}

local controls = {
    restart = restartButton,
    back = backButton,
    promotions = promotionButtons
}

local function syncPromotionSelection()
    for i, button in ipairs(promotionButtons) do
        button:setSelected(
            game.promotionPending ~= nil and i == promotionIndex
        )
    end
end

local function renderMonitors()
    displays:render(game, {
        mode = "LOCAL",
        title = "CHESS TOURNAMENT"
    })
end

local function redraw()
    if displayMenu:isOpen() then
        displayMenu:draw()
    else
        syncPromotionSelection()
        renderer:draw(game, controls)
        displayButton:draw(term)
    end

    renderMonitors()
end

local function restartGame()
    game:restart()
    promotionIndex = 1
end

local function choosePromotion(index)
    index = math.max(1, math.min(#promotionKinds, index))

    if game:choosePromotion(promotionKinds[index]) then
        promotionIndex = 1
        return true
    end

    return false
end

local function isPointerClick(button)
    return button == 1 or button == 0
end

local function handleMouse(button, x, y)
    if not isPointerClick(button) then
        return false
    end

    if displayButton:contains(x, y) then
        displayMenu:open()
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

    if game.promotionPending then
        for i, promotionButton in ipairs(promotionButtons) do
            if promotionButton:contains(x, y) then
                promotionIndex = i
                choosePromotion(i)
                return true
            end
        end

        return false
    end

    local boardX, boardY = renderer:screenToSquare(x, y)

    if boardX then
        local result = game:clickSquare(boardX, boardY)

        if result == "promotion" then
            promotionIndex = 1
        end

        return true
    end

    return false
end

local function movePromotionCursor(key)
    if key == keys.left then
        promotionIndex = promotionIndex - 1
        if promotionIndex < 1 then promotionIndex = #promotionKinds end
    elseif key == keys.right then
        promotionIndex = promotionIndex + 1
        if promotionIndex > #promotionKinds then promotionIndex = 1 end
    elseif key == keys.up then
        promotionIndex = promotionIndex - 2
        if promotionIndex < 1 then promotionIndex = promotionIndex + #promotionKinds end
    elseif key == keys.down then
        promotionIndex = promotionIndex + 2
        if promotionIndex > #promotionKinds then promotionIndex = promotionIndex - #promotionKinds end
    end
end

redraw()

while running do
    local event, a, b, c = os.pullEvent()
    local redrawNeeded = false

    if displayMenu:isOpen() then
        local changed = displayMenu:handleEvent(event, a, b, c)
        redrawNeeded = changed == true

    elseif event == "mouse_click" then
        redrawNeeded = handleMouse(a, b, c)

    elseif event == "key" then
        local key = a

        if key == keys.leftShift then
            running = false
        elseif key == keys.leftCtrl then
            restartGame()
            redrawNeeded = true
        elseif game.promotionPending then
            if key == keys.enter then
                redrawNeeded = choosePromotion(promotionIndex)
            elseif key == keys.left or key == keys.right or key == keys.up or key == keys.down then
                movePromotionCursor(key)
                redrawNeeded = true
            end
        elseif key == keys.left then
            game:moveCursor(-1, 0)
            redrawNeeded = true
        elseif key == keys.right then
            game:moveCursor(1, 0)
            redrawNeeded = true
        elseif key == keys.up then
            game:moveCursor(0, -1)
            redrawNeeded = true
        elseif key == keys.down then
            game:moveCursor(0, 1)
            redrawNeeded = true
        elseif key == keys.enter then
            local result = game:activateCursor()

            if result == "promotion" then
                promotionIndex = 1
            end

            redrawNeeded = true
        end

    elseif event == "peripheral" or event == "peripheral_detach" then
        displays:refresh()
        redrawNeeded = true

    elseif event == "term_resize" then
        local newWidth, newHeight = term.getSize()

        if newWidth < 51 or newHeight < 19 then
            running = false
        else
            width, height = newWidth, newHeight
            redrawNeeded = true
        end
    end

    if redrawNeeded and running then
        redraw()
    end
end

displays:clearOutputs()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Chess closed.")
