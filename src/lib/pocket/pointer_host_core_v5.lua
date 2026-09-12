local Host = {}

local HOST_VERSION = "0.23.0-alpha.5.4.5"
local PANEL_HEIGHT = 4
local ERROR_LOG = "/data/pointer_ui_error.log"

local PROFILES = {
    scheduler = {title="Scheduler", pages={{
        {"Run",keys.t},{"Bench",keys.b},{"Cancel",keys.c},{"Net",keys.m},
        {"History",keys.h},{"Profile",keys.p},{"Back",keys.q},
    }}},
    performance = {title="Performance", pages={{
        {"Delay",keys.d},{"Conc",keys.k},{"Cancel",keys.c},{"Profile",keys.p},{"Back",keys.q},
    }}},
    jobs = {title="Fleet Jobs", pages={{
        {"Tunnel",keys.t},{"Cancel",keys.c},{"Update",keys.u},{"Back",keys.q},
    }}},
    control = {title="Fleet Control", pages={
        {{"Forward",keys.up},{"Back",keys.down},{"Left",keys.left},{"Right",keys.right},
         {"Attack",keys.a},{"Dig",keys.d},{"Hold",keys.space},{"More","next_page"}},
        {{"Breach",keys.b},{"RTB",keys.r},{"Home",keys.h},{"Update",keys.u},
         {"Jobs",keys.j},{"NextUnit",keys.tab},{"Group",keys.g},{"Back",keys.q}},
    }},
}

local function ensureParent(path)
    local dir=fs.getDir(path)
    if dir~="" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function logError(corePath,stage,err)
    pcall(function()
        ensureParent(ERROR_LOG)
        local f=fs.open(ERROR_LOG,"w")
        if not f then return end
        f.write(table.concat({
            "BASE Pointer UI diagnostic",
            "version="..HOST_VERSION,
            "core="..tostring(corePath),
            "stage="..tostring(stage),
            "error="..tostring(err),
            "epoch="..tostring(os.epoch and os.epoch("utc") or 0),
        },"\n").."\n")
        f.close()
    end)
end

local function clamp(v,lo,hi)
    if v<lo then return lo elseif v>hi then return hi else return v end
end

local function trim(s)
    return tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")
end

local function parseDefault(prompt)
    local value=tostring(prompt or ""):match("%[([^%]]+)%]")
    return value and trim(value) or nil
end

local function fieldSpec(prompt,default)
    local p=string.lower(tostring(prompt or ""))
    if p:find("distance",1,true) then return {kind="number",min=1,max=4096,step=1,coarse=10,decimals=0}
    elseif p:find("repeats",1,true) then return {kind="number",min=1,max=5,step=1,coarse=1,decimals=0}
    elseif p:find("units",1,true) then return {kind="number",min=1,max=128,step=1,coarse=4,decimals=0}
    elseif p:find("concurrency",1,true) then return {kind="number",min=-1,max=128,step=1,coarse=4,decimals=0}
    elseif p:find("delay",1,true) then
        local allowProfile=p:find("0=profile",1,true)~=nil
        return {kind="number",min=allowProfile and 0 or 0.05,max=2,step=0.05,coarse=0.10,decimals=2}
    elseif p:find("fleet id",1,true) then return {kind="text"}
    elseif tonumber(default) then
        return {kind="number",min=-999999,max=999999,step=1,coarse=10,decimals=(tonumber(default)%1==0) and 0 or 2}
    end
    return {kind="text"}
end

local function labelForValue(value,decimals)
    if decimals and decimals>0 then return string.format("%."..decimals.."f",tonumber(value) or 0) end
    return tostring(math.floor((tonumber(value) or 0)+0.00001))
end

local function safeColor(t,fg,bg)
    if bg and t.setBackgroundColor then pcall(t.setBackgroundColor,bg) end
    if fg and t.setTextColor then pcall(t.setTextColor,fg) end
end

local function fillLine(t,y,text,fg,bg)
    local w=select(1,t.getSize())
    t.setCursorPos(1,y)
    safeColor(t,fg or colors.white,bg or colors.black)
    t.write(string.rep(" ",w))
    t.setCursorPos(1,y)
    t.write(tostring(text or ""):sub(1,w))
