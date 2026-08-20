local Game = require("chess.game")
local Renderer = require("chess.renderer")
local ChessNet = require("chess.network")
local Tournament = require("chess.tournament")
local Displays = require("chess.displays")
local DisplayMenu = require("chess.display_menu")
local Address = require("lib.net.address")
local CCTP = require("lib.net.cctp")
local Button = require("lib.gui.button")

local width, height = term.getSize()

if width < 51 or height < 19 then
    error("Terminal is too small for Chess Spectator (need at least 51x19)")
end

local game = Game.new()
local renderer = Renderer.new(term)
local displays = Displays.new()
local displayMenu = DisplayMenu.new(term, displays)
local tournament = Tournament.new({whiteName = "WHITE", blackName = "BLACK"})

renderer:setTitle("CHESS SPECTATOR")
renderer:setFlipped(false)

local running = true
local phase = "menu"
local targetId = os.getComputerID() + 1
local connectionId = nil
local connectRequestId = nil
local remoteAddress = nil
local gameId = nil
local moveNo = 0
local message = "Choose tournament HOST computer."

local function resetColors()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function line(y, text, color, x, maxWidth)
    x = x or 2
    maxWidth = maxWidth or (width - x + 1)
    text = tostring(text or "")

    if #text > maxWidth then
        text = text:sub(1, maxWidth)
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(color or colors.white)
    term.setCursorPos(x, y)
    term.write(text .. string.rep(" ", math.max(0, maxWidth - #text)))
    resetColors()
end

local function makeButton(id, label, x, y, buttonWidth, background, foreground)
    return Button.new({
        id = id,
        label = label,
        x = x,
        y = y,
        width = buttonWidth,
        height = 1,
        backgroundColor = background,
        textColor = foreground or colors.white
    })
end

local idMinusButton = makeButton("idminus", "ID -", 12, 6, 8, colors.gray)
local idPlusButton = makeButton("idplus", "ID +", 32, 6, 8, colors.gray)
local connectButton = makeButton("connect", "Watch Tournament", 12, 9, 28, colors.blue)
local menuBackButton = makeButton("back", "Back", 12, 13, 28, colors.red)
local displayButton = makeButton("displays", "Displays", 36, 15, 15, colors.purple)
local backButton = makeButton("back", "Back", 36, 16, 15, colors.red)

local controls = {
    back = backButton
}

local function targetAddress()
    return Address.forComputer(targetId) or "INVALID"
end

local function drawHeader(title, background)
    background = background or colors.purple
    term.setBackgroundColor(background)
    term.setTextColor(colors.white)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    term.setCursorPos(math.max(1, math.floor((width - #title) / 2) + 1), 2)
    term.write(title:sub(1, width))
    resetColors()
end

local function drawMenu()
    resetColors()
    term.clear()
    drawHeader("TOURNAMENT SPECTATOR", colors.purple)

    line(4, "LOCAL: " .. tostring(Address.localAddress() or "NO CCIP"), colors.cyan)
    line(5, "TARGET HOST #" .. tostring(targetId) .. " " .. targetAddress(), colors.yellow)
    idMinusButton:draw(term)
    idPlusButton:draw(term)
    connectButton:draw(term)
    menuBackButton:draw(term)
    line(15, "Read-only CCTP spectator port " .. tostring(ChessNet.SPECTATOR_PORT), colors.lightGray)
    line(17, message, colors.gray)

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))
    local footer = "LEFT/RIGHT target  ENTER connect  SHIFT back"
    term.setCursorPos(math.max(1, math.floor((width - #footer) / 2) + 1), height)
    term.write(footer:sub(1, width))
    resetColors()
end

local function renderMonitors()
    displays:render(game, {
        mode = "NETWORK",
        title = "CHESS TOURNAMENT",
        moveNo = moveNo,
        networkState = phase == "viewing" and "ONLINE" or "DISCONNECTED",
        spectator = true,
        tournament = tournament:export()
    })
end

local function drawViewer()
    renderer:setNetworkInfo({
        spectator = true,
        state = phase == "viewing" and "ONLINE" or phase,
        connected = connectionId ~= nil and phase == "viewing",
        moveNo = moveNo,
        tournament = tournament:export()
    })
    renderer:draw(game, controls)
    displayButton:draw(term)
    line(17, message, colors.gray, 36, 15)
    renderMonitors()
end

local function drawConnecting()
    resetColors()
    term.clear()
    drawHeader("SPECTATOR CONNECT", colors.blue)
    line(6, "HOST: " .. tostring(remoteAddress or targetAddress()), colors.cyan)
    line(9, "STATE: " .. tostring(phase):upper(), colors.yellow)
    line(12, message, colors.lightGray)
    menuBackButton:draw(term)
end

local function redraw()
    if displayMenu:isOpen() then
        displayMenu:draw()
    elseif phase == "menu" then
        displays:clearOutputs()
        drawMenu()
    elseif phase == "viewing" or phase == "disconnected" then
        drawViewer()
    else
        displays:clearOutputs()
        drawConnecting()
    end
end

local function disconnect()
    if connectionId then
        CCTP.close(connectionId)
    end

    connectionId = nil
    connectRequestId = nil
end

local function backToMenu()
    displayMenu:close()
    disconnect()
    gameId = nil
    moveNo = 0
    remoteAddress = nil
    game:restart()
    tournament = Tournament.new({whiteName = "WHITE", blackName = "BLACK"})
    phase = "menu"
    message = "Choose tournament HOST computer."
    displays:clearOutputs()
end

local function connectToHost()
    local address = targetAddress()

    if address == "INVALID" or targetId == os.getComputerID() then
        message = "Choose another valid Computer ID."
        return false
    end

    disconnect()
    remoteAddress = address
    connectRequestId = ChessNet.connectSpectator(address)

    if not connectRequestId then
        message = "Failed to queue spectator connection."
        phase = "menu"
        return false
    end

    phase = "connecting"
    message = "Connecting to " .. address .. ":" .. tostring(ChessNet.SPECTATOR_PORT) .. "..."
    return true
end

local function importState(payload)
    if type(payload) ~= "table" or type(payload.snapshot) ~= "table" then
        return false, "spectator_missing_snapshot"
    end

    local ok, err = game:importState(payload.snapshot)

    if not ok then
        return false, err
    end

    moveNo = math.max(0, math.floor(tonumber(payload.moveNo) or 0))

    if payload.hash and tostring(payload.hash) ~= "" and
        tostring(payload.hash) ~= game:positionSignature()
    then
        return false, "spectator_hash_mismatch"
    end

    if type(payload.tournament) == "table" then
        tournament:import(payload.tournament)
    end

    return true
end

local function handleNetworkMessage(connId, payload, source)
    if connId ~= connectionId then
        return false
    end

    local valid, reason = ChessNet.validate(payload)

    if not valid then
        message = "Rejected packet: " .. tostring(reason)
        return true
    end

    if gameId and payload.gameId ~= gameId then
        message = "Foreign tournament session rejected."
        return true
    end

    if payload.type == ChessNet.TYPE_SPECTATOR_HELLO then
        gameId = payload.gameId
        remoteAddress = source or remoteAddress
        local ok, err = importState(payload.payload)

        if ok then
            phase = "viewing"
            message = "Spectating game #" .. tostring(tournament.gameNo) .. "."
        else
            message = "Initial spectator sync failed: " .. tostring(err)
        end

        return true
    end

    if not gameId or payload.gameId ~= gameId then
        return true
    end

    if payload.type == ChessNet.TYPE_SPECTATOR_STATE then
        local ok, err = importState(payload.payload)

        if ok then
            phase = "viewing"
            message = "Live tournament state."
        else
            message = "Spectator sync failed: " .. tostring(err)
        end

        return true
    end

    if payload.type == ChessNet.TYPE_TOURNAMENT then
        if type(payload.payload.tournament) == "table" then
            tournament:import(payload.payload.tournament)
            moveNo = math.max(moveNo, math.floor(tonumber(payload.payload.moveNo) or moveNo))
        end
        return true
    end

    return true
end

redraw()

while running do
    local event, a, b, c, d = os.pullEvent()
    local redrawNeeded = false
    local uiConsumed = false

    if displayMenu:isOpen() and
        (event == "mouse_click" or event == "key" or
         event == "peripheral" or event == "peripheral_detach")
    then
        local changed = displayMenu:handleEvent(event, a, b, c)
        redrawNeeded = changed == true
        uiConsumed = true
    end

    if not uiConsumed then
        if event == "mouse_click" and (a == 1 or a == 0) then
            if phase == "menu" then
                if idMinusButton:contains(b, c) then
                    targetId = math.max(0, targetId - 1)
                    redrawNeeded = true
                elseif idPlusButton:contains(b, c) then
                    targetId = targetId + 1
                    redrawNeeded = true
                elseif connectButton:contains(b, c) then
                    connectToHost()
                    redrawNeeded = true
                elseif menuBackButton:contains(b, c) then
                    running = false
                end
            elseif phase == "viewing" or phase == "disconnected" then
                if displayButton:contains(b, c) then
                    displayMenu:open()
                    redrawNeeded = true
                elseif backButton:contains(b, c) then
                    backToMenu()
                    redrawNeeded = true
                end
            elseif menuBackButton:contains(b, c) then
                backToMenu()
                redrawNeeded = true
            end

        elseif event == "key" then
            if a == keys.leftShift then
                if phase == "menu" then
                    running = false
                else
                    backToMenu()
                    redrawNeeded = true
                end
            elseif phase == "menu" then
                if a == keys.left then
                    targetId = math.max(0, targetId - 1)
                    redrawNeeded = true
                elseif a == keys.right then
                    targetId = targetId + 1
                    redrawNeeded = true
                elseif a == keys.enter then
                    connectToHost()
                    redrawNeeded = true
                end
            end

        elseif event == "ccbase_cctp_connect_result" and connectRequestId and a == connectRequestId then
            if b == true then
                connectionId = c
                remoteAddress = d or remoteAddress
                phase = "handshake"
                message = "Connected. Waiting spectator state..."
            else
                phase = "menu"
                message = "Spectator connect failed: " .. tostring(c)
            end
            connectRequestId = nil
            redrawNeeded = true

        elseif event == "ccbase_cctp_receive" then
            redrawNeeded = handleNetworkMessage(a, b, c) or redrawNeeded

        elseif event == "ccbase_cctp_closed" and a == connectionId then
            connectionId = nil
            phase = "disconnected"
            tournament.running = false
            message = "Spectator connection closed: " .. tostring(b) .. "."
            redrawNeeded = true

        elseif event == "ccbase_cctp_send_result" and b == false and d == connectionId then
            message = "Spectator transport error: " .. tostring(c)
            redrawNeeded = true

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
    end

    if redrawNeeded and running then
        redraw()
    end
end

disconnect()
displays:clearOutputs()
resetColors()
term.clear()
term.setCursorPos(1, 1)
print("Chess Spectator closed.")
