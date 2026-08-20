local Game = require("chess.game")
local Renderer = require("chess.renderer")
local Pieces = require("chess.pieces")
local ChessNet = require("chess.network")
local Address = require("lib.net.address")
local CCTP = require("lib.net.cctp")
local Button = require("lib.gui.button")

local width, height = term.getSize()

if width < 51 or height < 19 then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    error("Terminal is too small for Network Chess (need at least 51x19)")
end

local game = Game.new()
local renderer = Renderer.new(term)
renderer:setTitle("CHESS NETWORK")

local running = true
local phase = "menu"
local role = nil
local localColor = nil
local remoteAddress = nil
local connectionId = nil
local connectRequestId = nil
local listenRequestId = nil
local listening = false
local gameId = nil
local moveNo = 0
local promotionIndex = 1
local message = "Choose HOST or JOIN."
local targetId = os.getComputerID() + 1
local menuIndex = 1

local menuActions = {"host", "join", "back"}

local function resetColors()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function line(y, text, color, x, maxWidth)
    x = x or 2
    maxWidth = maxWidth or (width - x)
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

local function button(id, label, x, y, w, bg, fg)
    return Button.new({
        id = id,
        label = label,
        x = x,
        y = y,
        width = w,
        height = 1,
        backgroundColor = bg,
        textColor = fg or colors.white
    })
end

local hostButton = button("host", "Host Game", 12, 7, 28, colors.blue)
local joinButton = button("join", "Join Target", 12, 10, 28, colors.green, colors.black)
local menuBackButton = button("back", "Back", 12, 13, 28, colors.red)
local idMinusButton = button("idminus", "ID -", 12, 5, 8, colors.gray)
local idPlusButton = button("idplus", "ID +", 32, 5, 8, colors.gray)
local waitBackButton = button("cancel", "Cancel / Back", 17, 14, 18, colors.red)

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
    Button.new({id="queen", label="Queen", x=35, y=9, width=8, height=1, backgroundColor=colors.gray}),
    Button.new({id="rook", label="Rook", x=44, y=9, width=8, height=1, backgroundColor=colors.gray}),
    Button.new({id="bishop", label="Bishop", x=35, y=11, width=8, height=1, backgroundColor=colors.gray}),
    Button.new({id="knight", label="Knight", x=44, y=11, width=8, height=1, backgroundColor=colors.gray})
}