end

local function buttonLayout(actions,y0,y1,width)
    local boxes={}
    local rows=math.max(1,y1-y0+1)
    local perRow=math.max(1,math.ceil(#actions/rows))
    local index=1
    for row=0,rows-1 do
        local count=math.min(perRow,#actions-index+1)
        if count<=0 then break end
        local cell=math.max(5,math.floor(width/count))
        for col=1,count do
            local x1=(col-1)*cell+1
            local x2=(col==count) and width or math.min(width,col*cell)
            boxes[#boxes+1]={x1=x1,x2=x2,y=y0+row,action=actions[index]}
            index=index+1
        end
    end
    return boxes
end

function Host.run(corePath,profileName)
    local profile=PROFILES[profileName]
    if not profile then error("Unknown pointer profile: "..tostring(profileName),0) end
    if not fs.exists(corePath) then error("Core program missing: "..tostring(corePath),0) end
    if type(window)~="table" or type(window.create)~="function" then
        logError(corePath,"window_api","window.create unavailable")
        error("Pointer UI requires window.create; see "..ERROR_LOG,0)
    end

    local native=term.current()
    local nativeW,nativeH=native.getSize()
    local panelH=math.min(PANEL_HEIGHT,math.max(2,nativeH-8))
    local childH=math.max(8,nativeH-panelH)
    local okWindow,child=pcall(window.create,native,1,1,nativeW,childH,true)
    if not okWindow or not child then
        logError(corePath,"window_create",child)
        error("Pointer UI cannot create viewport; see "..ERROR_LOG,0)
    end

    local state={
        running=true,mode="normal",page=1,boxes={},focus=1,
        lastPrompt=nil,lastPrinted=nil,input=nil,entropyRemaining=0,
    }

    local function setMode(mode,focus)
        state.mode=mode
        state.focus=math.max(1,math.floor(tonumber(focus) or 1))
    end

    local function panelRows() return childH+1,nativeH end

    local function clearPanel()
        local y0,y1=panelRows()
        for y=y0,y1 do fillLine(native,y,"",colors.white,colors.gray) end
    end

    local function addButton(box,label,kind,value,finishMode)
        local index=#state.boxes+1
        local focused=(index==state.focus)
        local text="["..tostring(label).."]"
        local span=box.x2-box.x1+1
        local x=box.x1+math.max(0,math.floor((span-#text)/2))
        native.setCursorPos(x,box.y)
        safeColor(native,focused and colors.black or colors.white,focused and colors.cyan or colors.gray)
        native.write(text:sub(1,span))
        state.boxes[index]={
            x1=box.x1,x2=box.x2,y=box.y,kind=kind,value=value,
            finishMode=finishMode,label=tostring(label),
        }
    end

    local function drawActions(actions,y0,y1,kind)
        for _,box in ipairs(buttonLayout(actions,y0,y1,nativeW)) do
            addButton(box,box.action[1],kind or "key",box.action[2],box.action[3])
        end
    end

    local function drawNormalPanel()
        clearPanel(); state.boxes={}
        local y0,y1=panelRows(); local pages=profile.pages or {}
        if state.page>#pages then state.page=1 end
        local page=pages[state.page] or {}
        fillLine(native,y0,string.format("%s %d/%d  arrows+Enter",profile.title,state.page,math.max(1,#pages)),colors.black,colors.lightGray)
        local actions={}; for _,item in ipairs(page) do actions[#actions+1]=item end
        if #pages>1 and not (actions[#actions] and actions[#actions][2]=="next_page") then
            actions[#actions+1]={"More","next_page"}
        end
        if state.focus<1 or state.focus>#actions then state.focus=1 end
        for _,box in ipairs(buttonLayout(actions,y0+1,y1,nativeW)) do
            addButton(box,box.action[1],"action",box.action[2])
        end
    end

    local function drawInputPanel()
        clearPanel(); state.boxes={}
        local y0,y1=panelRows(); local input=state.input
        if not input then setMode("normal"); drawNormalPanel(); return end
        local spec=input.spec
        fillLine(native,y0,tostring(input.label or "Input").."  L/R adjust U/D choose",colors.black,colors.lightGray)
        if spec.kind=="number" then
            fillLine(native,y0+1,"Value: "..labelForValue(input.value,spec.decimals),colors.white,colors.gray)
            if state.focus<1 or state.focus>6 then state.focus=6 end
            drawActions({{"--",keys.pageDown},{"-",keys.left},{"+",keys.right},{"++",keys.pageUp}},y0+2,y0+2,"key")
            drawActions({{"Default",keys.escape},{"OK",keys.enter}},math.min(y1,y0+3),math.min(y1,y0+3),"key")
        else
            fillLine(native,y0+1,"Value: "..tostring(input.value or input.default or ""),colors.white,colors.gray)
            fillLine(native,y0+2,"Type if needed; pointer can use default",colors.lightGray,colors.gray)
            if state.focus<1 or state.focus>2 then state.focus=2 end
            drawActions({{"Default",keys.escape},{"OK",keys.enter}},y1,y1,"key")
        end
    end

    local function drawConfirmPanel()
        clearPanel(); state.boxes={}; local y0,y1=panelRows()
        fillLine(native,y0,"Confirmation  arrows+Enter",colors.black,colors.lightGray)
        if state.focus<1 or state.focus>2 then state.focus=1 end
        drawActions({{"Cancel",keys.n,true},{"Confirm",keys.y,true}},y0+1,y1,"key")
    end

    local function drawWaitPanel()
        clearPanel(); state.boxes={}; local y0,y1=panelRows()
        fillLine(native,y0,"Continue",colors.black,colors.lightGray)
        state.focus=1
        drawActions({{"Continue",keys.enter,true}},y0+1,y1,"key")
    end

    local function drawEntropyPanel()
        clearPanel(); state.boxes={}; local y0,y1=panelRows()
        fillLine(native,y0,"Entropy setup",colors.black,colors.lightGray)
        fillLine(native,y0+1,"Tap panel repeatedly: "..tostring(state.entropyRemaining),colors.white,colors.gray)
        for y=y0+1,y1 do
            state.boxes[#state.boxes+1]={x1=1,x2=nativeW,y=y,kind="entropy",label="entropy"}
        end
    end

    local function drawPanel()
        if state.mode=="input" then drawInputPanel()
        elseif state.mode=="confirm" then drawConfirmPanel()
        elseif state.mode=="wait" then drawWaitPanel()
        elseif state.mode=="entropy" then drawEntropyPanel()
        else drawNormalPanel() end
    end

    local rawPrint,rawWrite,rawTerm,rawOs=print,write,term,os
    local termProxy=setmetatable({}, {__index=rawTerm})
    local osProxy=setmetatable({}, {__index=rawOs})
    local env=setmetatable({term=termProxy,os=osProxy}, {__index=_G})

    local capturedKeys={
        [keys.up]=true,[keys.down]=true,[keys.left]=true,[keys.right]=true,
        [keys.enter]=true,[keys.escape]=true,
    }

    local function corePullEvent(raw,filter)
        local pull=raw and rawOs.pullEventRaw or rawOs.pullEvent
        while true do
            local ev={pull()}
            local name=ev[1]
            if name=="pointer_action" then
                if not filter or filter=="key" then return "key",ev[2],false end
            elseif name=="key" and state.mode~="input" and state.mode~="entropy" and capturedKeys[ev[2]] then
                -- Physical navigation belongs to the pointer focus layer. Swallow it for the legacy core.
            elseif not filter or name==filter then
                return (table.unpack or unpack)(ev)
            end
        end
    end

    osProxy.pullEvent=function(filter) return corePullEvent(false,filter) end
    osProxy.pullEventRaw=function(filter) return corePullEvent(true,filter) end

    termProxy.clear=function(...)
        if state.mode=="confirm" or state.mode=="wait" then setMode("normal") end
        local result=rawTerm.clear(...); drawPanel(); return result
    end

    env.write=function(value)
        local s=tostring(value or "")
        if s:find(":%s*$") or s:find("%[[^%]]+%]%s*:%s*$") then state.lastPrompt=s end
        return rawWrite(value)
    end

    env.print=function(...)
        local parts={}; for i=1,select("#",...) do parts[#parts+1]=tostring(select(i,...)) end
        local joined=table.concat(parts,"\t")
        local previous=state.lastPrinted
        local result=rawPrint(...)
        if joined:find("Y=CONFIRM",1,true) then
            local prior=string.lower(tostring(previous or ""))
            local confirmByDefault=(prior:match("^%s*start%s")~=nil) or (prior:match("^%s*benchmark%s")~=nil)
            setMode("confirm",confirmByDefault and 2 or 1); drawPanel()
        elseif joined:find("Press varied keys 24 times",1,true) then setMode("entropy"); state.entropyRemaining=24; drawPanel()
        elseif joined:find("Press any key",1,true) or joined:find("Press ENTER",1,true) then setMode("wait"); drawPanel() end
        state.lastPrinted=joined
        return result
    end

    env.read=function(replaceChar,history,completeFn,defaultText)
        local prompt=state.lastPrompt or "Input"; state.lastPrompt=nil
        local default=parseDefault(prompt)
        if defaultText~=nil and tostring(defaultText)~="" then default=tostring(defaultText) end
        local spec=fieldSpec(prompt,default)
        local label=trim(prompt:gsub("%s*%[[^%]]+%]%s*:%s*$",""):gsub(":%s*$",""))
        local input={label=label,default=default,spec=spec}
        if spec.kind=="number" then input.value=clamp(tonumber(default) or spec.min or 0,spec.min,spec.max)
        else input.value=default or "" end
        state.input=input; setMode("input",spec.kind=="number" and 6 or 2); drawPanel()
        local typed=""

        local function finishInput(useDefault)
            local out
            if useDefault then
                out=tostring(input.default or "")
            elseif spec.kind=="number" then
                out=labelForValue(input.value,spec.decimals)
            else
                out=typed~="" and typed or tostring(input.value or input.default or "")
            end
            state.input=nil; setMode("normal"); drawPanel()
            return out
        end

        local function selectInputChoice(useOk)
            if spec.kind=="number" then state.focus=useOk and 6 or 5
            else state.focus=useOk and 2 or 1 end
            drawPanel()
        end

        local function adjustNumber(delta)
            input.value=clamp(input.value+delta,spec.min,spec.max)
            if spec.decimals and spec.decimals>0 then
                local scale=10^spec.decimals
                input.value=math.floor(input.value*scale+0.5)/scale
            else input.value=math.floor(input.value+0.5) end
            drawPanel()
        end

        while true do
            local e,a=rawOs.pullEvent()
            if e=="key" then
                if a==keys.up then
                    selectInputChoice(false)
                elseif a==keys.down then
                    selectInputChoice(true)
                elseif a==keys.enter then
                    local selected=state.boxes[state.focus]
                    return finishInput(selected and selected.value==keys.escape)
                elseif a==keys.escape then
                    return finishInput(true)
                elseif spec.kind=="number" then
                    local delta=0
                    if a==keys.left then delta=-spec.step
                    elseif a==keys.right then delta=spec.step
                    elseif a==keys.pageDown then delta=-spec.coarse
                    elseif a==keys.pageUp then delta=spec.coarse end
                    if delta~=0 then
                        adjustNumber(delta)
                    elseif a==keys.backspace and typed~="" then typed=typed:sub(1,-2) end
                elseif a==keys.backspace and typed~="" then
                    typed=typed:sub(1,-2); input.value=typed; drawPanel()
                end
            elseif e=="char" then
                local ch=tostring(a or "")
                if spec.kind=="number" then
                    if ch:match("[%d%.%-]") then
                        typed=typed..ch; local n=tonumber(typed)
                        if n then input.value=clamp(n,spec.min,spec.max); drawPanel() end
                    end
                else typed=typed..ch; input.value=typed; drawPanel() end
            end
        end
    end

    local function queueAction(code)
        rawOs.queueEvent("pointer_action",code)
    end

    local function queueInputKey(code)
        rawOs.queueEvent("key",code,false)
    end

    local function hit(x,y)
        for i,box in ipairs(state.boxes or {}) do
            if y==box.y and x>=box.x1 and x<=box.x2 then return box,i end
        end
        return nil,nil
    end

    local function activateBox(box)
        if not box then return end
        if box.kind=="action" then
            if box.value=="next_page" then
                state.page=(state.page%(#profile.pages))+1
                state.focus=1
                drawPanel()
            else
                queueAction(box.value)
            end
        elseif box.kind=="key" then
            if state.mode=="input" then queueInputKey(box.value) else queueAction(box.value) end
            if box.finishMode then setMode("normal"); drawPanel() end
        elseif box.kind=="entropy" and state.entropyRemaining>0 then
            local pseudo=1000+state.entropyRemaining
            queueInputKey(pseudo)
            state.entropyRemaining=state.entropyRemaining-1
            if state.entropyRemaining<=0 then setMode("normal") end
            drawPanel()
        end
    end

    local function moveFocusHorizontal(delta)
        local n=#state.boxes
        if n==0 then return end
        state.focus=((state.focus-1+delta)%n)+1
        drawPanel()
    end

    local function moveFocusVertical(direction)
        local n=#state.boxes
        if n==0 then return end
        local current=state.boxes[state.focus] or state.boxes[1]
        local cx=(current.x1+current.x2)/2
        local best,bestScore=nil,nil
        for i,box in ipairs(state.boxes) do
            local dy=(box.y-current.y)*direction
            if dy>0 then
                local bx=(box.x1+box.x2)/2
                local score=dy*1000+math.abs(bx-cx)
                if not bestScore or score<bestScore then best,bestScore=i,score end
            end
        end
        if not best then
            local targetY=direction>0 and math.huge or -math.huge
            for _,box in ipairs(state.boxes) do
                if direction>0 then targetY=math.min(targetY,box.y) else targetY=math.max(targetY,box.y) end
            end
            for i,box in ipairs(state.boxes) do
                if box.y==targetY then
                    local bx=(box.x1+box.x2)/2
                    local score=math.abs(bx-cx)
                    if not bestScore or score<bestScore then best,bestScore=i,score end
                end
            end
        end
        if best then state.focus=best; drawPanel() end
    end

    local function activateEscape()
        local preferred
        if state.mode=="confirm" then preferred=keys.n
        elseif state.mode=="wait" then preferred=keys.enter
        else preferred=keys.q end
        for i,box in ipairs(state.boxes) do
            if box.value==preferred then state.focus=i; drawPanel(); activateBox(box); return true end
        end
        return false
    end

    local function handleFocusKey(code)
        if state.mode=="input" or state.mode=="entropy" then return false end
        if code==keys.left then moveFocusHorizontal(-1); return true
        elseif code==keys.right then moveFocusHorizontal(1); return true
        elseif code==keys.up then moveFocusVertical(-1); return true
        elseif code==keys.down then moveFocusVertical(1); return true
        elseif code==keys.enter then activateBox(state.boxes[state.focus]); return true
        elseif code==keys.escape then return activateEscape() end
        return false
    end

    local function pointerLoop()
        drawPanel()
        while state.running do
            local e,a,b,c=rawOs.pullEvent(); local x,y
            if e=="mouse_click" then x,y=b,c
            elseif e=="monitor_touch" then x,y=b,c
            elseif e=="key" then handleFocusKey(a)
            elseif e=="term_resize" then drawPanel() end
            if x and y and y>childH then
                local box,index=hit(x,y)
                if box then
                    state.focus=index or state.focus
                    drawPanel()
                    activateBox(box)
                end
            end
        end
    end

    local function coreRunner()
        local old=term.redirect(child)
        local okCall,result=pcall(os.run,env,corePath)
        term.redirect(old)
        state.running=false
        if not okCall then logError(corePath,"os.run",result); error(result,0) end
        if result==false then logError(corePath,"core_return","os.run returned false"); error("Pointer core failed; see "..ERROR_LOG,0) end
    end

    local ok,err=pcall(function() parallel.waitForAny(coreRunner,pointerLoop) end)
    state.running=false
    term.redirect(native)
    safeColor(native,colors.white,colors.black)
    native.setCursorBlink(false)
    if not ok then logError(corePath,"host",err); error(err,0) end
end

Host.VERSION=HOST_VERSION
Host.ERROR_LOG=ERROR_LOG
return Host
