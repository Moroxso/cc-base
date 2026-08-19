local Button = require("lib.gui.button")
local List = require("lib.gui.list")
local Protocol = require("lib.net.protocol")
local Transport = require("lib.net.transport")
local Peers = require("lib.net.peers")

local STATUS_PATH = "/data/network/status.json"

local width, height = term.getSize()

if width < 48 or height < 18 then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    error("Terminal is too small for Network UI")
end

local running = true
local message = "Network Core diagnostics"
local peersData = Peers.load()
local lastStatus = nil

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

local function readStatus()
    if not fs.exists(STATUS_PATH) then
        return nil
    end

    local file = fs.open(STATUS_PATH, "r")

    if not file then
        return nil
    end

    local raw = file.readAll()
    file.close()

    local ok, status = pcall(textutils.unserializeJSON, raw)

    if not ok or type(status) ~= "table" then
        return nil
    end

    return status
end

local function serviceOnline(status)
    if not status or status.running ~= true then
        return false
    end

    local updatedAt = tonumber(status.updatedAt) or 0
    local age = math.max(0, Protocol.nowMs() - updatedAt)

    return age <= 5000
end

local function peerLabel(peer)
    local trust = peer.trusted and "T" or "?"
    local latency = ""

    if (peer.latencyMs or 0) > 0 then
        latency = " " .. tostring(peer.latencyMs) .. "ms"
    end

    return string.format(
        "[%s] #%d %s%s",
        trust,
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

local scanButton = Button.new({
    id = "scan",
    label = "Scan",
    x = 2,
    y = 14,
    width = 10,
    height = 1,
    backgroundColor = colors.blue,
    textColor = colors.white
})

local pingButton = Button.new({
    id = "ping",
    label = "Ping",
    x = 13,
    y = 14,
    width = 10,
    height = 1,
    backgroundColor = colors.green,
    textColor = colors.black
})

local pairButton = Button.new({
    id = "pair",
    label = "Pair",
    x = 24,
    y = 14,
    width = 13,
    height = 1,
    backgroundColor = colors.orange,
    textColor = colors.black
})

local backButton = Button.new({
    id = "back",
    label = "Back",
    x = 38,
    y = 14,
    width = math.max(10, width - 39),
    height = 1,
    backgroundColor = colors.red,
    textColor = colors.white
})

local function refreshPeers()
    local selectedId = nil
    local selected = peerList:getSelectedItem()

    if selected then
        selectedId = selected.id
    end

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

local function findPending(status, peerId)
    if not status or not peerId then
        return nil
    end

    for _, pending in ipairs(status.pairings or {}) do
        if pending.peerId == peerId then
            return pending
        end
    end

    return nil
end

local function drawHeader()
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    local title = "NETWORK CORE"
    local x = math.max(1, math.floor((width - #title) / 2) + 1)
    term.setCursorPos(x, 2)
    term.write(title)
    resetColors()
end

local function drawFooter()
    local footer = "MOUSE  ARROWS peer  ENTER ping  CTRL scan  SHIFT back"

    if #footer > width then
        footer = "MOUSE  ARROWS  ENTER ping  CTRL scan  SHIFT"
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

local function configurePairButton(selected, pending)
    if not selected then
        pairButton.label = "Pair"
        pairButton:setEnabled(false)
        return
    end

    if selected.trusted then
        pairButton.label = "Untrust"
        pairButton.backgroundColor = colors.red
        pairButton.textColor = colors.white
        pairButton:setEnabled(true)
        return
    end

    pairButton.backgroundColor = colors.orange
    pairButton.textColor = colors.black

    if not pending then
        pairButton.label = "Pair"
        pairButton:setEnabled(true)
    elseif pending.code and not pending.localConfirmed then
        pairButton.label = "Confirm"
        pairButton:setEnabled(true)
    elseif pending.localConfirmed then
        pairButton.label = "Waiting"
        pairButton:setEnabled(false)
    else
        pairButton.label = "Pairing..."
        pairButton:setEnabled(false)
    end
end

local function draw()
    resetColors()
    term.clear()
    term.setCursorPos(1, 1)

    drawHeader()

    local status = readStatus()
    lastStatus = status
    local online = serviceOnline(status)
    local modems = status and status.modems or Transport.getModems()
    local modemText = #modems > 0 and table.concat(modems, ",") or "NONE"

    writeLine(
        2,
        4,
        width - 3,
        string.format(
            "ID #%d  %s",
            os.getComputerID(),
            os.getComputerLabel() or "UNNAMED"
        ),
        colors.cyan
    )

    writeLine(
        2,
        5,
        width - 3,
        "SERVICE: " .. (online and "ONLINE" or "OFFLINE") ..
            "  REDNET: " .. (Transport.isOpen() and "OPEN" or "CLOSED") ..
            "  MODEM: " .. modemText,
        online and colors.lime or colors.orange
    )

    writeLine(
        2,
        6,
        width - 3,
        "PEERS: " .. tostring(#peersData.peers) ..
            "  TRUSTED: " .. tostring(status and status.trustedCount or 0) ..
            "   [?] untrusted [T] trusted",
        colors.lightGray
    )

    peerList:draw(term)

    local selected = peerList:getSelectedItem()
    local pending = selected and findPending(status, selected.id) or nil

    if selected then
        local seenAge = math.max(
            0,
            math.floor((Protocol.nowMs() - (selected.lastSeen or 0)) / 1000)
        )

        writeLine(
            2,
            12,
            width - 3,
            string.format(
                "Selected #%d | seen %ds | protocol v%d | %s",
                selected.id,
                seenAge,
                selected.protocolVersion or 0,
                selected.trusted and "TRUSTED" or "UNTRUSTED"
            ),
            selected.trusted and colors.lime or colors.white
        )
    else
        writeLine(2, 12, width - 3, "No peer selected.", colors.lightGray)
    end

    scanButton:draw(term)
    pingButton:setEnabled(selected ~= nil)
    pingButton:draw(term)
    configurePairButton(selected, pending)
    pairButton:draw(term)
    backButton:draw(term)

    if pending and pending.code then
        local localState = pending.localConfirmed and "YES" or "NO"
        local remoteState = pending.remoteConfirmed and "YES" or "NO"

        writeLine(
            2,
            16,
            width - 3,
            "PAIR CODE: " .. tostring(pending.code) ..
                "  LOCAL: " .. localState ..
                "  REMOTE: " .. remoteState,
            colors.yellow
        )
    elseif selected and selected.trusted then
        writeLine(
            2,
            16,
            width - 3,
            "Trusted session active. Sequenced app packets enabled.",
            colors.lime
        )
    else
        writeLine(2, 16, width - 3, message, colors.lightGray)
    end

    local lastError = status and status.lastError or ""

    if lastError ~= "" then
        writeLine(
            2,
            17,
            width - 3,
            "CORE: " .. tostring(lastError),
            colors.orange
        )
    elseif pending and pending.code then
        writeLine(
            2,
            17,
            width - 3,
            "Compare codes on BOTH computers, then Confirm on BOTH.",
            colors.lightGray
        )
    else
        writeLine(
            2,
            17,
            width - 3,
            message,
            colors.gray
        )
    end

    drawFooter()
end

local function startScan()
    os.queueEvent("ccbase_net_scan")
    message = "Discovery broadcast requested..."
end

local function pingSelected()
    local peer = peerList:getSelectedItem()

    if not peer then
        message = "Select a peer first."
        return
    end

    os.queueEvent("ccbase_net_ping", peer.id)
    message = "Ping requested for #" .. tostring(peer.id) .. "..."
end

local function pairSelected()
    local peer = peerList:getSelectedItem()

    if not peer then
        message = "Select a peer first."
        return
    end

    if peer.trusted then
        os.queueEvent("ccbase_net_untrust", peer.id)
        message = "Removing trust for #" .. tostring(peer.id) .. "..."
        return
    end

    local pending = findPending(lastStatus, peer.id)

    if not pending then
        os.queueEvent("ccbase_net_pair_start", peer.id)
        message = "Pair request sent to #" .. tostring(peer.id) .. "..."
    elseif pending.code and not pending.localConfirmed then
        os.queueEvent("ccbase_net_pair_confirm", peer.id)
        message = "Pair code confirmed locally."
    else
        message = "Pairing is waiting for the other computer."
    end
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

        elseif scanButton:contains(b, c) then
            startScan()
            redraw = true

        elseif pingButton:contains(b, c) then
            pingSelected()
            redraw = true

        elseif pairButton:contains(b, c) and pairButton.enabled then
            pairSelected()
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
            pingSelected()
            redraw = true

        elseif a == keys.leftCtrl then
            startScan()
            redraw = true

        elseif a == keys.leftShift then
            running = false
        end

    elseif event == "ccbase_net_peers_changed" then
        refreshPeers()
        message = "Peer registry updated."
        redraw = true

    elseif event == "ccbase_net_pong" then
        refreshPeers()
        message = string.format(
            "Pong from #%s: %sms",
            tostring(a),
            tostring(b)
        )
        redraw = true

    elseif event == "ccbase_net_scan_started" then
        message = a and "Discovery broadcast sent." or "Scan failed: no open modem."
        redraw = true

    elseif event == "ccbase_net_ping_started" then
        if b then
            message = "Ping sent to #" .. tostring(a)
        else
            message = "Ping failed for #" .. tostring(a)
        end
        redraw = true

    elseif event == "ccbase_net_pair_state" then
        refreshPeers()

        if b == "confirm_required" or b == "remote_confirmed" then
            message = "Pairing with #" .. tostring(a) .. ": compare code " .. tostring(c)
        elseif b == "trusted" then
            message = "Computer #" .. tostring(a) .. " is now trusted."
        elseif b == "expired" then
            message = "Pairing with #" .. tostring(a) .. " expired."
        elseif b == "untrusted" then
            message = "Trust removed from #" .. tostring(a) .. "."
        end

        redraw = true

    elseif event == "ccbase_net_pair_action" then
        if c then
            message = "Pair action accepted for #" .. tostring(a) .. "."
        else
            message = "Pair action failed: " .. tostring(d)
        end
        redraw = true

    elseif event == "timer" and a == refreshTimer then
        refreshPeers()
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
print("Network Control closed.")
