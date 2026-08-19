local Button = require("lib.gui.button")
local List = require("lib.gui.list")
local Address = require("lib.net.address")
local Peers = require("lib.net.peers")
local Routes = require("lib.net.routes")
local Protocol = require("lib.net.protocol")

local width, height = term.getSize()
if width < 48 or height < 18 then error("Terminal is too small for Routing UI") end

local running = true
local message = "Configure gateway/forwarding, then test a remote Computer ID."
local peersData = Peers.load()
local routesData = Routes.load()
local requestSequence = 0
local targetId = math.min(Address.MAX_COMPUTER_ID, os.getComputerID() + 1)

local function resetColors()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function line(y, text, color, x, maxWidth)
    x = x or 2
    maxWidth = maxWidth or (width - x)
    text = tostring(text or "")
    if #text > maxWidth then text = text:sub(1, maxWidth) end
    term.setBackgroundColor(colors.black)
    term.setTextColor(color or colors.white)
    term.setCursorPos(x, y)
    term.write(text .. string.rep(" ", math.max(0, maxWidth - #text)))
    resetColors()
end

local function newRequestId(prefix)
    requestSequence = requestSequence + 1
    return string.format(
        "%s:%d:%d:%d",
        prefix,
        os.getComputerID(),
        Protocol.nowMs(),
        requestSequence
    )
end

local function peerAddress(peer)
    return Address.forComputer(peer.id) or "NO-IP"
end

local function peerLabel(peer)
    return string.format(
        "[%s] #%d %-16s %s",
        peer.trusted and "T" or "?",
        peer.id,
        (peer.label or ("Computer " .. tostring(peer.id))):sub(1, 16),
        peerAddress(peer)
    )
end

local peerList = List.new({
    x = 2,
    y = 7,
    width = width - 3,
    height = 5,
    items = peersData.peers,
    getLabel = peerLabel,
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

local gatewayButton = button("gateway", "Set Gateway", 2, 14, 13, colors.blue)
local forwardButton = button("forward", "Forward OFF", 16, 14, 13, colors.orange, colors.black)
local clearButton = button("clear", "Clear GW", 30, 14, 10, colors.gray)
local backButton = button("back", "Back", 41, 14, math.max(8, width - 42), colors.red)
local minusButton = button("minus", "ID -", 2, 15, 8, colors.gray)
local plusButton = button("plus", "ID +", 11, 15, 8, colors.gray)
local ipTestButton = button("iptest", "Route Ping", 20, 15, 13, colors.cyan, colors.black)
local cctpTestButton = button("tcptest", "Route CCTP", 34, 15, math.max(14, width - 35), colors.lightBlue, colors.black)

local function refresh()
    local selected = peerList:getSelectedItem()
    local selectedId = selected and selected.id or nil
    peersData = Peers.load()
    routesData = Routes.load()
    peerList:setItems(peersData.peers)

    if selectedId then
        for index, peer in ipairs(peersData.peers) do
            if peer.id == selectedId then
                peerList:setSelected(index)
                break
            end
        end
    end
end

local function drawHeader()
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end
    local title = "CCIP ROUTING"
    term.setCursorPos(math.floor((width - #title) / 2) + 1, 2)
    term.write(title)
    resetColors()
end

local function drawFooter()
    local text = "LEFT/RIGHT target  ENTER ping  CTRL forward  SHIFT back"
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

    local gateway = routesData.defaultGateway or "DIRECT"
    local targetAddress = Address.forComputer(targetId) or "INVALID"

    line(4,
        "LOCAL: " .. tostring(Address.localAddress() or "UNAVAILABLE") ..
        "   STATIC ROUTES: " .. tostring(#routesData.routes),
        colors.cyan
    )
    line(5,
        "FORWARDING: " .. (routesData.forwarding and "ON" or "OFF") ..
        "   DEFAULT: " .. gateway,
        routesData.forwarding and colors.lime or colors.lightGray
    )
    line(6, "Gateway must be a directly reachable TRUSTED peer.", colors.lightGray)

    peerList:draw(term)
    local selected = peerList:getSelectedItem()

    if selected then
        line(12,
            string.format("Gateway candidate #%d %s | %s", selected.id, peerAddress(selected), selected.trusted and "TRUSTED" or "UNTRUSTED"),
            selected.trusted and colors.lime or colors.orange
        )
    else
        line(12, "No gateway peer selected.", colors.lightGray)
    end

    line(13,
        string.format("TEST TARGET: Computer #%d  CCIP %s", targetId, targetAddress),
        colors.yellow
    )

    gatewayButton:setEnabled(selected ~= nil and selected.trusted == true)
    gatewayButton:draw(term)
    forwardButton.label = routesData.forwarding and "Forward ON" or "Forward OFF"
    forwardButton.backgroundColor = routesData.forwarding and colors.green or colors.orange
    forwardButton:draw(term)
    clearButton:setEnabled(routesData.defaultGateway ~= nil)
    clearButton:draw(term)
    backButton:draw(term)
    minusButton:setEnabled(targetId > 0)
    plusButton:setEnabled(targetId < Address.MAX_COMPUTER_ID)
    minusButton:draw(term)
    plusButton:draw(term)
    ipTestButton:draw(term)
    cctpTestButton:draw(term)

    line(16,
        routesData.forwarding and
            "ROUTER MODE: transit CCIP packets are forwarded with TTL - 1." or
            "HOST MODE: transit packets are dropped.",
        routesData.forwarding and colors.lime or colors.white
    )
    line(17, message, colors.gray)
    drawFooter()
end

local function setGateway()
    local peer = peerList:getSelectedItem()
    if not peer or not peer.trusted then
        message = "Select a trusted directly connected peer first."
        return
    end
    local address = peerAddress(peer)
    os.queueEvent("ccbase_route_set_default", address, newRequestId("route-gw"))
    message = "Setting default gateway to " .. address .. "..."
end

local function toggleForwarding()
    os.queueEvent(
        "ccbase_route_set_forwarding",
        not routesData.forwarding,
        newRequestId("route-fwd")
    )
    message = "Changing forwarding mode..."
end

local function clearGateway()
    os.queueEvent("ccbase_route_clear_default", newRequestId("route-clear"))
    message = "Clearing default gateway..."
end

local function changeTarget(delta)
    targetId = math.max(0, math.min(Address.MAX_COMPUTER_ID, targetId + delta))
    message = "Target changed to Computer #" .. tostring(targetId)
end

local function testRoute(kind)
    local address = Address.forComputer(targetId)
    if not address then
        message = "Invalid target ID."
        return
    end

    if kind == "CCIP" then
        os.queueEvent("ccbase_ip_ping", address)
    else
        os.queueEvent("ccbase_cctp_ping", address)
    end

    message = kind .. " routed test queued for " .. address
end

local refreshTimer = os.startTimer(0.5)
draw()

while running do
    local event, a, b, c, d, e, f = os.pullEvent()
    local redraw = false

    if event == "mouse_click" and (a == 1 or a == 0) then
        local index = peerList:findAt(b, c)
        if index then peerList:setSelected(index) redraw = true
        elseif gatewayButton:contains(b, c) and gatewayButton.enabled then setGateway() redraw = true
        elseif forwardButton:contains(b, c) then toggleForwarding() redraw = true
        elseif clearButton:contains(b, c) and clearButton.enabled then clearGateway() redraw = true
        elseif minusButton:contains(b, c) and minusButton.enabled then changeTarget(-1) redraw = true
        elseif plusButton:contains(b, c) and plusButton.enabled then changeTarget(1) redraw = true
        elseif ipTestButton:contains(b, c) then testRoute("CCIP") redraw = true
        elseif cctpTestButton:contains(b, c) then testRoute("CCTP") redraw = true
        elseif backButton:contains(b, c) then running = false end

    elseif event == "key" then
        if a == keys.up then peerList:move(-1) redraw = true
        elseif a == keys.down then peerList:move(1) redraw = true
        elseif a == keys.left then changeTarget(-1) redraw = true
        elseif a == keys.right then changeTarget(1) redraw = true
        elseif a == keys.enter then testRoute("CCIP") redraw = true
        elseif a == keys.leftCtrl then toggleForwarding() redraw = true
        elseif a == keys.leftShift then running = false end

    elseif event == "ccbase_routes_changed" then
        refresh() message = "Routing table updated." redraw = true
    elseif event == "ccbase_route_action" then
        refresh()
        message = b and ("Routing: " .. tostring(d) .. " = " .. tostring(c)) or
            ("Routing error: " .. tostring(c))
        redraw = true
    elseif event == "ccbase_net_peers_changed" then
        refresh() redraw = true
    elseif event == "ccbase_ip_pong" then
        message = string.format("ROUTED CCIP pong %s: %sms", tostring(a), tostring(b))
        redraw = true
    elseif event == "ccbase_cctp_pong" then
        message = string.format(
            "ROUTED CCTP %s: %sms | win %s | RTO %sms",
            tostring(a), tostring(b), tostring(e or "?"), tostring(f or "?")
        )
        redraw = true
    elseif event == "ccbase_ip_ping_failed" or event == "ccbase_cctp_ping_failed" then
        message = "Routed test failed: " .. tostring(b)
        redraw = true
    elseif event == "timer" and a == refreshTimer then
        refresh() refreshTimer = os.startTimer(0.5) redraw = true
    elseif event == "term_resize" then
        local w, h = term.getSize()
        if w < 48 or h < 18 then running = false else redraw = true end
    end

    if redraw and running then draw() end
end

resetColors()
term.clear()
term.setCursorPos(1, 1)
print("Routing Control closed.")
