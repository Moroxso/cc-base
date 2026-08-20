local Pieces = require("chess.pieces")
local Protocol = require("lib.net.protocol")

local Tournament = {}
Tournament.__index = Tournament

Tournament.DEFAULT_CLOCK_MS = 10 * 60 * 1000

local function nowMs()
    return Protocol.nowMs()
end

local function cleanName(value, fallback)
    value = tostring(value or "")
    value = value:gsub("[%c]", " ")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")

    if value == "" then
        value = fallback or "PLAYER"
    end

    return value:sub(1, 20)
end

local function clampMs(value, maximum)
    value = math.floor(tonumber(value) or 0)
    return math.max(0, math.min(value, maximum))
end

function Tournament.computerName()
    local label = os.getComputerLabel()

    if label and tostring(label) ~= "" then
        return cleanName(label, "Computer")
    end

    return "Computer #" .. tostring(os.getComputerID())
end

function Tournament.formatClock(milliseconds)
    milliseconds = math.max(0, math.floor(tonumber(milliseconds) or 0))
    local totalSeconds = math.ceil(milliseconds / 1000)
    local minutes = math.floor(totalSeconds / 60)
    local seconds = totalSeconds % 60
    return string.format("%02d:%02d", minutes, seconds)
end

function Tournament.new(options)
    options = type(options) == "table" and options or {}

    local self = setmetatable({}, Tournament)
    self.timeControlMs = math.max(
        60 * 1000,
        math.floor(tonumber(options.timeControlMs) or Tournament.DEFAULT_CLOCK_MS)
    )
    self.whiteName = cleanName(options.whiteName, "WHITE")
    self.blackName = cleanName(options.blackName, "BLACK")
    self.whiteScore = 0
    self.blackScore = 0
    self.draws = 0
    self.gameNo = 1
    self.whiteMs = self.timeControlMs
    self.blackMs = self.timeControlMs
    self.activeColor = Pieces.WHITE
    self.running = false
    self.finished = false
    self.result = nil
    self.winner = nil
    self.lastTickAt = nowMs()
    self.resultRecorded = false

    return self
end

function Tournament:setNames(whiteName, blackName)
    if whiteName ~= nil then
        self.whiteName = cleanName(whiteName, self.whiteName)
    end

    if blackName ~= nil then
        self.blackName = cleanName(blackName, self.blackName)
    end
end

function Tournament:startGame(incrementGame)
    if incrementGame == true then
        self.gameNo = self.gameNo + 1
    end

    self.whiteMs = self.timeControlMs
    self.blackMs = self.timeControlMs
    self.activeColor = Pieces.WHITE
    self.running = true
    self.finished = false
    self.result = nil
    self.winner = nil
    self.lastTickAt = nowMs()
    self.resultRecorded = false
end

function Tournament:recordResult(result, winner)
    if self.resultRecorded then
        return false
    end

    self.resultRecorded = true
    self.finished = true
    self.running = false
    self.result = tostring(result or "finished")
    self.winner = winner

    if winner == Pieces.WHITE then
        self.whiteScore = self.whiteScore + 1
    elseif winner == Pieces.BLACK then
        self.blackScore = self.blackScore + 1
    else
        self.draws = self.draws + 1
        self.whiteScore = self.whiteScore + 0.5
        self.blackScore = self.blackScore + 0.5
    end

    return true
end

function Tournament:tick()
    if not self.running or self.finished then
        self.lastTickAt = nowMs()
        return false
    end

    local now = nowMs()
    local elapsed = math.max(0, now - (self.lastTickAt or now))
    self.lastTickAt = now

    if elapsed <= 0 then
        return false
    end

    if self.activeColor == Pieces.BLACK then
        self.blackMs = math.max(0, self.blackMs - elapsed)

        if self.blackMs <= 0 then
            self:recordResult("timeout", Pieces.WHITE)
        end
    else
        self.whiteMs = math.max(0, self.whiteMs - elapsed)

        if self.whiteMs <= 0 then
            self:recordResult("timeout", Pieces.BLACK)
        end
    end

    return true
end

function Tournament:afterMove(game)
    self:tick()

    if self.finished then
        return
    end

    if game.status == "checkmate" then
        self:recordResult("checkmate", game.winner)
        return
    elseif game.status == "stalemate" then
        self:recordResult("stalemate", nil)
        return
    end

    self.activeColor = game:getTurn()
    self.lastTickAt = nowMs()
end

function Tournament:export()
    return {
        version = 1,
        timeControlMs = self.timeControlMs,
        whiteName = self.whiteName,
        blackName = self.blackName,
        whiteScore = self.whiteScore,
        blackScore = self.blackScore,
        draws = self.draws,
        gameNo = self.gameNo,
        whiteMs = math.floor(self.whiteMs),
        blackMs = math.floor(self.blackMs),
        activeColor = self.activeColor,
        running = self.running == true,
        finished = self.finished == true,
        result = self.result,
        winner = self.winner
    }
end

function Tournament:import(state)
    if type(state) ~= "table" then
        return false, "tournament_state_not_table"
    end

    local timeControlMs = math.max(
        60 * 1000,
        math.floor(tonumber(state.timeControlMs) or self.timeControlMs)
    )

    self.timeControlMs = timeControlMs
    self.whiteName = cleanName(state.whiteName, self.whiteName)
    self.blackName = cleanName(state.blackName, self.blackName)
    self.whiteScore = math.max(0, tonumber(state.whiteScore) or 0)
    self.blackScore = math.max(0, tonumber(state.blackScore) or 0)
    self.draws = math.max(0, math.floor(tonumber(state.draws) or 0))
    self.gameNo = math.max(1, math.floor(tonumber(state.gameNo) or 1))
    self.whiteMs = clampMs(state.whiteMs, timeControlMs)
    self.blackMs = clampMs(state.blackMs, timeControlMs)
    self.activeColor = state.activeColor == Pieces.BLACK and Pieces.BLACK or Pieces.WHITE
    self.running = state.running == true
    self.finished = state.finished == true
    self.result = state.result ~= nil and tostring(state.result) or nil
    self.winner = state.winner == Pieces.WHITE and Pieces.WHITE or
        (state.winner == Pieces.BLACK and Pieces.BLACK or nil)
    self.lastTickAt = nowMs()
    self.resultRecorded = self.finished

    return true
end

return Tournament
