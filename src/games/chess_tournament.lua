local Game = require("chess.game")
local Renderer = require("chess.renderer")
local Pieces = require("chess.pieces")
local ChessNet = require("chess.network")
local Tournament = require("chess.tournament")
local Displays = require("chess.displays")
local DisplayMenu = require("chess.display_menu")
local Address = require("lib.net.address")
local CCTP = require("lib.net.cctp")
local Button = require("lib.gui.button")

local width, height = term.getSize()

if width < 51 or height < 19 then
    error("Terminal is too small for Tournament Chess (need at least 51x19)")
end

local game = Game.new()
local renderer = Renderer.new(term)
local displays = Displays.new()
local displayMenu = DisplayMenu.new(term, displays)
local tournament = Tournament.new({
    whiteName = Tournament.computerName(),
    blackName = "Waiting"
})

renderer:setTitle("CHESS TOURNAMENT")

local running = true
local phase = "menu"
local role = nil
local localColor = nil
local remoteAddress = nil
local connectionId = nil
local connectRequestId = nil
local playerListenRequestId = nil
local spectatorListenRequestId = nil
local playerListening = false
local spectatorListening = false
local spectators = {}
local gameId = nil
local moveNo = 0
local promotionIndex = 1
local message = "Choose HOST or JOIN. 10 minute tournament clock."
local targetId = os.getComputerID() + 1
local menuIndex = 1
local clockTimer = os.startTimer(1)

local menuActions = {"host", "join", "back"}

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

local hostButton = makeButton("host", "Host Tournament", 12, 7, 28, colors.blue)
local joinButton = makeButton("join", "Join Tournament", 12, 10, 28, colors.green, colors.black)
local menuBackButton = makeButton("back", "Back", 12, 13, 28, colors.red)
local idMinusButton = makeButton("idminus", "ID -", 12, 5, 8, colors.gray)
local idPlusButton = makeButton("idplus", "ID +", 32, 5, 8, colors.gray)
local waitBackButton = makeButton("cancel", "Cancel / Back", 17, 14, 18, colors.red)

local restartButton = makeButton("restart", "Next Game", 36, 14, 15, colors.blue)
local displayButton = makeButton("displays", "Displays", 36, 15, 15, colors.purple)
local backButton = makeButton("back", "Back", 36, 16, 15, colors.red)

