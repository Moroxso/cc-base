local Host = {}

local HOST_VERSION = "0.23.0-alpha.5.4"
local PANEL_HEIGHT = 4

local PROFILES = {
    scheduler = {
        title = "Scheduler",
        pages = {{
            {"Run", keys.t}, {"Bench", keys.b}, {"Cancel", keys.c},
            {"Net", keys.m}, {"History", keys.h}, {"Profile", keys.p}, {"Back", keys.q},
        }},
    },
    performance = {
        title = "Performance",
        pages = {{
            {"Delay", keys.d}, {"Conc", keys.k}, {"Cancel", keys.c},
            {"Profile", keys.p}, {"Back", keys.q},
        }},
    },
    jobs = {
        title = "Fleet Jobs",
        pages = {{
            {"Tunnel", keys.t}, {"Cancel", keys.c}, {"Update", keys.u}, {"Back", keys.q},
        }},
    },
    control = {
        title = "Fleet Control",
        pages = {
            {
                {"Forward", keys.up}, {"Back", keys.down}, {"Left", keys.left}, {"Right", keys.right},
                {"Attack", keys.a}, {"Dig", keys.d}, {"Hold", keys.space}, {"More", "next_page"},
            },
            {
                {"Breach", keys.b}, {"RTB", keys.r}, {"Home", keys.h}, {"Update", keys.u},
                {"Jobs", keys.j}, {"NextUnit", keys.tab}, {"Group", keys.g}, {"Back", keys.q},
            },
        },
    },
}

local function shallowCopy(src)
    local out = {}
    for k, v in pairs(src) do out[k] = v end
    return out
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function parseDefault(prompt)
    local value = tostring(prompt or ""):match("%[([^%]]+)%]")
    return value and trim(value) or nil
end

local function fieldSpec(prompt, default)
    local p = string.lower(tostring(prompt or ""))
    if p:find("distance", 1, true) then
        return {kind="number", min=1, max=4096, step=1, coarse=10, decimals=0}
    elseif p:find("repeats", 1, true) then
        return {kind="number", min=1, max=5, step=1, coarse=1, decimals=0}
    elseif p:find("units", 1, true) then
        return {kind="number", min=1, max=128, step=1, coarse=4, decimals=0}
    elseif p:find("concurrency", 1, true) then
        return {kind="number", min=-1, max=128, step=1, coarse=4, decimals=0}
    elseif p:find("delay", 1, true) then
        local allowProfile = p:find("0=profile", 1, true) ~= nil
        return {kind="number", min=allowProfile and 0 or 0.05, max=2, step=0.05, coarse=0.10, decimals=2}
    elseif p:find("fleet id", 1, true) then
        return {kind="text"}
    end
    if tonumber(default) then
        return {kind="number", min=-999999, max=999999, step=1, coarse=10, decimals=tonumber(default) % 1 == 0 and 0 or 2}
    end
    return {kind="text"}
end

local function safeColor(termObj, fg, bg)
    if bg and termObj.setBackgroundColor then pcall(termObj.setBackgroundColor, bg) end
    if fg and termObj.setTextColor then pcall(termObj.setTextColor, fg) end
end

local function fillLine(termObj, y, text, fg, bg)
    local w = select(1, termObj.getSize())
    termObj.setCursorPos(1, y)
    safeColor(termObj, fg or colors.white, bg or colors.black)
    termObj.write(string.rep(" ", w))
    termObj.setCursorPos(1, y)
    termObj.write(tostring(text or ""):sub(1, w))
end