local controls = {
    restart = restartButton,
    back = backButton,
    promotions = promotionButtons
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
    drawHeader("CHESS MULTIPLAYER", colors.purple)

    line(4, "LOCAL: " .. tostring(Address.localAddress() or "NO CCIP"), colors.cyan)
    line(5, "TARGET #" .. tostring(targetId) .. "  " .. targetAddress(), colors.yellow, 21, 30)

    hostButton:setSelected(menuIndex == 1)
    joinButton:setSelected(menuIndex == 2)
    menuBackButton:setSelected(menuIndex == 3)

    idMinusButton:draw(term)
    idPlusButton:draw(term)
    hostButton:draw(term)
    joinButton:draw(term)
    menuBackButton:draw(term)

    line(15, "HOST = White. JOIN = Black. Port " .. tostring(ChessNet.PORT), colors.lightGray)
    line(16, "Routed games work when CCIP route + CCTP firewall allow them.", colors.lightGray)
    line(17, message, colors.gray)

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))
    local footer = "LEFT/RIGHT target  UP/DOWN option  ENTER  SHIFT back"
    term.setCursorPos(math.max(1, math.floor((width - #footer) / 2) + 1), height)
    term.write(footer:sub(1, width))
    resetColors()
end

local function drawWaiting()
    resetColors()
    term.clear()
    drawHeader("CHESS NETWORK LOBBY", colors.blue)

    line(5, "ROLE: " .. tostring(role or "-"):upper(), colors.cyan)
    line(7, "LOCAL: " .. tostring(Address.localAddress() or "NO CCIP"), colors.white)
    line(8, "REMOTE: " .. tostring(remoteAddress or targetAddress()), colors.white)
    line(10, "STATE: " .. tostring(phase):upper(), colors.yellow)
    line(12, message, colors.lightGray)
    waitBackButton:draw(term)
    line(16, "CCTP reliable session / synchronized chess state", colors.gray)

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))
    local footer = "SHIFT or button = cancel/back"
    term.setCursorPos(math.max(1, math.floor((width - #footer) / 2) + 1), height)
    term.write(footer)
    resetColors()
end

local function syncPromotionSelection()
    for index, promotionButton in ipairs(promotionButtons) do
        promotionButton:setSelected(
            game.promotionPending ~= nil and index == promotionIndex
        )
    end
end

local function drawGame()
    syncPromotionSelection()
    renderer:setFlipped(localColor == Pieces.BLACK)
    renderer:setNetworkInfo({
        localColor = localColor or "?",
        state = phase == "playing" and "ONLINE" or phase,
        connected = connectionId ~= nil and phase == "playing",
        moveNo = moveNo
    })
    renderer:draw(game, controls)

    if message ~= "" then
        line(17, message, colors.gray, 36, 15)
    end
end

local function redraw()
    if phase == "menu" then
        drawMenu()
    elseif phase == "playing" or phase == "disconnected" then
        drawGame()
    else
        drawWaiting()
    end
end

local function closeConnection()
    if connectionId then
        CCTP.close(connectionId)
        connectionId = nil
    end
end

local function stopListening()
    if listening or listenRequestId then
        ChessNet.unlisten()
        listening = false
        listenRequestId = nil
    end
end

local function resetSession()
    closeConnection()
    stopListening()
    role = nil
    localColor = nil
    remoteAddress = nil
    connectionId = nil
    connectRequestId = nil
    gameId = nil
    moveNo = 0
    promotionIndex = 1
    game:restart()
    renderer:setFlipped(false)
    phase = "menu"
    message = "Choose HOST or JOIN."
end

local function sendMessage(messageType, payload)
    if not connectionId or not gameId then
        return false, "no_game_connection"
    end

    local requestId, err = ChessNet.send(
        connectionId,
        messageType,
        gameId,
        payload
    )

    if not requestId then
        return false, err
    end

    return true, requestId
end

local function sendSync(reason)
    if role ~= "host" or not connectionId or not gameId then
        return false
    end

    local snapshot = game:exportState()
    local hash = game:positionSignature()

    sendMessage(ChessNet.TYPE_SYNC, {
        moveNo = moveNo,
        snapshot = snapshot,
        hash = hash,
        reason = reason or "authoritative_sync"
    })

    return true
end

local function requestSync(reason)
    if role == "host" then
        return sendSync(reason)
    end

    return sendMessage(ChessNet.TYPE_SYNC_REQUEST, {
        moveNo = moveNo,
        hash = game:positionSignature(),
        reason = reason or "state_mismatch"
    })
end

local function beginHost()
    resetSession()
    role = "host"
    localColor = Pieces.WHITE
    gameId = ChessNet.newGameId()
    listenRequestId = ChessNet.listen()

    if not listenRequestId then
        phase = "menu"
        message = "Failed to request CCTP listener."
        return
    end

    phase = "hosting"
    message = "Opening port " .. tostring(ChessNet.PORT) .. "..."
end

local function beginJoin()
    local address = targetAddress()

    if address == "INVALID" or targetId == os.getComputerID() then
        message = "Choose another valid Computer ID."
        return
    end

    resetSession()
    role = "client"
    localColor = Pieces.BLACK
    remoteAddress = address
    connectRequestId = ChessNet.connect(address)

    if not connectRequestId then
        phase = "menu"
        message = "Failed to queue CCTP connection."
        return
    end

    phase = "joining"
    message = "Connecting to " .. address .. ":" .. tostring(ChessNet.PORT) .. "..."
end

local function startHostGame()
    game:restart()
    moveNo = 0
    phase = "playing"
    message = "Connected. You are WHITE."

    sendMessage(ChessNet.TYPE_START, {
        hostColor = Pieces.WHITE,
        guestColor = Pieces.BLACK,
        moveNo = moveNo,
        snapshot = game:exportState(),
        hash = game:positionSignature()
    })
end

local function importAuthoritative(payload)
    if type(payload) ~= "table" or type(payload.snapshot) ~= "table" then
        return false, "sync_missing_snapshot"
    end

    local ok, err = game:importState(payload.snapshot)

    if not ok then
        return false, err
    end

    moveNo = math.max(0, math.floor(tonumber(payload.moveNo) or 0))
    local expected = tostring(payload.hash or "")

    if expected ~= "" and expected ~= game:positionSignature() then
        return false, "sync_hash_mismatch"
    end

    promotionIndex = 1
    return true
end

local function handleRemoteMove(payload)
    if type(payload) ~= "table" then
        requestSync("bad_move_payload")
        return false
    end

    local expectedMove = moveNo + 1

    if tonumber(payload.moveNo) ~= expectedMove then
        requestSync("move_number_mismatch")
        return false
    end

    local currentHash = game:positionSignature()

    if payload.beforeHash ~= currentHash then
        requestSync("pre_move_hash_mismatch")
        return false
    end

    if game:getTurn() == localColor then
        requestSync("remote_moved_on_local_turn")
        return false
    end

    local ok, err = game:applyMoveCoordinates(
        tonumber(payload.fromX),
        tonumber(payload.fromY),
        tonumber(payload.toX),
        tonumber(payload.toY),
        payload.promotion
    )

    if not ok then
        requestSync("illegal_remote_move:" .. tostring(err))
        return false
    end

    moveNo = expectedMove

    if payload.afterHash ~= game:positionSignature() then
        requestSync("post_move_hash_mismatch")
        return false
    end

    message = "Opponent moved."
    return true
end

local function sendCompletedLocalMove(beforeHash)
    local move = game.lastMove

    if not move then
        return false
    end

    moveNo = moveNo + 1
    local ok, err = sendMessage(ChessNet.TYPE_MOVE, {
        moveNo = moveNo,
        fromX = move.fromX,
        fromY = move.fromY,
        toX = move.toX,
        toY = move.toY,
        promotion = game.lastPromotion,
        beforeHash = beforeHash,
        afterHash = game:positionSignature()
    })

    if not ok then
        message = "Move send failed: " .. tostring(err)
        return false
    end

    message = "Move sent."
    return true
end

local function restartNetworkGame()
    if role == "host" then
        game:restart()
        moveNo = 0
        promotionIndex = 1
        sendSync("new_game")
        message = "New game started."
    else
        sendMessage(ChessNet.TYPE_NEW_GAME_REQUEST, {
            moveNo = moveNo
        })
        message = "New game requested from host."
    end
end

local function localInputAllowed()
    return phase == "playing" and
        connectionId ~= nil and
        game.status == "playing" and
        game:getTurn() == localColor
end

local function choosePromotion(index)
    if not localInputAllowed() or not game.promotionPending then
        return false
    end

    index = math.max(1, math.min(#promotionKinds, index))
    local beforeHash = game:positionSignature()
    local oldMove = game.lastMove

    if game:choosePromotion(promotionKinds[index]) then
        promotionIndex = 1

        if game.lastMove ~= oldMove then
            sendCompletedLocalMove(beforeHash)
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

local function handleBoardClick(x, y)
    if not localInputAllowed() then
        message = game.status ~= "playing" and "Game finished. Use New Game." or "Wait for your turn."
        return true
    end

    local boardX, boardY = renderer:screenToSquare(x, y)

    if not boardX then
        return false
    end

    local beforeHash = game:positionSignature()
    local oldMove = game.lastMove
    local result = game:clickSquare(boardX, boardY)

    if result == "promotion" then
        promotionIndex = 1
    elseif game.lastMove ~= oldMove then
        sendCompletedLocalMove(beforeHash)
    end

    return true
end

local function handleGameMouse(buttonValue, x, y)
    if buttonValue ~= 1 and buttonValue ~= 0 then
        return false
    end

    if backButton:contains(x, y) then
        resetSession()
        return true
    end

    if restartButton:contains(x, y) then
        restartNetworkGame()
        return true
    end

    if game.promotionPending then
        for index, promotionButton in ipairs(promotionButtons) do
            if promotionButton:contains(x, y) then
                promotionIndex = index
                choosePromotion(index)
                return true
            end
        end

        return false
    end

    return handleBoardClick(x, y)
end

local function handleGameKey(key)
    if key == keys.leftShift then
        resetSession()
        return true
    end

    if key == keys.leftCtrl then
        restartNetworkGame()
        return true
    end

    if not localInputAllowed() then
        message = game.status ~= "playing" and "Game finished. Use New Game." or "Wait for your turn."
        return true
    end

    if game.promotionPending then
        if key == keys.enter then
            choosePromotion(promotionIndex)
            return true
        elseif key == keys.left or key == keys.right or key == keys.up or key == keys.down then
            movePromotionCursor(key)
            return true
        end

        return false
    end

    if key == keys.left then
        game:moveCursor(-1, 0)
    elseif key == keys.right then
        game:moveCursor(1, 0)
    elseif key == keys.up then
        game:moveCursor(0, -1)
    elseif key == keys.down then
        game:moveCursor(0, 1)
    elseif key == keys.enter then
        local beforeHash = game:positionSignature()
        local oldMove = game.lastMove
        local result = game:selectSquare(game.cursorX, game.cursorY)

        if result == "promotion" then
            promotionIndex = 1
        elseif game.lastMove ~= oldMove then
            sendCompletedLocalMove(beforeHash)
        end
    else
        return false
    end

    return true
end

local function handleNetworkMessage(connId, payload, source)
    if connId ~= connectionId then
        return false
    end

    local valid, reason = ChessNet.validate(payload)

    if not valid then
        message = "Rejected chess packet: " .. tostring(reason)
        return true
    end

    if gameId and payload.gameId ~= gameId then
        message = "Rejected foreign game session."
        return true
    end

    if role == "client" and payload.type == ChessNet.TYPE_HELLO then
        gameId = payload.gameId
        remoteAddress = source or remoteAddress
        localColor = payload.payload.guestColor == Pieces.WHITE and Pieces.WHITE or Pieces.BLACK
        phase = "handshake"
        sendMessage(ChessNet.TYPE_READY, {
            clientId = os.getComputerID(),
            color = localColor
        })
        message = "Handshake complete; waiting for START..."
        return true
    end

    if not gameId or payload.gameId ~= gameId then
        return true
    end

    if role == "host" and payload.type == ChessNet.TYPE_READY then
        startHostGame()
        return true
    end

    if role == "client" and payload.type == ChessNet.TYPE_START then
        local ok, err = importAuthoritative(payload.payload)

        if ok then
            phase = "playing"
            message = "Connected. You are " .. tostring(localColor):upper() .. "."
        else
            message = "START sync failed: " .. tostring(err)
            requestSync("start_import_failed")
        end

        return true
    end

    if payload.type == ChessNet.TYPE_MOVE and phase == "playing" then
        handleRemoteMove(payload.payload)
        return true
    end

    if payload.type == ChessNet.TYPE_SYNC_REQUEST and role == "host" then
        sendSync(payload.payload.reason or "peer_requested")
        message = "Authoritative state sync sent."
        return true
    end

    if payload.type == ChessNet.TYPE_SYNC and role == "client" then
        local ok, err = importAuthoritative(payload.payload)

        if ok then
            phase = "playing"
            message = "Game state synchronized."
        else
            message = "State sync failed: " .. tostring(err)
        end

        return true
    end

    if payload.type == ChessNet.TYPE_NEW_GAME_REQUEST and role == "host" then
        game:restart()
        moveNo = 0
        promotionIndex = 1
        sendSync("new_game")
        message = "Opponent requested a new game."
        return true
    end

    return true
end

redraw()

while running do
    local event, a, b, c, d, e, f = os.pullEvent()
    local redrawNeeded = false

    if event == "mouse_click" and (a == 1 or a == 0) then
        if phase == "menu" then
            if idMinusButton:contains(b, c) then
                targetId = math.max(0, targetId - 1)
                redrawNeeded = true
            elseif idPlusButton:contains(b, c) then
                targetId = targetId + 1
                redrawNeeded = true
            elseif hostButton:contains(b, c) then
                beginHost()
                redrawNeeded = true
            elseif joinButton:contains(b, c) then
                beginJoin()
                redrawNeeded = true
            elseif menuBackButton:contains(b, c) then
                running = false
            end
        elseif phase == "playing" or phase == "disconnected" then
            redrawNeeded = handleGameMouse(a, b, c)
        elseif waitBackButton:contains(b, c) then
            resetSession()
            redrawNeeded = true
        end

    elseif event == "key" then
        if phase == "menu" then
            if a == keys.leftShift then
                running = false
            elseif a == keys.left then
                targetId = math.max(0, targetId - 1)
                redrawNeeded = true
            elseif a == keys.right then
                targetId = targetId + 1
                redrawNeeded = true
            elseif a == keys.up then
                menuIndex = menuIndex - 1
                if menuIndex < 1 then menuIndex = #menuActions end
                redrawNeeded = true
            elseif a == keys.down then
                menuIndex = menuIndex + 1
                if menuIndex > #menuActions then menuIndex = 1 end
                redrawNeeded = true
            elseif a == keys.enter then
                local action = menuActions[menuIndex]
                if action == "host" then beginHost()
                elseif action == "join" then beginJoin()
                else running = false end
                redrawNeeded = true
            end
        elseif phase == "playing" or phase == "disconnected" then
            redrawNeeded = handleGameKey(a)
        elseif a == keys.leftShift then
            resetSession()
            redrawNeeded = true
        end

    elseif event == "ccbase_cctp_listen_result" and listenRequestId and a == listenRequestId then
        if b == true then
            listening = true
            phase = "hosting"
            message = "Hosting on " .. tostring(Address.localAddress()) .. ":" .. tostring(ChessNet.PORT) .. "."
        else
            phase = "menu"
            listenRequestId = nil
            message = "Listen failed: " .. tostring(c)
        end
        redrawNeeded = true

    elseif event == "ccbase_cctp_accept" and role == "host" and a == ChessNet.LISTENER_ID then
        if connectionId then
            CCTP.close(b)
        else
            connectionId = b
            remoteAddress = c
            phase = "handshake"
            sendMessage(ChessNet.TYPE_HELLO, {
                hostId = os.getComputerID(),
                hostColor = Pieces.WHITE,
                guestColor = Pieces.BLACK,
                protocol = ChessNet.VERSION
            })
            message = "Peer connected; waiting READY..."
        end
        redrawNeeded = true

    elseif event == "ccbase_cctp_connect_result" and connectRequestId and a == connectRequestId then
        if b == true then
            connectionId = c
            remoteAddress = d or remoteAddress
            phase = "handshake"
            message = "CCTP connected; waiting host HELLO..."
        else
            phase = "menu"
            connectRequestId = nil
            message = "Connect failed: " .. tostring(c)
        end
        redrawNeeded = true

    elseif event == "ccbase_cctp_receive" then
        redrawNeeded = handleNetworkMessage(a, b, c) or redrawNeeded

    elseif event == "ccbase_cctp_closed" and a == connectionId then
        connectionId = nil
        phase = "disconnected"
        message = "Connection closed: " .. tostring(b) .. ". SHIFT = back."
        redrawNeeded = true

    elseif event == "ccbase_cctp_send_result" and b == false and d == connectionId then
        message = "CCTP send failed: " .. tostring(c)
        redrawNeeded = true

    elseif event == "term_resize" then
        local newWidth, newHeight = term.getSize()

        if newWidth < 51 or newHeight < 19 then
            running = false
        else
            redrawNeeded = true
        end
    end

    if redrawNeeded and running then
        redraw()
    end
end

closeConnection()
stopListening()
resetColors()
term.clear()
term.setCursorPos(1, 1)
print("Network Chess closed.")
