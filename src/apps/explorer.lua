local ui = require("lib.ui")
local StorageManager = require("lib.system.storage_manager")

local manager = StorageManager.new()
local TITLE = "BASE COMMANDER"

local panes = {
    {path = "/", entries = {}, selected = 1, offset = 1},
    {path = "/", entries = {}, selected = 1, offset = 1}
}

local active = 1
local message = "Ready"

local function truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

local function parentPath(path)
    path = StorageManager.normalizePath(path)
    if path == "/" then return "/" end
    local parent = fs.getDir(path)
    if parent == "" then return "/" end
    return StorageManager.normalizePath(parent)
end

local function refreshPane(index)
    local pane = panes[index]
    local entries, err = manager:list(pane.path)
    if not entries then
        pane.path = "/"
        entries, err = manager:list("/")
    end
    pane.entries = entries or {}
    if pane.selected < 1 then pane.selected = 1 end
    if pane.selected > #pane.entries then pane.selected = math.max(1, #pane.entries) end
    if pane.offset < 1 then pane.offset = 1 end
    if pane.offset > pane.selected then pane.offset = pane.selected end
    return err == nil, err
end

local function refreshAll()
    refreshPane(1)
    refreshPane(2)
end

local function selectedEntry()
    local pane = panes[active]
    return pane.entries[pane.selected]
end

local function layout()
    local width, height = term.getSize()
    local divider = math.floor((width + 1) / 2)
    return {
        width = width,
        height = height,
        divider = divider,
        leftX = 1,
        leftWidth = divider - 1,
        rightX = divider + 1,
        rightWidth = width - divider,
        firstRow = 5,
        lastRow = math.max(5, height - 4)
    }
end

local function clampOffsets(rows)
    for _, pane in ipairs(panes) do
        if pane.selected < pane.offset then pane.offset = pane.selected end
        if pane.selected > pane.offset + rows - 1 then
            pane.offset = pane.selected - rows + 1
        end
        pane.offset = math.max(1, pane.offset)
    end
end

local function drawPane(index, x, width, firstRow, lastRow)
    local pane = panes[index]
    local isActive = index == active

    term.setBackgroundColor(isActive and colors.blue or colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(x, 4)
    term.write(string.rep(" ", width))
    term.setCursorPos(x + 1, 4)
    term.write(truncate(pane.path, math.max(1, width - 2)))

    for row = firstRow, lastRow do
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.setCursorPos(x, row)
        term.write(string.rep(" ", width))

        local entryIndex = pane.offset + (row - firstRow)
        local entry = pane.entries[entryIndex]
        if entry then
            local selected = isActive and entryIndex == pane.selected
            if selected then
                term.setBackgroundColor(colors.lightBlue)
                term.setTextColor(colors.black)
                term.setCursorPos(x, row)
                term.write(string.rep(" ", width))
            else
                term.setBackgroundColor(colors.black)
                term.setTextColor(entry.isDir and colors.cyan or colors.white)
            end

            local marker = entry.isDir and "/" or " "
            if entry.protected then marker = "*" end
            local text = marker .. " " .. entry.name
            term.setCursorPos(x + 1, row)
            term.write(truncate(text, math.max(1, width - 2)))
        end
    end

    if #pane.entries == 0 then
        term.setTextColor(colors.lightGray)
        term.setCursorPos(x + 2, firstRow)
        term.write(truncate("<empty>", math.max(1, width - 3)))
    end
end

local function drawStatus(info)
    local l = layout()
    local pane = panes[active]
    local entry = selectedEntry()
    local detail = "No selection"

    if entry then
        local owner = entry.owner or (entry.protected and "managed" or "user")
        local kind = entry.isDir and "DIR" or StorageManager.formatBytes(entry.size)
        detail = string.format("%s | %s | %s", kind, owner, entry.name)
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(1, l.height - 3)
    term.write(string.rep(" ", l.width))
    term.setCursorPos(2, l.height - 3)
    term.write(truncate(detail, l.width - 2))

    local snapshot = manager:inspect(pane.path, false)
    local driveText = snapshot and tostring(snapshot.drive or "?") or "?"
    local freeText = snapshot and StorageManager.formatBytes(snapshot.free) or "unknown"

    term.setCursorPos(1, l.height - 2)
    term.write(string.rep(" ", l.width))
    term.setCursorPos(2, l.height - 2)
    term.setTextColor(colors.lightGray)
    term.write(truncate("[" .. driveText .. "] free " .. freeText .. " | " .. tostring(info or message), l.width - 2))
end

local function draw()
    local l = layout()
    ui.drawHeader(TITLE)
    clampOffsets(l.lastRow - l.firstRow + 1)

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.lightGray)
    for row = 4, l.lastRow do
        term.setCursorPos(l.divider, row)
        term.write("|")
    end

    drawPane(1, l.leftX, l.leftWidth, l.firstRow, l.lastRow)
    drawPane(2, l.rightX, l.rightWidth, l.firstRow, l.lastRow)
    drawStatus(message)
    ui.drawFooter("TAB F2 REN F3 VIEW F5 COPY F6 MOVE F7 DIR F8 DEL")