local function buttonLayout(actions, y0, y1, width)
    local boxes = {}
    local rows = math.max(1, y1 - y0 + 1)
    local perRow = math.max(1, math.ceil(#actions / rows))
    local index = 1
    for row = 0, rows - 1 do
        local count = math.min(perRow, #actions - index + 1)
        if count <= 0 then break end
        local cell = math.max(5, math.floor(width / count))
        for col = 1, count do
            local action = actions[index]
            local x1 = (col - 1) * cell + 1
            local x2 = col == count and width or math.min(width, col * cell)
            boxes[#boxes+1] = {x1=x1, x2=x2, y=y0+row, action=action}
            index = index + 1
        end
    end
    return boxes
end

local function labelForValue(value, decimals)
    if decimals and decimals > 0 then return string.format("%."..decimals.."f", tonumber(value) or 0) end
    return tostring(math.floor((tonumber(value) or 0) + 0.00001))
end

function Host.run(corePath, profileName)
    local profile = PROFILES[profileName]
    if not profile then error("Unknown pointer profile: " .. tostring(profileName), 0) end
    if not fs.exists(corePath) then error("Core program missing: " .. tostring(corePath), 0) end

    local native = term.current()
    local nativeW, nativeH = native.getSize()
    local panelH = math.min(PANEL_HEIGHT, math.max(2, nativeH - 8))
    local childH = math.max(8, nativeH - panelH)
    local child = window.create(native, 1, 1, nativeW, childH, true)

    local state = {
        running = true,
        mode = "normal",
        page = 1,
        boxes = {},
        lastPrompt = nil,
        input = nil,
        entropyRemaining = 0,
    }

    local function panelRows()
        return childH + 1, nativeH
    end

    local function clearPanel()
        local y0, y1 = panelRows()
        for y = y0, y1 do fillLine(native, y, "", colors.white, colors.gray) end
    end

    local function drawNormalPanel()
        clearPanel()
        state.boxes = {}
        local y0, y1 = panelRows()
        local pages = profile.pages or {}
        if state.page > #pages then state.page = 1 end
        local page = pages[state.page] or {}
        local title = string.format("POINTER %s  %d/%d", profile.title, state.page, math.max(1,#pages))
        fillLine(native, y0, title, colors.black, colors.lightGray)
        local actions = {}
        for _, item in ipairs(page) do actions[#actions+1] = item end
        if #pages > 1 and not (actions[#actions] and actions[#actions][2] == "next_page") then
            actions[#actions+1] = {"More", "next_page"}
        end
        local boxes = buttonLayout(actions, y0+1, y1, nativeW)
        for _, box in ipairs(boxes) do
            local item = box.action
            local text = "[" .. tostring(item[1]) .. "]"
            local span = box.x2 - box.x1 + 1
            local x = box.x1 + math.max(0, math.floor((span - #text) / 2))
            native.setCursorPos(x, box.y)
            safeColor(native, colors.white, colors.gray)
            native.write(text:sub(1, span))
            state.boxes[#state.boxes+1] = {x1=box.x1,x2=box.x2,y=box.y,kind="action",value=item[2]}
        end
    end

    local function drawInputPanel()
        clearPanel()
        state.boxes = {}
        local y0, y1 = panelRows()
        local input = state.input
        if not input then drawNormalPanel(); return end
        local spec = input.spec
        fillLine(native, y0, tostring(input.label or "Input"), colors.black, colors.lightGray)
        if spec.kind == "number" then
            local valueText = labelForValue(input.value, spec.decimals)
            fillLine(native, y0+1, "Value: " .. valueText, colors.white, colors.gray)
            local actions = {{"--",keys.pageDown},{"-",keys.left},{"+",keys.right},{"++",keys.pageUp}}
            local boxes = buttonLayout(actions, y0+2, y0+2, nativeW)
            for _, box in ipairs(boxes) do
                local text = "["..box.action[1].."]"
                local span=box.x2-box.x1+1
                local x=box.x1+math.max(0,math.floor((span-#text)/2))
                native.setCursorPos(x,box.y); safeColor(native,colors.white,colors.gray); native.write(text:sub(1,span))
                state.boxes[#state.boxes+1]={x1=box.x1,x2=box.x2,y=box.y,kind="key",value=box.action[2]}
            end
            local actionY = math.min(y1, y0+3)
            local final = buttonLayout({{"Default",keys.escape},{"OK",keys.enter}}, actionY, actionY, nativeW)
            for _,box in ipairs(final) do
                local text="["..box.action[1].."]"; local span=box.x2-box.x1+1
                local x=box.x1+math.max(0,math.floor((span-#text)/2))
                native.setCursorPos(x,box.y); safeColor(native,colors.white,colors.gray); native.write(text:sub(1,span))
                state.boxes[#state.boxes+1]={x1=box.x1,x2=box.x2,y=box.y,kind="key",value=box.action[2]}
            end
        else
            fillLine(native, y0+1, "Value: " .. tostring(input.value or input.default or ""), colors.white, colors.gray)
            fillLine(native, y0+2, "Type if needed; pointer can use default", colors.lightGray, colors.gray)
            local final = buttonLayout({{"Default",keys.escape},{"OK",keys.enter}}, y1, y1, nativeW)
            for _,box in ipairs(final) do
                local text="["..box.action[1].."]"; local span=box.x2-box.x1+1
                local x=box.x1+math.max(0,math.floor((span-#text)/2))
                native.setCursorPos(x,box.y); safeColor(native,colors.white,colors.gray); native.write(text:sub(1,span))
                state.boxes[#state.boxes+1]={x1=box.x1,x2=box.x2,y=box.y,kind="key",value=box.action[2]}
            end
        end
    end

    local function drawConfirmPanel()
        clearPanel(); state.boxes={}
        local y0,y1=panelRows()
        fillLine(native,y0,"Confirmation",colors.black,colors.lightGray)
        local boxes=buttonLayout({{"Cancel",keys.n},{"Confirm",keys.y}},y0+1,y1,nativeW)
        for _,box in ipairs(boxes) do
            local text="["..box.action[1].."]"; local span=box.x2-box.x1+1
            local x=box.x1+math.max(0,math.floor((span-#text)/2))
            native.setCursorPos(x,box.y); safeColor(native,colors.white,colors.gray); native.write(text:sub(1,span))
            state.boxes[#state.boxes+1]={x1=box.x1,x2=box.x2,y=box.y,kind="key",value=box.action[2],finishMode=true}
        end
    end

    local function drawWaitPanel(text)
        clearPanel(); state.boxes={}
        local y0,y1=panelRows()
        fillLine(native,y0,text or "Continue",colors.black,colors.lightGray)
        local boxes=buttonLayout({{"Continue",keys.enter}},y0+1,y1,nativeW)
        for _,box in ipairs(boxes) do
            local label="[Continue]"; local span=box.x2-box.x1+1
            local x=box.x1+math.max(0,math.floor((span-#label)/2))
            native.setCursorPos(x,box.y); safeColor(native,colors.white,colors.gray); native.write(label:sub(1,span))
            state.boxes[#state.boxes+1]={x1=box.x1,x2=box.x2,y=box.y,kind="key",value=keys.enter,finishMode=true}
        end
    end

    local function drawEntropyPanel()
        clearPanel(); state.boxes={}
        local y0,y1=panelRows()
        fillLine(native,y0,"Entropy setup",colors.black,colors.lightGray)
        fillLine(native,y0+1,"Tap panel repeatedly: "..tostring(state.entropyRemaining),colors.white,colors.gray)
        state.boxes[1]={x1=1,x2=nativeW,y=y0+1,kind="entropy"}
        for y=y0+2,y1 do state.boxes[#state.boxes+1]={x1=1,x2=nativeW,y=y,kind="entropy"} end
    end

    local function drawPanel()
        if state.mode == "input" then drawInputPanel()
        elseif state.mode == "confirm" then drawConfirmPanel()
        elseif state.mode == "wait" then drawWaitPanel("Tap Continue")
        elseif state.mode == "entropy" then drawEntropyPanel()
        else drawNormalPanel() end
    end

    local rawPrint = print
    local rawWrite = write
    local rawTerm = term

    local env = setmetatable({}, {__index=_G})
    local termProxy = shallowCopy(rawTerm)
    env.term = termProxy

    termProxy.clear = function(...)
        if state.mode == "confirm" or state.mode == "wait" then state.mode = "normal" end
        local result = rawTerm.clear(...)
        drawPanel()
        return result
    end

    env.write = function(value)
        local s = tostring(value or "")
        if s:find(":%s*$") or s:find("%[[^%]]+%]%s*:%s*$") then state.lastPrompt = s end
        return rawWrite(value)
    end

    env.print = function(...)
        local parts={}
        for i=1,select("#",...) do parts[#parts+1]=tostring(select(i,...)) end
        local joined=table.concat(parts,"\t")
        local result=rawPrint(...)
        if joined:find("Y=CONFIRM",1,true) then
            state.mode="confirm"; drawPanel()
        elseif joined:find("Press varied keys 24 times",1,true) then
            state.mode="entropy"; state.entropyRemaining=24; drawPanel()
        elseif joined:find("Press any key",1,true) or joined:find("Press ENTER",1,true) then
            state.mode="wait"; drawPanel()
        end
        return result
    end

    env.read = function(replaceChar, history, completeFn, defaultText)
        local prompt = state.lastPrompt or "Input"
        state.lastPrompt = nil
        local default = parseDefault(prompt)
        if defaultText ~= nil and tostring(defaultText) ~= "" then default = tostring(defaultText) end
        local spec = fieldSpec(prompt, default)
        local label = trim(prompt:gsub("%s*%[[^%]]+%]%s*:%s*$", ""):gsub(":%s*$", ""))
        local input = {label=label,default=default,spec=spec}
        if spec.kind == "number" then
            input.value = tonumber(default) or spec.min or 0
            input.value = clamp(input.value, spec.min, spec.max)
        else
            input.value = default or ""
        end
        state.input=input; state.mode="input"; drawPanel()

        local typed = ""
        while true do
            local e,a = os.pullEvent()
            if e == "key" then
                if a == keys.enter then
                    local out
                    if spec.kind=="number" then out=labelForValue(input.value,spec.decimals)
                    else out=typed~="" and typed or tostring(input.value or input.default or "") end
                    state.input=nil; state.mode="normal"; drawPanel(); return out
                elseif a == keys.escape then
                    local out=tostring(input.default or "")
                    state.input=nil; state.mode="normal"; drawPanel(); return out
                elseif spec.kind=="number" then
                    local delta=0
                    if a==keys.left then delta=-spec.step
                    elseif a==keys.right then delta=spec.step
                    elseif a==keys.pageDown then delta=-spec.coarse
                    elseif a==keys.pageUp then delta=spec.coarse end
                    if delta~=0 then
                        input.value=clamp(input.value+delta,spec.min,spec.max)
                        if spec.decimals and spec.decimals>0 then
                            local scale=10^spec.decimals
                            input.value=math.floor(input.value*scale+0.5)/scale
                        else input.value=math.floor(input.value+0.5) end
                        drawPanel()
                    elseif a==keys.backspace and typed~="" then
                        typed=typed:sub(1,-2)
                    end
                elseif a==keys.backspace and typed~="" then
                    typed=typed:sub(1,-2); input.value=typed; drawPanel()
                end
            elseif e=="char" then
                local ch=tostring(a or "")
                if spec.kind=="number" then
                    if ch:match("[%d%.%-]") then
                        typed=typed..ch
                        local n=tonumber(typed)
                        if n then input.value=clamp(n,spec.min,spec.max); drawPanel() end
                    end
                else
                    typed=typed..ch; input.value=typed; drawPanel()
                end
            end
        end
    end

    local function queueKey(code)
        os.queueEvent("key", code, false)
    end

    local function hit(x,y)
        for _,box in ipairs(state.boxes or {}) do
            if y==box.y and x>=box.x1 and x<=box.x2 then return box end
        end
        return nil
    end

    local function pointerLoop()
        drawPanel()
        while state.running do
            local e,a,b,c=os.pullEvent()
            local x,y
            if e=="mouse_click" then x,y=b,c
            elseif e=="monitor_touch" then x,y=b,c
            elseif e=="term_resize" then drawPanel() end
            if x and y and y>childH then
                local box=hit(x,y)
                if box then
                    if box.kind=="action" then
                        if box.value=="next_page" then
                            state.page=(state.page%(#profile.pages))+1; drawPanel()
                        else queueKey(box.value) end
                    elseif box.kind=="key" then
                        queueKey(box.value)
                        if box.finishMode then state.mode="normal"; drawPanel() end
                    elseif box.kind=="entropy" then
                        if state.entropyRemaining>0 then
                            local pseudo=1000 + (x*37 + y*17 + state.entropyRemaining)%10000
                            os.queueEvent("key",pseudo,false)
                            state.entropyRemaining=state.entropyRemaining-1
                            if state.entropyRemaining<=0 then state.mode="normal" end
                            drawPanel()
                        end
                    end
                end
            end
        end
    end

    local function coreRunner()
        local old = term.redirect(child)
        local loader, err = loadfile(corePath, "t", env)
        if not loader then
            term.redirect(old)
            error("Pointer core load failed: "..tostring(err),0)
        end
        local ok, runErr = pcall(loader)
        state.running=false
        term.redirect(old)
        if not ok then error(runErr,0) end
    end

    local ok, err = pcall(function() parallel.waitForAny(coreRunner, pointerLoop) end)
    state.running=false
    term.redirect(native)
    safeColor(native,colors.white,colors.black)
    native.setCursorBlink(false)
    if not ok then error(err,0) end
end

Host.VERSION = HOST_VERSION
return Host
