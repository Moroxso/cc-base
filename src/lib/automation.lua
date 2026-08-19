local Automation = {}
Automation.__index = Automation

local DEFAULT_PATH = "/data/automation.json"
local CONFIG_VERSION = 3

local VALID_SIDES = {
    left = true,
    right = true,
    front = true,
    back = true,
    top = true,
    bottom = true
}

local VALID_OPERATORS = {
    [">="] = true,
    [">"] = true,
    ["<="] = true,
    ["<"] = true,
    ["=="] = true,
    ["!="] = true
}

local VALID_ACTION_MODES = {
    hold = true,
    pulse = true,
    delay = true
}

local function copyDefault()
    return {
        version = CONFIG_VERSION,
        enabled = true,
        rules = {}
    }
end

local function ensureParent(path)
    local dir = fs.getDir(path)

    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function clampLevel(value)
    value = tonumber(value) or 0
    value = math.floor(value)

    if value < 0 then
        return 0
    elseif value > 15 then
        return 15
    end

    return value
end

local function clampSeconds(value)
    value = tonumber(value) or 1

    if value < 0.1 then
        return 0.1
    elseif value > 300 then
        return 300
    end

    return value
end

local function normalizeOperator(value)
    value = tostring(value or ">=")

    if VALID_OPERATORS[value] then
        return value
    end

    return ">="
end

local function normalizeActionMode(value)
    value = tostring(value or "hold")

    if VALID_ACTION_MODES[value] then
        return value
    end

    return "hold"
end

local function compare(input, operator, threshold)
    if operator == ">=" then
        return input >= threshold
    elseif operator == ">" then
        return input > threshold
    elseif operator == "<=" then
        return input <= threshold
    elseif operator == "<" then
        return input < threshold
    elseif operator == "==" then
        return input == threshold
    elseif operator == "!=" then
        return input ~= threshold
    end

    return false
end

local function normalizeRule(rule, index)
    if type(rule) ~= "table" then
        return nil
    end

    if not VALID_SIDES[rule.inputSide] then
        return nil
    end

    if not VALID_SIDES[rule.outputSide] then
        return nil
    end

    local threshold = clampLevel(rule.threshold)
    local outputValue = clampLevel(rule.outputValue)
    local operator = normalizeOperator(rule.operator)
    local actionMode = normalizeActionMode(rule.actionMode)
    local seconds = clampSeconds(rule.seconds)

    return {
        name = tostring(
            rule.name or
            ("Rule " .. tostring(index))
        ),
        enabled = rule.enabled ~= false,
        inputSide = rule.inputSide,
        operator = operator,
        threshold = threshold,
        outputSide = rule.outputSide,
        outputValue = outputValue,
        actionMode = actionMode,
        seconds = seconds
    }
end

local function makeRuleKey(rule, index)
    return table.concat({
        tostring(index),
        rule.name,
        rule.inputSide,
        rule.operator,
        tostring(rule.threshold),
        rule.outputSide,
        tostring(rule.outputValue),
        rule.actionMode,
        tostring(rule.seconds)
    }, "|")
end

function Automation.loadConfig(path)
    path = path or DEFAULT_PATH

    if not fs.exists(path) then
        return copyDefault()
    end

    local file = fs.open(path, "r")

    if not file then
        return copyDefault()
    end

    local raw = file.readAll()
    file.close()

    local ok, config = pcall(
        textutils.unserializeJSON,
        raw
    )

    if not ok or type(config) ~= "table" then
        return copyDefault()
    end

    local normalized = {
        version = CONFIG_VERSION,
        enabled = config.enabled ~= false,
        rules = {}
    }

    if type(config.rules) == "table" then
        for i, rule in ipairs(config.rules) do
            local validRule = normalizeRule(rule, i)

            if validRule then
                table.insert(
                    normalized.rules,
                    validRule
                )
            end
        end
    end

    return normalized
end

function Automation.saveConfig(path, config)
    path = path or DEFAULT_PATH
    config = config or copyDefault()

    config.version = CONFIG_VERSION

    ensureParent(path)

    local file = fs.open(path, "w")

    if not file then
        return false, "Cannot open config for writing"
    end

    file.write(
        textutils.serializeJSON(config)
    )
    file.close()

    return true
end

function Automation.new(path)
    local self = setmetatable({}, Automation)

    self.path = path or DEFAULT_PATH
    self.config = Automation.loadConfig(self.path)
    self.controlledSides = {}
    self.ruleStates = {}
    self.running = false

    return self
end

function Automation:reload()
    self.config = Automation.loadConfig(self.path)
end

function Automation:getConfig()
    return self.config
end

function Automation:clearControlledOutputs()
    for side in pairs(self.controlledSides) do
        redstone.setAnalogOutput(side, 0)
    end

    self.controlledSides = {}
end

function Automation:evaluate()
    local desired = {}
    local activeStateKeys = {}
    local now = os.clock()

    if self.config.enabled then
        for index, rule in ipairs(self.config.rules) do
            if rule.enabled then
                desired[rule.outputSide] =
                    desired[rule.outputSide] or 0

                local input = redstone.getAnalogInput(
                    rule.inputSide
                )

                local matched = compare(
                    input,
                    rule.operator,
                    rule.threshold
                )

                local stateKey = makeRuleKey(rule, index)
                activeStateKeys[stateKey] = true

                local state = self.ruleStates[stateKey]

                if not state then
                    state = {
                        lastMatched = false,
                        delayStartedAt = nil,
                        pulseUntil = nil
                    }
                    self.ruleStates[stateKey] = state
                end

                local shouldOutput = false

                if rule.actionMode == "hold" then
                    shouldOutput = matched

                elseif rule.actionMode == "delay" then
                    if matched then
                        if not state.delayStartedAt then
                            state.delayStartedAt = now
                        end

                        shouldOutput =
                            (now - state.delayStartedAt) >= rule.seconds
                    else
                        state.delayStartedAt = nil
                    end

                elseif rule.actionMode == "pulse" then
                    if matched and not state.lastMatched then
                        state.pulseUntil = now + rule.seconds
                    end

                    if state.pulseUntil then
                        if now < state.pulseUntil then
                            shouldOutput = true
                        else
                            state.pulseUntil = nil
                        end
                    end
                end

                state.lastMatched = matched

                if shouldOutput then
                    desired[rule.outputSide] = math.max(
                        desired[rule.outputSide],
                        rule.outputValue
                    )
                end
            end
        end
    else
        self.ruleStates = {}
    end

    for stateKey in pairs(self.ruleStates) do
        if not activeStateKeys[stateKey] then
            self.ruleStates[stateKey] = nil
        end
    end

    for side in pairs(self.controlledSides) do
        if desired[side] == nil then
            redstone.setAnalogOutput(side, 0)
        end
    end

    for side, value in pairs(desired) do
        if redstone.getAnalogOutput(side) ~= value then
            redstone.setAnalogOutput(side, value)
        end
    end

    self.controlledSides = {}

    for side in pairs(desired) do
        self.controlledSides[side] = true
    end
end

function Automation:run()
    self.running = true
    self:reload()
    self:evaluate()

    local timer = os.startTimer(0.1)

    while self.running do
        local event, value = os.pullEvent()

        if event == "redstone" then
            self:evaluate()

        elseif event == "automation_reload" then
            self:reload()
            self:evaluate()

        elseif event == "timer" and value == timer then
            self:reload()
            self:evaluate()
            timer = os.startTimer(0.1)
        end
    end
end

function Automation:stop()
    self.running = false
end

return Automation
