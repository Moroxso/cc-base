local CCTP = require("lib.net.cctp")
local Protocol = require("lib.net.protocol")

local ChessNet = {}

ChessNet.VERSION = 2
ChessNet.APP = "ccbase.chess"
ChessNet.PORT = 3200
ChessNet.SPECTATOR_PORT = 3201
ChessNet.LISTENER_ID = "chess-multiplayer"
ChessNet.SPECTATOR_LISTENER_ID = "chess-spectator"

ChessNet.TYPE_HELLO = "hello"
ChessNet.TYPE_READY = "ready"
ChessNet.TYPE_START = "start"
ChessNet.TYPE_MOVE = "move"
ChessNet.TYPE_SYNC_REQUEST = "sync_request"
ChessNet.TYPE_SYNC = "sync"
ChessNet.TYPE_NEW_GAME_REQUEST = "new_game_request"
ChessNet.TYPE_TOURNAMENT = "tournament"
ChessNet.TYPE_SPECTATOR_HELLO = "spectator_hello"
ChessNet.TYPE_SPECTATOR_STATE = "spectator_state"

local VALID_TYPES = {
    hello = true,
    ready = true,
    start = true,
    move = true,
    sync_request = true,
    sync = true,
    new_game_request = true,
    tournament = true,
    spectator_hello = true,
    spectator_state = true
}

local sequence = 0

local function nextId(prefix)
    sequence = sequence + 1

    return string.format(
        "%s:%d:%d:%d",
        prefix,
        os.getComputerID(),
        Protocol.nowMs(),
        sequence
    )
end

function ChessNet.newGameId()
    return string.format(
        "chess:%d:%d:%06d",
        os.getComputerID(),
        Protocol.nowMs(),
        math.random(0, 999999)
    )
end

function ChessNet.message(messageType, gameId, payload)
    if not VALID_TYPES[messageType] then
        return nil, "chess_net_bad_type"
    end

    if type(gameId) ~= "string" or gameId == "" then
        return nil, "chess_net_bad_game_id"
    end

    return {
        app = ChessNet.APP,
        version = ChessNet.VERSION,
        type = messageType,
        gameId = gameId,
        messageId = nextId("chess-msg"),
        sentAt = Protocol.nowMs(),
        payload = type(payload) == "table" and payload or {}
    }
end

function ChessNet.validate(message)
    if type(message) ~= "table" then
        return false, "chess_net_not_table"
    end

    if message.app ~= ChessNet.APP or message.version ~= ChessNet.VERSION then
        return false, "chess_net_version_or_app"
    end

    if not VALID_TYPES[message.type] then
        return false, "chess_net_bad_type"
    end

    if type(message.gameId) ~= "string" or message.gameId == "" or #message.gameId > 128 then
        return false, "chess_net_bad_game_id"
    end

    if type(message.messageId) ~= "string" or message.messageId == "" or #message.messageId > 160 then
        return false, "chess_net_bad_message_id"
    end

    if type(message.payload) ~= "table" then
        return false, "chess_net_bad_payload"
    end

    return true
end

function ChessNet.send(connectionId, messageType, gameId, payload)
    local message, err = ChessNet.message(messageType, gameId, payload)

    if not message then
        return nil, err
    end

    return CCTP.send(connectionId, message)
end

function ChessNet.listen()
    return CCTP.listen(ChessNet.PORT, ChessNet.LISTENER_ID)
end

function ChessNet.unlisten()
    return CCTP.unlisten(ChessNet.PORT, ChessNet.LISTENER_ID)
end

function ChessNet.listenSpectators()
    return CCTP.listen(
        ChessNet.SPECTATOR_PORT,
        ChessNet.SPECTATOR_LISTENER_ID
    )
end

function ChessNet.unlistenSpectators()
    return CCTP.unlisten(
        ChessNet.SPECTATOR_PORT,
        ChessNet.SPECTATOR_LISTENER_ID
    )
end

function ChessNet.connect(address)
    return CCTP.connect(address, ChessNet.PORT)
end

function ChessNet.connectSpectator(address)
    return CCTP.connect(address, ChessNet.SPECTATOR_PORT)
end

return ChessNet
