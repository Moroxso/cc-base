local Button = require("lib.gui.button")
local List = require("lib.gui.list")
local Firewall = require("lib.net.firewall")
local CCIP = require("lib.net.ccip")

local width, height = term.getSize()

if width < 48 or height < 18 then
    error("Terminal is too small for Firewall UI")
end

local running = true
local config = Firewall.load()
local chainIndex = 2
local chains = {
    Firewall.CHAIN_INPUT,
    Firewall.CHAIN_FORWARD,
    Firewall.CHAIN_OUTPUT
}
local message = "FORWARD defaults to DROP. Add explicit rules or change policy."

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

local function readJson(path)
    if not fs.exists(path) then
        return nil
    end

    local file = fs.open(path, "r")

    if not file then
        return nil
    end

    local raw = file.readAll()
    file.close()

    local ok, data = pcall(textutils.unserializeJSON, raw)
    return ok and type(data) == "table" and data or nil
end

local function currentChain()
    return chains[chainIndex]
end

local function chainRules()
    local result = {}

    for _, rule in ipairs(config.rules or {}) do
        if rule.chain == currentChain() then
            table.insert(result, rule)
        end
    end

    return result
end

local function protocolName(protocolId)
    if protocolId == nil then
        return "ANY"
    elseif protocolId == CCIP.PROTOCOL_CONTROL then
        return "CTRL"
    elseif protocolId == CCIP.PROTOCOL_CCTP then
        return "CCTP"
    elseif protocolId == CCIP.PROTOCOL_CCDP then
        return "CCDP"
    end

    return "P" .. tostring(protocolId)
end

local function ruleLabel(rule)
    return string.format(
        "[%s] %-5s %-4s %s",
        rule.enabled and "X" or " ",
        rule.action,
        protocolName(rule.protocol),
        rule.name or rule.id
    )
end

local ruleList = List.new({
    x = 2,
    y = 7,
    width = width - 3,
    height = 5,
    items = chainRules(),
    getLabel = ruleLabel,
    selectedBackgroundColor = colors.lightBlue,
    selectedTextColor = colors.black
})

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

local chainButton = button("chain", "Chain", 2, 14, 10, colors.blue)
local policyButton = button("policy", "Policy", 13, 14, 11, colors.orange, colors.black)
local enableButton = button("enable", "Firewall", 25, 14, 10, colors.green, colors.black)
local backButton = button("back", "Back", 36, 14, math.max(12, width - 37), colors.red)

local ctrlButton = button("ctrl", "+ CTRL", 2, 15, 10, colors.cyan, colors.black)
local udpButton = button("udp", "+ CCDP", 13, 15, 10, colors.purple)
local tcpButton = button("tcp", "+ CCTP", 24, 15, 10, colors.lightBlue, colors.black)
local allButton = button("all", "+ ALL", 35, 15, math.max(13, width - 36), colors.lime, colors.black)

local deleteButton = button("delete", "Delete", 2, 16, 10, colors.red)
local clearLogButton = button("clearlog", "Clear Log", 13, 16, 12, colors.gray)

local function refreshRules(keepId)
    config = Firewall.load()
    ruleList:setItems(chainRules())

    if keepId then
        for index, rule in ipairs(ruleList.items or {}) do
            if rule.id == keepId then
                ruleList:setSelected(index)
                return
            end
        end
    end
end

local function saveConfig()
    local ok, err = Firewall.save(config)

    if not ok then
        message = "Firewall save failed: " .. tostring(err)
        return false
    end

    os.queueEvent("ccbase_firewall_reload")
    os.queueEvent("ccbase_firewall_changed")
    refreshRules()
    return true
end

