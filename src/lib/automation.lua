local Automation = {}
Automation.__index = Automation

local DEFAULT_PATH = "/data/automation.json"

local VALID_SIDES = {
    left = true,
    right = true,
    front = true,
    back = true,
    top = true,
    bottom = true
}

local function copyDefault()
    return {
        version = 1,
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

    return {
        name = tostring(
            rule.name or
            ("Rule " .. tostring(index))
        ),
        enabled = rule.enabled ~= false,
        inputSide = rule.inputSide,
        threshold = threshold,
        outputSide = rule.outputSide,
        outputValue = outputValue
    }
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
        version = 1,
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

    if self.config.enabled then
        for _, rule in ipairs(self.config.rules) do
            if rule.enabled then
                desired[rule.outputSide] =
                    desired[rule.outputSide] or 0

                local input = redstone.getAnalogInput(
                    rule.inputSide
                )

                if input >= rule.threshold then
                    desired[rule.outputSide] = math.max(
                        desired[rule.outputSide],
                        rule.outputValue
                    )
                end
            end
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

    local timer = os.startTimer(0.5)

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
            timer = os.startTimer(0.5)
        end
    end
end

function Automation:stop()
    self.running = false
end

return Automation
