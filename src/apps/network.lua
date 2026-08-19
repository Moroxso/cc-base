local Button = require("lib.gui.button")
local List = require("lib.gui.list")
local Runtime = require("lib.runtime")
local Protocol = require("lib.net.protocol")
local Transport = require("lib.net.transport")
local Peers = require("lib.net.peers")
local Address = require("lib.net.address")
local Firewall = require("lib.net.firewall")

local STATUS_PATH = "/data/network/status.json"
local width, height = term.getSize()

if width < 48 or height < 18 then
    error("Terminal is too small for Network UI")
end

local running = true
local message = "Network Core / CC stack diagnostics"
local peersData = Peers.load()
local lastStatus = nil

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

local function readStatus()
    if not fs.exists(STATUS_PATH) then return nil end
    local file = fs.open(STATUS_PATH, "r")
    if not file then return nil end
    local raw = file.readAll()
    file.close()
    local ok, data = pcall(textutils.unserializeJSON, raw)
    return ok and type(data) == "table" and data or nil
end

local function online(status)
    return status and status.running == true and
        math.max(0, Protocol.nowMs() - (tonumber(status.updatedAt) or 0)) <= 5000
end

local function peerAddress(peer)
    return Address.forComputer(peer.id) or "NO-IP"
end

local function peerLabel(peer)
    local latency = (peer.latencyMs or 0) > 0 and
        (" " .. tostring(peer.latencyMs) .. "ms") or ""

    return string.format(
        "[%s] #%d %s%s",
        peer.trusted and "T" or "?",
        peer.id,
        peer.label or ("Computer " .. tostring(peer.id)),
        latency
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

local routesButton = button("routes", "Routing", 2, 13, 12, colors.brown)
local firewallButton = button("firewall", "Firewall", 15, 13, 12, colors.red)
local securityButton = button("security", "Security", 28, 13, 12, colors.orange, colors.black)
local scanButton = button("scan", "Scan", 2, 14, 10, colors.blue)
local pingButton = button("ping", "Ping", 13, 14, 10, colors.green, colors.black)
local pairButton = button("pair", "Pair", 24, 14, 13, colors.orange, colors.black)
local backButton = button("back", "Back", 38, 14, math.max(10, width - 39), colors.red)
local ipButton = button("ip", "CCIP Ping", 2, 15, 14, colors.cyan, colors.black)
local udpButton = button("udp", "CCDP Echo", 17, 15, 14, colors.purple)
local tcpButton = button("tcp", "CCTP Echo", 32, 15, math.max(15, width - 33), colors.lightBlue, colors.black)

local function refreshPeers()
    local selected = peerList:getSelectedItem()
    local selectedId = selected and selected.id or nil
    peersData = Peers.load()
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

local function pendingPair(status, peerId)
    for _, pending in ipairs(status and status.pairings or {}) do
        if pending.peerId == peerId then return pending end
    end
    return nil
end

local function selectedPeer()
    return peerList:getSelectedItem()
end

local function drawHeader()
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end
    local title = "NETWORK CORE / CC STACK"
    term.setCursorPos(math.floor((width - #title) / 2) + 1, 2)
    term.write(title)
    resetColors()
end

local function drawFooter()
    local text = "MOUSE ARROWS ENTER core CTRL scan SHIFT back"
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))
    term.setCursorPos(math.max(1, math.floor((width - #text) / 2) + 1), height)
    term.write(text:sub(1, width))
    resetColors()
end

local function configurePair(peer, pending)
    if not peer then
        pairButton.label = "Pair"
        pairButton:setEnabled(false)
    elseif peer.trusted then
        pairButton.label = "Untrust"
        pairButton.backgroundColor = colors.red
        pairButton.textColor = colors.white
        pairButton:setEnabled(true)
    else
        pairButton.backgroundColor = colors.orange
        pairButton.textColor = colors.black
        pairButton:setEnabled(true)
        if pending and pending.code and not pending.localConfirmed then
            pairButton.label = "Confirm"
        elseif pending then
            pairButton.label = "Waiting"
            pairButton:setEnabled(false)
        else
            pairButton.label = "Pair"
        end
    end
end

local function draw()
    resetColors()
    term.clear()
    drawHeader()

    local status = readStatus()
    lastStatus = status
    local isOnline = online(status)
    local modems = status and status.modems or Transport.getModems()
    local peer = selectedPeer()
    local pending = peer and pendingPair(status, peer.id) or nil
    local firewall = Firewall.load()

    line(4, string.format(
        "ID #%d  %s  CCIP %s",
        os.getComputerID(),
        os.getComputerLabel() or "UNNAMED",
        Address.localAddress() or "UNAVAILABLE"
    ), colors.cyan)

    line(5,
        "SERVICE: " .. (isOnline and "ONLINE" or "OFFLINE") ..
        "  REDNET: " .. (Transport.isOpen() and "OPEN" or "CLOSED") ..
        "  MODEM: " .. (#modems > 0 and table.concat(modems, ",") or "NONE"),
        isOnline and colors.lime or colors.orange
    )

    line(6,
        "PEERS: " .. tostring(#peersData.peers) ..
        "  TRUSTED: " .. tostring(status and status.trustedCount or 0) ..
        "  FW: " .. (firewall.enabled and "ON" or "OFF"),
        colors.lightGray
    )

    peerList:draw(term)

    if peer then
        line(12,
            string.format("#%d %s | %s", peer.id, peerAddress(peer), peer.trusted and "TRUSTED" or "UNTRUSTED"),
            peer.trusted and colors.lime or colors.white
        )
    else
        line(12, "No peer selected.", colors.lightGray)
    end

    routesButton:draw(term)
    firewallButton:draw(term)
    securityButton:draw(term)
    scanButton:draw(term)
    pingButton:setEnabled(peer ~= nil)
    pingButton:draw(term)
    configurePair(peer, pending)
    pairButton:draw(term)
    backButton:draw(term)

    local secure = peer ~= nil and peer.trusted == true
    ipButton:setEnabled(secure)
    udpButton:setEnabled(secure)
    tcpButton:setEnabled(secure)
    ipButton:draw(term)
    udpButton:draw(term)
    tcpButton:draw(term)

    if pending and pending.code then
        line(16,
            "PAIR CODE: " .. tostring(pending.code) ..
            "  LOCAL: " .. (pending.localConfirmed and "YES" or "NO") ..
            "  REMOTE: " .. (pending.remoteConfirmed and "YES" or "NO"),
            colors.yellow
        )
    elseif secure then
        line(16, "Trusted CC stack link. Routing + firewall + integrity available.", colors.lime)
    else
        line(16, message, colors.lightGray)
    end

    local lastError = status and status.lastError or ""
    line(17, lastError ~= "" and ("CORE: " .. lastError) or message,
        lastError ~= "" and colors.orange or colors.gray)
    drawFooter()
end

local function scan()
    os.queueEvent("ccbase_net_scan")
    message = "Discovery broadcast requested..."
end

local function corePing()
    local peer = selectedPeer()
    if not peer then message = "Select a peer first." return end
    os.queueEvent("ccbase_net_ping", peer.id)
    message = "Core ping queued for #" .. tostring(peer.id)
end

local function secureTest(kind)
    local peer = selectedPeer()
    if not peer or not peer.trusted then
        message = kind .. " requires a trusted peer."
        return
    end

    local address = peerAddress(peer)
    local eventName = kind == "CCIP" and "ccbase_ip_ping" or
        (kind == "CCDP" and "ccbase_ccdp_ping" or "ccbase_cctp_ping")
    os.queueEvent(eventName, address)
    message = kind .. " test queued for " .. address
end

local function pairAction()
    local peer = selectedPeer()
    if not peer then message = "Select a peer first." return end

    if peer.trusted then
        os.queueEvent("ccbase_net_untrust", peer.id)
        message = "Removing trust for #" .. tostring(peer.id)
        return
    end

    local pending = pendingPair(lastStatus, peer.id)
    if not pending then
        os.queueEvent("ccbase_net_pair_start", peer.id)
        message = "Pair request sent to #" .. tostring(peer.id)
    elseif pending.code and not pending.localConfirmed then
        os.queueEvent("ccbase_net_pair_confirm", peer.id)
        message = "Pair code confirmed locally."
    end
end

local function openRouting()
    local ok, err = Runtime.run("/apps/routing.lua")
    message = ok and "Routing controls closed." or ("Routing UI error: " .. tostring(err))
    refreshPeers()
end

local function openFirewall()
    local ok, err = Runtime.run("/apps/firewall.lua")
    message = ok and "Firewall controls closed." or ("Firewall UI error: " .. tostring(err))
end

local function openSecurity()
    local ok, err = Runtime.run("/apps/security.lua")
    message = ok and "Security controls closed." or ("Security UI error: " .. tostring(err))
end

local refreshTimer = os.startTimer(0.5)
draw()

while running do
    local event, a, b, c, d, e, f = os.pullEvent()
    local redraw = false

    if event == "mouse_click" and (a == 1 or a == 0) then
        local index = peerList:findAt(b, c)
        if index then peerList:setSelected(index) redraw = true
        elseif routesButton:contains(b, c) then openRouting() redraw = true
        elseif firewallButton:contains(b, c) then openFirewall() redraw = true
        elseif securityButton:contains(b, c) then openSecurity() redraw = true
        elseif scanButton:contains(b, c) then scan() redraw = true
        elseif pingButton:contains(b, c) then corePing() redraw = true
        elseif pairButton:contains(b, c) and pairButton.enabled then pairAction() redraw = true
        elseif ipButton:contains(b, c) and ipButton.enabled then secureTest("CCIP") redraw = true
        elseif udpButton:contains(b, c) and udpButton.enabled then secureTest("CCDP") redraw = true
        elseif tcpButton:contains(b, c) and tcpButton.enabled then secureTest("CCTP") redraw = true
        elseif backButton:contains(b, c) then running = false end

    elseif event == "key" then
        if a == keys.up then peerList:move(-1) redraw = true
        elseif a == keys.down then peerList:move(1) redraw = true
        elseif a == keys.enter then corePing() redraw = true
        elseif a == keys.right then secureTest("CCIP") redraw = true
        elseif a == keys.left then secureTest("CCDP") redraw = true
        elseif a == keys.leftCtrl then scan() redraw = true
        elseif a == keys.leftShift then running = false end

    elseif event == "ccbase_net_peers_changed" then
        refreshPeers() message = "Peer registry updated." redraw = true
    elseif event == "ccbase_net_pong" then
        refreshPeers() message = string.format("Core pong #%s: %sms", tostring(a), tostring(b)) redraw = true
    elseif event == "ccbase_ip_pong" then
        message = string.format("CCIP pong %s: %sms", tostring(a), tostring(b)) redraw = true
    elseif event == "ccbase_ccdp_pong" then
        message = string.format("CCDP echo %s: %sms", tostring(a), tostring(b)) redraw = true
    elseif event == "ccbase_cctp_pong" then
        message = string.format(
            "CCTP %s: %sms | win %s | RTO %sms",
            tostring(a), tostring(b), tostring(e or "?"), tostring(f or "?")
        )
        redraw = true
    elseif event == "ccbase_ip_ping_failed" or event == "ccbase_ccdp_ping_failed" or event == "ccbase_cctp_ping_failed" then
        message = "Network test failed: " .. tostring(b) redraw = true
    elseif event == "ccbase_firewall_drop" then
        message = "Firewall DROP " .. tostring(a) .. ": " .. tostring(b)
        redraw = true
    elseif event == "ccbase_firewall_changed" then
        message = "Firewall policy updated."
        redraw = true
    elseif event == "ccbase_security_state" then
        message = a and "Integrity state: CLEAN" or ("Integrity ALERT: " .. tostring(b) .. " issue(s)")
        redraw = true
    elseif event == "ccbase_net_scan_started" then
        message = a and "Discovery broadcast sent." or "Scan failed: no open modem." redraw = true
    elseif event == "ccbase_net_ping_started" then
        message = b and ("Core ping sent to #" .. tostring(a)) or ("Core ping failed for #" .. tostring(a)) redraw = true
    elseif event == "ccbase_net_pair_state" then
        refreshPeers()
        if b == "confirm_required" or b == "remote_confirmed" then
            message = "Pairing #" .. tostring(a) .. ": compare code " .. tostring(c)
        elseif b == "trusted" then message = "Computer #" .. tostring(a) .. " is trusted."
        elseif b == "expired" then message = "Pairing expired."
        elseif b == "untrusted" then message = "Trust removed from #" .. tostring(a) end
        redraw = true
    elseif event == "timer" and a == refreshTimer then
        refreshPeers() refreshTimer = os.startTimer(0.5) redraw = true
    elseif event == "term_resize" then
        local w, h = term.getSize()
        if w < 48 or h < 18 then running = false else redraw = true end
    end

    if redraw and running then draw() end
end

resetColors()
term.clear()
term.setCursorPos(1, 1)
print("Network Control closed.")