end

local function setMessage(text)
    message = tostring(text or "")
end

local function moveSelection(delta)
    local pane = panes[active]
    if #pane.entries == 0 then return end
    pane.selected = math.max(1, math.min(#pane.entries, pane.selected + delta))
end

local function goParent()
    local pane = panes[active]
    local parent = parentPath(pane.path)
    if parent ~= pane.path then
        pane.path = parent
        pane.selected = 1
        pane.offset = 1
        refreshPane(active)
        setMessage("Parent: " .. parent)
    end
end

local function openSelected()
    local entry = selectedEntry()
    if not entry then return end
    if entry.isDir then
        local pane = panes[active]
        pane.path = entry.path
        pane.selected = 1
        pane.offset = 1
        refreshPane(active)
        setMessage("Opened " .. entry.path)
    else
        return "view"
    end
end

local function promptLine(label, initial)
    local l = layout()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.yellow)
    term.setCursorPos(1, l.height - 2)
    term.write(string.rep(" ", l.width))
    term.setCursorPos(2, l.height - 2)
    term.write(truncate(label, math.max(1, l.width - 3)))
    term.setTextColor(colors.white)
    term.setCursorBlink(true)
    local value = read(nil, nil, nil, initial)
    term.setCursorBlink(false)
    return value
end

local function confirm(text)
    local l = layout()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.orange)
    term.setCursorPos(1, l.height - 2)
    term.write(string.rep(" ", l.width))
    term.setCursorPos(2, l.height - 2)
    term.write(truncate(text .. " [y/N]", l.width - 2))

    while true do
        local event, value = os.pullEvent()
        if event == "char" then
            value = string.lower(value)
            if value == "y" then return true end
            if value == "n" then return false end
        elseif event == "key" and (value == keys.enter or value == keys.escape or value == keys.left) then
            return false
        end
    end
end

