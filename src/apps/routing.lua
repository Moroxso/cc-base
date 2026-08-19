local Button = require("lib.gui.button")
local List = require("lib.gui.list")
local Address = require("lib.net.address")
local Peers = require("lib.net.peers")
local Routes = require("lib.net.routes")
local Protocol = require("lib.net.protocol")

local width, height = term.getSize()

if width < 48 or height < 18 then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    error("Terminal is too small for Routing UI")
end

local running = true
local message = "Select a trusted gateway or enable router mode."
local peersData = Peers.load()
local routesData = Routes.load()
local requestSequence = 0

local function resetColors()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function writeLine(x, y, maxWidth, text, color)
    text = tostring(text or "")

    if #text > maxWidth then
        text = text:sub(1, maxWidth)
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(color or colors.white)
    term.setCursorPos(x, y)
    term.write(text)
    term.write(string.rep(" ", math.max(0, maxWidth - #text)))
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

local gatewayButton = Button.new({
    id = "gateway",
    label = "Set Gateway",
    x = 2,
    y = 14,
    width = 13,
    height = 1,
    backgroundColor = colors.blue,
    textColor = colors.white
})

local forwardButton = Button.new({
    id = "forward",
    label = "Forward OFF",
    x = 16,
    y = 14,
    width = 13,
    height = 1,
    backgroundColor = colors.orange,
    textColor = colors.black
})

local clearButton = Button.new({
    id = "clear",
    label = "Clear GW",
    x = 30,
    y = 14,
    width = 10,
    height = 1,
    backgroundColor = colors.gray,
    textColor = colors.white
})

local backButton = Button.new({
    id = "back",
    label = "Back",
    x = 41,
    y = 14,
    width = math.max(8, width - 42),
    height = 1,
    backgroundColor = colors.red,
    textColor = colors.white
})

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
    local x = math.max(1, math.floor((width - #title) / 2) + 1)
    term.setCursorPos(x, 2)
    term.write(title)
    resetColors()
end

local function drawFooter()
    local footer = "MOUSE  UP/DOWN peer  ENTER gateway  CTRL forward  SHIFT back"

    if #footer > width then
        footer = "UP/DOWN ENTER gateway CTRL forward SHIFT back"
    end

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))

    local x = math.max(1, math.floor((width - #footer) / 2) + 1)
    term.setCursorPos(x, height)
    term.write(footer:sub(1, width))
    resetColors()
end

local function draw()
    resetColors()
    term.clear()
    drawHeader()

    local localAddress = Address.localAddress() or "UNAVAILABLE"
    local gateway = routesData.defaultGateway or "DIRECT"

    writeLine(
        2,
        4,
        width - 3,
        "LOCAL: " .. localAddress .. "   ROUTES: " .. tostring(#routesData.routes),
        colors.cyan
    )

    writeLine(
        2,
        5,
        width - 3,
        "FORWARDING: " .. (routesData.forwarding and "ON" or "OFF") ..
            "   DEFAULT: " .. gateway,
        routesData.forwarding and colors.lime or colors.lightGray
    )

    writeLine(
        2,
        6,
        width - 3,
        "Gateway must be a directly reachable TRUSTED peer.",
        colors.lightGray
    )

    peerList:draw(term)

    local selected = peerList:getSelectedItem()

    if selected then
        writeLine(
            2,
            12,
            width - 3,
            string.format(
                "Selected #%d %s | %s",
                selected.id,
                peerAddress(selected),
                selected.trusted and "TRUSTED" or "UNTRUSTED"
            ),
            selected.trusted and colors.lime or colors.orange
        )
    else
        writeLine(2, 12, width - 3, "No peer selected.", colors.lightGray)
    end

    gatewayButton:setEnabled(selected ~= nil and selected.trusted == true)
    gatewayButton:draw(term)

    forwardButton.label = routesData.forwarding and "Forward ON" or "Forward OFF"
    forwardButton.backgroundColor = routesData.forwarding and colors.green or colors.orange
    forwardButton.textColor = colors.black
    forwardButton:draw(term)

    clearButton:setEnabled(routesData.defaultGateway ~= nil)
    clearButton:draw(term)
    backButton:draw(term)

    writeLine(
        2,
        16,
        width - 3,
        routesData.forwarding and
            "ROUTER MODE: packets not addressed to this host may be forwarded." or
            "HOST MODE: transit packets are dropped.",
        routesData.forwarding and colors.lime or colors.white
    )

    writeLine(2, 17, width - 3, message, colors.gray)
    drawFooter()
end

local function setGateway()
    local peer = peerList:getSelectedItem()

    if not peer or not peer.trusted then
        message = "Select a trusted directly connected peer first."
        return
    end

    local address = peerAddress(peer)
    local requestId = newRequestId("route-gw")

    os.queueEvent("ccbase_route_set_default", address, requestId)
    message = "Setting default gateway to " .. address .. "..."
end

local function toggleForwarding()
    local requestId = newRequestId("route-fwd")
    os.queueEvent(
        "ccbase_route_set_forwarding",
        not routesData.forwarding,
        requestId
    )
    message = "Changing forwarding mode..."
end

local function clearGateway()
    local requestId = newRequestId("route-clear")
    os.queueEvent("ccbase_route_clear_default", requestId)
    message = "Clearing default gateway..."
end

local function isPointerClick(button)
    return button == 1 or button == 0
end

local refreshTimer = os.startTimer(0.5)
draw()

while running do
    local event, a, b, c, d = os.pullEvent()
    local redraw = false

    if event == "mouse_click" and isPointerClick(a) then
        local index = peerList:findAt(b, c)

        if index then
            peerList:setSelected(index)
            redraw = true
        elseif gatewayButton:contains(b, c) and gatewayButton.enabled then
            setGateway()
            redraw = true
        elseif forwardButton:contains(b, c) then
            toggleForwarding()
            redraw = true
        elseif clearButton:contains(b, c) and clearButton.enabled then
            clearGateway()
            redraw = true
        elseif backButton:contains(b, c) then
            running = false
        end

    elseif event == "key" then
        if a == keys.up then
            peerList:move(-1)
            redraw = true
        elseif a == keys.down then
            peerList:move(1)
            redraw = true
        elseif a == keys.enter then
            setGateway()
            redraw = true
        elseif a == keys.leftCtrl then
            toggleForwarding()
            redraw = true
        elseif a == keys.leftShift then
            running = false
        end

    elseif event == "ccbase_routes_changed" then
        refresh()
        message = "Routing table updated."
        redraw = true

    elseif event == "ccbase_route_action" then
        refresh()

        if b then
            message = "Routing: " .. tostring(d) .. " = " .. tostring(c)
        else
            message = "Routing error: " .. tostring(c)
        end

        redraw = true

    elseif event == "ccbase_net_peers_changed" then
        refresh()
        redraw = true

    elseif event == "timer" and a == refreshTimer then
        refresh()
        refreshTimer = os.startTimer(0.5)
        redraw = true

    elseif event == "term_resize" then
        local newWidth, newHeight = term.getSize()

        if newWidth < 48 or newHeight < 18 then
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
print("Routing Control closed.")