local promotionKinds = {"queen", "rook", "bishop", "knight"}
local promotionButtons = {
    makeButton("queen", "Queen", 35, 9, 8, colors.gray),
    makeButton("rook", "Rook", 44, 9, 8, colors.gray),
    makeButton("bishop", "Bishop", 35, 11, 8, colors.gray),
    makeButton("knight", "Knight", 44, 11, 8, colors.gray)
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
    drawHeader("CHESS TOURNAMENT", colors.purple)

    line(4, "LOCAL: " .. tostring(Address.localAddress() or "NO CCIP"), colors.cyan)
    line(5, "TARGET #" .. tostring(targetId) .. " " .. targetAddress(), colors.yellow, 21, 30)

    hostButton:setSelected(menuIndex == 1)
    joinButton:setSelected(menuIndex == 2)
    menuBackButton:setSelected(menuIndex == 3)

    idMinusButton:draw(term)
    idPlusButton:draw(term)
    hostButton:draw(term)
    joinButton:draw(term)
    menuBackButton:draw(term)

    line(15, "10:00 clocks | score persists across Next Game", colors.lightGray)
    line(16, "Spectators connect on CCTP port " .. tostring(ChessNet.SPECTATOR_PORT), colors.lightGray)
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
    drawHeader("TOURNAMENT LOBBY", colors.blue)

    line(5, "ROLE: " .. tostring(role or "-"):upper(), colors.cyan)
    line(7, "LOCAL: " .. tostring(Address.localAddress() or "NO CCIP"), colors.white)
    line(8, "REMOTE: " .. tostring(remoteAddress or targetAddress()), colors.white)
    line(9, "SPECTATORS: " .. tostring((function()
        local count = 0
        for _ in pairs(spectators) do count = count + 1 end
        return count
    end)()), colors.lightGray)
    line(10, "STATE: " .. tostring(phase):upper(), colors.yellow)
    line(12, message, colors.lightGray)
    waitBackButton:draw(term)
    line(16, "Host is authoritative for clocks, score and spectator state.", colors.gray)

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

local function tournamentState()
    return tournament:export()
end

local function renderMonitors()
    displays:render(game, {
        mode = "NETWORK",
        title = "CHESS TOURNAMENT",
        moveNo = moveNo,
        networkState = phase == "playing" and "ONLINE" or phase:upper(),
        tournament = tournamentState()
    })
end

local function drawGame()
    syncPromotionSelection()
    renderer:setFlipped(localColor == Pieces.BLACK)
    renderer:setNetworkInfo({
        localColor = localColor or "?",
        state = phase == "playing" and "ONLINE" or phase,
        connected = connectionId ~= nil and phase == "playing",
        moveNo = moveNo,
        tournament = tournamentState()
    })
    renderer:draw(game, controls)
    displayButton:draw(term)

    if message ~= "" then
        line(17, message, colors.gray, 36, 15)
    end
end

local function redraw()
    if displayMenu:isOpen() then
        displayMenu:draw()
    elseif phase == "menu" then
        drawMenu()
    elseif phase == "playing" or phase == "disconnected" then
        drawGame()
    else
        drawWaiting()
    end

    if phase == "playing" or phase == "disconnected" then
        renderMonitors()
    else
        displays:clearOutputs()
    end
end

local function closeConnection(id)
    if id then
        CCTP.close(id)
    end
end

local function closePlayerConnection()
    if connectionId then
        closeConnection(connectionId)
        connectionId = nil
    end
end

local function closeSpectators()
    local ids = {}

    for id in pairs(spectators) do
        table.insert(ids, id)
    end

    spectators = {}

    for _, id in ipairs(ids) do
        closeConnection(id)
    end
end

local function stopListening()
    if playerListening or playerListenRequestId then
        ChessNet.unlisten()
    end

    if spectatorListening or spectatorListenRequestId then
        ChessNet.unlistenSpectators()
    end

    playerListening = false
    spectatorListening = false
    playerListenRequestId = nil
    spectatorListenRequestId = nil
end

local function resetSession()
    displayMenu:close()
    closePlayerConnection()
    closeSpectators()
    stopListening()
    role = nil
    localColor = nil
    remoteAddress = nil
    connectRequestId = nil
    gameId = nil
    moveNo = 0
    promotionIndex = 1
    game:restart()
    tournament = Tournament.new({
        whiteName = Tournament.computerName(),
        blackName = "Waiting"
    })
    renderer:setFlipped(false)
    phase = "menu"
    message = "Choose HOST or JOIN. 10 minute tournament clock."
    displays:clearOutputs()
end

local function sendPlayer(messageType, payload)
    if not connectionId or not gameId then
        return false, "no_player_connection"
    end

    local requestId, err = ChessNet.send(connectionId, messageType, gameId, payload)

    if not requestId then
        return false, err
    end

    return true, requestId
end

local function sendSpectator(id, messageType, payload)
    if not id or not gameId then
        return false
    end

    local requestId = ChessNet.send(id, messageType, gameId, payload)
    return requestId ~= nil
end

local function spectatorPayload(reason)
    return {
        moveNo = moveNo,
        snapshot = game:exportState(),
        hash = game:positionSignature(),
        tournament = tournamentState(),
        phase = phase,
        reason = reason or "state"
    }
end

local function broadcastSpectatorState(reason)
    local payload = spectatorPayload(reason)

    for id in pairs(spectators) do
        sendSpectator(id, ChessNet.TYPE_SPECTATOR_STATE, payload)
    end
end

local function sendTournamentState()
    if role ~= "host" then
        return
    end

    if connectionId then
        sendPlayer(ChessNet.TYPE_TOURNAMENT, {
            tournament = tournamentState(),
            moveNo = moveNo
        })
    end

    for id in pairs(spectators) do
        sendSpectator(id, ChessNet.TYPE_TOURNAMENT, {
            tournament = tournamentState(),
            moveNo = moveNo
        })
    end
end

local function sendSync(reason)
    if role ~= "host" or not connectionId or not gameId then
        return false
    end

    sendPlayer(ChessNet.TYPE_SYNC, {
        moveNo = moveNo,
        snapshot = game:exportState(),
        hash = game:positionSignature(),
        tournament = tournamentState(),
        reason = reason or "authoritative_sync"
    })

    broadcastSpectatorState(reason or "sync")
    return true
end

local function requestSync(reason)
    if role == "host" then
        return sendSync(reason)
    end

    return sendPlayer(ChessNet.TYPE_SYNC_REQUEST, {
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
    tournament:setNames(Tournament.computerName(), "Waiting")
    playerListenRequestId = ChessNet.listen()
    spectatorListenRequestId = ChessNet.listenSpectators()

    if not playerListenRequestId then
        phase = "menu"
        message = "Failed to request player listener."
        return
    end

    phase = "hosting"
    message = "Opening player and spectator ports..."
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
    tournament:setNames("Host", Tournament.computerName())
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
    tournament:startGame(false)
    phase = "playing"
    message = "Tournament started. You are WHITE."

    sendPlayer(ChessNet.TYPE_START, {
        hostColor = Pieces.WHITE,
        guestColor = Pieces.BLACK,
        moveNo = moveNo,
        snapshot = game:exportState(),
        hash = game:positionSignature(),
        tournament = tournamentState()
    })

    broadcastSpectatorState("start")
end

local function startNextGame(reason)
    if role ~= "host" then
        return false
    end

    game:restart()
    moveNo = 0
    promotionIndex = 1
    tournament:startGame(true)
    phase = "playing"
    sendSync(reason or "next_game")
    sendTournamentState()
    message = "Game #" .. tostring(tournament.gameNo) .. " started."
    return true
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

    if type(payload.tournament) == "table" then
        tournament:import(payload.tournament)
    end

    promotionIndex = 1
    return true
end

local function hostAfterMove()
    if role ~= "host" then
        return
    end

    tournament:afterMove(game)
    sendTournamentState()
    broadcastSpectatorState("move")
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

    if payload.beforeHash ~= game:positionSignature() then
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

    if role == "host" then
        hostAfterMove()
    elseif type(payload.tournament) == "table" then
        tournament:import(payload.tournament)
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

    if role == "host" then
        tournament:afterMove(game)
    end

    local ok, err = sendPlayer(ChessNet.TYPE_MOVE, {
        moveNo = moveNo,
        fromX = move.fromX,
        fromY = move.fromY,
        toX = move.toX,
        toY = move.toY,
        promotion = game.lastPromotion,
        beforeHash = beforeHash,
        afterHash = game:positionSignature(),
        tournament = role == "host" and tournamentState() or nil
    })

    if not ok then
        message = "Move send failed: " .. tostring(err)
        return false
    end

    if role == "host" then
        sendTournamentState()
        broadcastSpectatorState("move")
    end

    message = "Move sent."
    return true
end

local function restartNetworkGame()
    if role == "host" then
        startNextGame("host_next_game")
    else
        sendPlayer(ChessNet.TYPE_NEW_GAME_REQUEST, {
            moveNo = moveNo,
            gameNo = tournament.gameNo
        })
        message = "Next game requested from host."
    end
end

local function localInputAllowed()
    return phase == "playing" and
        connectionId ~= nil and
        game.status == "playing" and
        not tournament.finished and
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
        message = tournament.finished and "Game finished. Use Next Game." or "Wait for your turn."
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

    if displayButton:contains(x, y) then
        displayMenu:open()
        return true
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
        message = tournament.finished and "Game finished. Use Next Game." or "Wait for your turn."
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

local function handlePlayerMessage(connId, payload, source)
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
        localColor = Pieces.BLACK
        tournament:setNames(payload.payload.hostName or "Host", Tournament.computerName())
        phase = "handshake"
        sendPlayer(ChessNet.TYPE_READY, {
            clientId = os.getComputerID(),
            clientName = Tournament.computerName(),
            color = localColor
        })
        message = "Handshake complete; waiting for START..."
        return true
    end

    if not gameId or payload.gameId ~= gameId then
        return true
    end

    if role == "host" and payload.type == ChessNet.TYPE_READY then
        tournament:setNames(nil, payload.payload.clientName or "Guest")
        startHostGame()
        return true
    end

    if role == "client" and payload.type == ChessNet.TYPE_START then
        local ok, err = importAuthoritative(payload.payload)

        if ok then
            phase = "playing"
            message = "Tournament started. You are BLACK."
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
            message = "Tournament state synchronized."
        else
            message = "State sync failed: " .. tostring(err)
        end

        return true
    end

    if payload.type == ChessNet.TYPE_TOURNAMENT and role == "client" then
        if type(payload.payload.tournament) == "table" then
            tournament:import(payload.payload.tournament)
        end
        return true
    end

    if payload.type == ChessNet.TYPE_NEW_GAME_REQUEST and role == "host" then
        startNextGame("guest_next_game_request")
        message = "Opponent requested game #" .. tostring(tournament.gameNo) .. "."
        return true
    end

    return true
end

local function acceptSpectator(connId, source)
    if role ~= "host" or not gameId then
        closeConnection(connId)
        return false
    end

    spectators[connId] = {
        address = source,
        connectedAt = os.epoch and os.epoch("utc") or 0
    }

    sendSpectator(connId, ChessNet.TYPE_SPECTATOR_HELLO, spectatorPayload("spectator_join"))
    message = "Spectator connected from " .. tostring(source) .. "."
    return true
end

redraw()

while running do
    local event, a, b, c, d, e, f = os.pullEvent()
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
                    if action == "host" then
                        beginHost()
                    elseif action == "join" then
                        beginJoin()
                    else
                        running = false
                    end
                    redrawNeeded = true
                end
            elseif phase == "playing" or phase == "disconnected" then
                redrawNeeded = handleGameKey(a)
            elseif a == keys.leftShift then
                resetSession()
                redrawNeeded = true
            end

        elseif event == "ccbase_cctp_listen_result" then
            if playerListenRequestId and a == playerListenRequestId then
                if b == true then
                    playerListening = true
                    message = "Player port open. Waiting opponent..."
                else
                    phase = "menu"
                    message = "Player listen failed: " .. tostring(c)
                end
                playerListenRequestId = nil
                redrawNeeded = true
            elseif spectatorListenRequestId and a == spectatorListenRequestId then
                if b == true then
                    spectatorListening = true
                else
                    message = "Spectator port failed: " .. tostring(c)
                end
                spectatorListenRequestId = nil
                redrawNeeded = true
            end

        elseif event == "ccbase_cctp_accept" and role == "host" then
            if a == ChessNet.LISTENER_ID then
                if connectionId then
                    closeConnection(b)
                else
                    connectionId = b
                    remoteAddress = c
                    phase = "handshake"
                    sendPlayer(ChessNet.TYPE_HELLO, {
                        hostId = os.getComputerID(),
                        hostName = Tournament.computerName(),
                        hostColor = Pieces.WHITE,
                        guestColor = Pieces.BLACK,
                        protocol = ChessNet.VERSION,
                        timeControlMs = tournament.timeControlMs
                    })
                    message = "Player connected; waiting READY..."
                end
                redrawNeeded = true
            elseif a == ChessNet.SPECTATOR_LISTENER_ID then
                acceptSpectator(b, c)
                redrawNeeded = true
            end

        elseif event == "ccbase_cctp_connect_result" and connectRequestId and a == connectRequestId then
            if b == true then
                connectionId = c
                remoteAddress = d or remoteAddress
                phase = "handshake"
                message = "CCTP connected; waiting host HELLO..."
            else
                phase = "menu"
                message = "Connect failed: " .. tostring(c)
            end
            connectRequestId = nil
            redrawNeeded = true

        elseif event == "ccbase_cctp_receive" then
            redrawNeeded = handlePlayerMessage(a, b, c) or redrawNeeded

        elseif event == "ccbase_cctp_closed" then
            if a == connectionId then
                connectionId = nil
                phase = "disconnected"
                tournament.running = false
                message = "Player connection closed: " .. tostring(b) .. "."
                redrawNeeded = true
            elseif spectators[a] then
                spectators[a] = nil
                redrawNeeded = true
            end

        elseif event == "ccbase_cctp_send_result" and b == false then
            if d == connectionId then
                message = "CCTP send failed: " .. tostring(c)
                redrawNeeded = true
            elseif spectators[d] then
                spectators[d] = nil
                redrawNeeded = true
            end

        elseif event == "timer" and a == clockTimer then
            if role == "host" and phase == "playing" then
                local wasFinished = tournament.finished
                tournament:tick()
                sendTournamentState()

                if tournament.finished and not wasFinished then
                    broadcastSpectatorState("timeout")
                    message = "Clock expired. " .. tostring(tournament.winner or "?"):upper() .. " wins."
                end

                redrawNeeded = true
            end

            clockTimer = os.startTimer(1)

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

closePlayerConnection()
closeSpectators()
stopListening()
displays:clearOutputs()
resetColors()
term.clear()
term.setCursorPos(1, 1)
print("Tournament Chess closed.")