local function showInfo(entry)
    if not entry then return end
    local info, err = manager:inspect(entry.path, entry.isDir)
    if not info then
        setMessage(err)
        return
    end

    ui.drawHeader(TITLE)
    ui.centerText(term, 4, entry.isDir and "DIRECTORY INFO" or "FILE VIEW", colors.cyan)

    if entry.isDir then
        local lines = {
            "Path: " .. info.path,
            "Drive: " .. tostring(info.drive or "unknown"),
            "Size: " .. StorageManager.formatBytes(info.size),
            "Free: " .. StorageManager.formatBytes(info.free),
            "Owner: " .. tostring(info.owner or "user"),
            "Protection: " .. tostring(info.protection or "none"),
            "Read-only: " .. tostring(info.readOnly == true)
        }
        for index, line in ipairs(lines) do
            if index + 5 >= select(2, term.getSize()) then break end
            term.setCursorPos(2, index + 5)
            term.setTextColor(colors.white)
            term.write(truncate(line, select(1, term.getSize()) - 2))
        end
    else
        local raw, previewState = manager:readPreview(entry.path, 8192)
        if not raw then
            term.setCursorPos(2, 6)
            term.setTextColor(colors.orange)
            term.write(truncate("Preview unavailable: " .. tostring(previewState), select(1, term.getSize()) - 2))
        else
            local width, height = term.getSize()
            local y = 6
            for line in (raw .. "\n"):gmatch("(.-)\n") do
                if y >= height then break end
                local remaining = line
                repeat
                    local chunk = remaining:sub(1, math.max(1, width - 2))
                    term.setCursorPos(2, y)
                    term.setTextColor(colors.white)
                    term.write(chunk)
                    remaining = remaining:sub(#chunk + 1)
                    y = y + 1
                until remaining == "" or y >= height
                if y >= height then break end
            end
            if previewState == true and y < height then
                term.setCursorPos(2, y)
                term.setTextColor(colors.orange)
                term.write("<preview truncated>")
            end
        end
    end

    ui.drawFooter("LEFT / SHIFT - Back")
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.left or key == keys.leftShift or key == keys.escape then break end
    end
end

local function renameSelected()
    local entry = selectedEntry()
    if not entry then return end
    local name = promptLine("Rename to: ", entry.name)
    if not name or name == "" or name == entry.name then
        setMessage("Rename cancelled")
        return
    end
    local ok, detail = manager:rename(entry.path, name)
    setMessage(ok and ("Renamed to " .. name) or detail)
    refreshAll()
end

local function copySelected()
    local entry = selectedEntry()
    if not entry then return end
    local destination = panes[active == 1 and 2 or 1].path
    local ok, detail = manager:copyTo(entry.path, destination)
    setMessage(ok and ("Copied to " .. tostring(detail)) or detail)
    refreshAll()
end

local function moveSelectedToOther()
    local entry = selectedEntry()
    if not entry then return end
    local destination = panes[active == 1 and 2 or 1].path
    if not confirm("Move " .. entry.name .. " -> " .. destination .. "?") then
        setMessage("Move cancelled")
        return
    end
    local ok, detail = manager:moveTo(entry.path, destination)
    setMessage(ok and ("Moved to " .. tostring(detail)) or detail)
    refreshAll()
end

local function makeDirectory()
    local pane = panes[active]
    local name = promptLine("New directory: ")
    if not name or name == "" then
        setMessage("mkdir cancelled")
        return
    end
    local ok, detail = manager:makeDir(pane.path, name)
    setMessage(ok and ("Created " .. tostring(detail)) or detail)
    refreshAll()
end

local function deleteSelected()
    local entry = selectedEntry()
    if not entry then return end
    if not confirm("DELETE " .. entry.name .. "?") then
        setMessage("Delete cancelled")
        return
    end
    local ok, detail = manager:delete(entry.path)
    setMessage(ok and ("Deleted " .. entry.name) or detail)
    refreshAll()
end

local function handleMouse(button, x, y)
    if button ~= 1 then return end
    local l = layout()
    if y < l.firstRow or y > l.lastRow then return end

    local paneIndex
    local paneX
    local paneWidth
    if x < l.divider then
        paneIndex = 1
        paneX = l.leftX
        paneWidth = l.leftWidth
    elseif x > l.divider then
        paneIndex = 2
        paneX = l.rightX
        paneWidth = l.rightWidth
    else
        return
    end

    if x < paneX or x >= paneX + paneWidth then return end

    active = paneIndex
    local pane = panes[active]
    local index = pane.offset + (y - l.firstRow)
    if index >= 1 and index <= #pane.entries then
        pane.selected = index
    end
end

refreshAll()

while true do
    draw()
    local event, a, b, c = os.pullEvent()

    if event == "term_resize" then
        refreshAll()
    elseif event == "mouse_click" then
        handleMouse(a, b, c)
    elseif event == "key" then
        if a == keys.tab then
            active = active == 1 and 2 or 1
        elseif a == keys.up then
            moveSelection(-1)
        elseif a == keys.down then
            moveSelection(1)
        elseif a == keys.pageUp then
            moveSelection(-math.max(1, layout().lastRow - layout().firstRow))
        elseif a == keys.pageDown then
            moveSelection(math.max(1, layout().lastRow - layout().firstRow))
        elseif a == keys.enter then
            if openSelected() == "view" then showInfo(selectedEntry()) end
        elseif a == keys.backspace or a == keys.left then
            goParent()
        elseif a == keys.f2 then
            renameSelected()
        elseif a == keys.f3 then
            showInfo(selectedEntry())
        elseif a == keys.f5 then
            copySelected()
        elseif a == keys.f6 then
            moveSelectedToOther()
        elseif a == keys.f7 then
            makeDirectory()
        elseif a == keys.f8 or a == keys.delete then
            deleteSelected()
        elseif a == keys.leftShift or a == keys.escape then
            ui.clear(term)
            return
        end
    end
end