local function drawHeader()
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    local title = "CCIP FIREWALL"
    term.setCursorPos(math.floor((width - #title) / 2) + 1, 2)
    term.write(title)
    resetColors()
end

local function drawFooter()
    local text = "UP/DOWN rule  LEFT/RIGHT chain  ENTER toggle  CTRL policy  SHIFT back"

    if #text > width then
        text = "ARROWS select/chain ENTER toggle CTRL policy SHIFT"
    end

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))
    term.setCursorPos(math.max(1, math.floor((width - #text) / 2) + 1), height)
    term.write(text:sub(1, width))
    resetColors()
end

local function draw()
    resetColors()
    term.clear()
    drawHeader()

    local status = readJson(Firewall.STATUS_PATH) or {}
    local log = Firewall.loadLog()
    local lastLog = log[#log]
    local chain = currentChain()
    local policy = config.policies[chain] or Firewall.ACTION_DROP

    line(4,
        "STATE: " .. (config.enabled and "ON" or "OFF") ..
        "   RATE: " .. (config.rateLimit.enabled and
            (tostring(config.rateLimit.packets) .. "/" .. tostring(config.rateLimit.windowMs) .. "ms") or
            "OFF"),
        config.enabled and colors.lime or colors.orange
    )

    line(5,
        "INPUT " .. config.policies.INPUT ..
        "   FORWARD " .. config.policies.FORWARD ..
        "   OUTPUT " .. config.policies.OUTPUT,
        colors.lightGray
    )

    line(6,
        string.format(
            "CHAIN: %s  POLICY: %s  RULES: %d  DROP: %s",
            chain,
            policy,
            #(chainRules()),
            tostring(status.dropped or 0)
        ),
        policy == Firewall.ACTION_DROP and colors.orange or colors.cyan
    )

    ruleList:draw(term)

    local selected = ruleList:getSelectedItem()

    if selected then
        line(12,
            string.format(
                "%s | %s | src %s | dst %s",
                selected.id,
                protocolName(selected.protocol),
                selected.source or "ANY",
                selected.destination or "ANY"
            ),
            colors.white
        )
    else
        line(12, "No rule selected in this chain.", colors.lightGray)
    end

    if lastLog then
        line(13,
            string.format(
                "LAST DROP %s %s -> %s P%s:%s",
                tostring(lastLog.chain or "?"),
                tostring(lastLog.source or "?"),
                tostring(lastLog.destination or "?"),
                tostring(lastLog.protocol or "?"),
                tostring(lastLog.destinationPort or "?")
            ),
            colors.red
        )
    else
        line(13, "DROP LOG: empty", colors.gray)
    end

    chainButton.label = "Chain " .. chain:sub(1, 3)
    chainButton:draw(term)

    policyButton.label = "Policy " .. policy
    policyButton.backgroundColor = policy == Firewall.ACTION_ALLOW and colors.green or colors.orange
    policyButton:draw(term)

    enableButton.label = config.enabled and "FW ON" or "FW OFF"
    enableButton.backgroundColor = config.enabled and colors.green or colors.gray
    enableButton:draw(term)
    backButton:draw(term)

    ctrlButton:draw(term)
    udpButton:draw(term)
    tcpButton:draw(term)
    allButton:draw(term)

    deleteButton:setEnabled(selected ~= nil)
    deleteButton:draw(term)
    clearLogButton:draw(term)

    line(17, message, colors.gray, 26, math.max(1, width - 27))
    drawFooter()
end

local function cycleChain(delta)
    chainIndex = chainIndex + delta

    if chainIndex < 1 then
        chainIndex = #chains
    elseif chainIndex > #chains then
        chainIndex = 1
    end

    refreshRules()
    message = "Selected chain " .. currentChain()
end

local function togglePolicy()
    local chain = currentChain()
    local nextPolicy = config.policies[chain] == Firewall.ACTION_ALLOW and
        Firewall.ACTION_DROP or Firewall.ACTION_ALLOW

    local updated, ok, err = Firewall.setPolicy(config, chain, nextPolicy)

    if not ok then
        message = "Policy error: " .. tostring(err)
        return
    end

    config = updated

    if saveConfig() then
        message = chain .. " default policy = " .. nextPolicy
    end
end

local function toggleFirewall()
    config = Firewall.setEnabled(config, not config.enabled)

    if saveConfig() then
        message = "Firewall " .. (config.enabled and "enabled" or "disabled")
    end
end

local function addPreset(name, protocolId, destinationPort)
    local chain = currentChain()
    local id = string.format(
        "ui-%s-%s",
        chain:lower(),
        tostring(name):lower()
    )

    local updated, ok, err = Firewall.addRule(config, {
        id = id,
        name = "Allow " .. name,
        enabled = true,
        chain = chain,
        action = Firewall.ACTION_ALLOW,
        protocol = protocolId,
        destinationPort = destinationPort
    })

    if not ok then
        message = "Rule error: " .. tostring(err)
        return
    end

    config = updated

    if saveConfig() then
        refreshRules(id)
        message = "ALLOW " .. name .. " added to " .. chain
    end
end

local function toggleSelectedRule()
    local selected = ruleList:getSelectedItem()

    if not selected then
        message = "No rule selected."
        return
    end

    local updated, changed = Firewall.toggleRule(config, selected.id)

    if changed then
        config = updated
        saveConfig()
        refreshRules(selected.id)
        message = "Rule " .. selected.id .. " toggled."
    end
end

local function deleteSelectedRule()
    local selected = ruleList:getSelectedItem()

    if not selected then
        message = "No rule selected."
        return
    end

    local updated, changed = Firewall.removeRule(config, selected.id)

    if changed then
        config = updated
        saveConfig()
        message = "Rule " .. selected.id .. " deleted."
    end
end

local refreshTimer = os.startTimer(0.5)
draw()

while running do
    local event, a, b, c = os.pullEvent()
    local redraw = false

    if event == "mouse_click" and (a == 1 or a == 0) then
        local index = ruleList:findAt(b, c)

        if index then
            ruleList:setSelected(index)
            redraw = true
        elseif chainButton:contains(b, c) then
            cycleChain(1)
            redraw = true
        elseif policyButton:contains(b, c) then
            togglePolicy()
            redraw = true
        elseif enableButton:contains(b, c) then
            toggleFirewall()
            redraw = true
        elseif backButton:contains(b, c) then
            running = false
        elseif ctrlButton:contains(b, c) then
            addPreset("CTRL", CCIP.PROTOCOL_CONTROL, 7)
            redraw = true
        elseif udpButton:contains(b, c) then
            addPreset("CCDP", CCIP.PROTOCOL_CCDP, nil)
            redraw = true
        elseif tcpButton:contains(b, c) then
            addPreset("CCTP", CCIP.PROTOCOL_CCTP, nil)
            redraw = true
        elseif allButton:contains(b, c) then
            addPreset("ALL", nil, nil)
            redraw = true
        elseif deleteButton:contains(b, c) and deleteButton.enabled then
            deleteSelectedRule()
            redraw = true
        elseif clearLogButton:contains(b, c) then
            Firewall.clearLog()
            message = "Drop log cleared."
            redraw = true
        end

    elseif event == "key" then
        if a == keys.up then
            ruleList:move(-1)
            redraw = true
        elseif a == keys.down then
            ruleList:move(1)
            redraw = true
        elseif a == keys.left then
            cycleChain(-1)
            redraw = true
        elseif a == keys.right then
            cycleChain(1)
            redraw = true
        elseif a == keys.enter then
            toggleSelectedRule()
            redraw = true
        elseif a == keys.leftCtrl then
            togglePolicy()
            redraw = true
        elseif a == keys.leftShift then
            running = false
        end

    elseif event == "ccbase_firewall_changed" then
        refreshRules()
        redraw = true

    elseif event == "timer" and a == refreshTimer then
        config = Firewall.load()
        refreshRules(ruleList:getSelectedItem() and ruleList:getSelectedItem().id or nil)
        refreshTimer = os.startTimer(0.5)
        redraw = true

    elseif event == "term_resize" then
        local w, h = term.getSize()

        if w < 48 or h < 18 then
            running = false
        else
            redraw = true
        end
    end

    if redraw and running then
        draw()
    end
end

resetColors()
term.clear()
term.setCursorPos(1, 1)
print("Firewall Control closed.")
