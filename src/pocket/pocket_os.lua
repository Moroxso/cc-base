local VERSION = "0.23.0-alpha.4"
local RUNTIME_PATH = "/data/fleet_runtime.json"
local LEGACY_STARTUP = "/data/pocketbase_legacy_startup.lua"

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f=fs.open(path,"r"); if not f then return nil end
    local raw=f.readAll(); f.close()
    local ok,value=pcall(textutils.unserializeJSON,raw)
    return ok and type(value)=="table" and value or nil
end

local function line(y,text,color)
    local w=term.getSize()
    term.setCursorPos(1,y); term.setBackgroundColor(colors.black); term.setTextColor(color or colors.white)
    term.write(string.rep(" ",w)); term.setCursorPos(1,y); term.write(tostring(text):sub(1,w))
end

local function systemInfo()
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1)
    print("BASE Pocket System")
    print("Version: "..VERSION)
    print("Computer: #"..os.getComputerID())
    print("Label: "..tostring(os.getComputerLabel() or "-"))
    print("Free: "..tostring(fs.getFreeSpace("/")))
    local runtime=readJson(RUNTIME_PATH)
    print("Fleet runtime: "..tostring(runtime and runtime.version or "unknown"))
    local names={}
    for _,name in ipairs(peripheral.getNames()) do
        local ok,t=pcall(peripheral.getType,name)
        if ok and t=="modem" then names[#names+1]=name end
    end
    print("Modem: "..(#names>0 and table.concat(names,",") or "none"))
    print("")
    print("Press any key")
    os.pullEvent("key")
end

local function updateSelf()
    term.clear(); term.setCursorPos(1,1)
    print("Updating BASE Pocket...")
    if not fs.exists("/fleet_update.lua") then print("fleet_update.lua missing"); sleep(2); return end
    local ok=shell.run("/fleet_update.lua","update","pocket")
    if ok~=false then print("Updated. Rebooting..."); sleep(0.5); os.reboot() end
    print("Update failed"); sleep(2)
end

local items={
    {name="Fleet Control",run=function() shell.run("/fleet_control.lua") end},
    {name="Fleet Jobs",run=function() shell.run("/fleet_jobs.lua") end},
    {name="Fleet Update",run=updateSelf},
    {name="System Info",run=systemInfo},
    {name="Shell",run=function() shell.run("shell") end},
}
if fs.exists(LEGACY_STARTUP) then
    items[#items+1]={name="Legacy BASE",run=function() shell.run(LEGACY_STARTUP) end}
end
items[#items+1]={name="Reboot",run=function() os.reboot() end}
items[#items+1]={name="Shutdown",run=function() os.shutdown() end}

local selected=1
local function draw()
    local w,h=term.getSize()
    term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
    term.setCursorPos(1,1); term.setBackgroundColor(colors.blue); term.write(string.rep(" ",w)); term.setCursorPos(2,1); term.setTextColor(colors.white); term.write("BASE POCKET")
    line(2,"v"..VERSION.."  #"..os.getComputerID(),colors.lightGray)
    local first=4
    local visible=math.max(1,h-6)
    local start=math.max(1,math.min(selected-math.floor(visible/2),math.max(1,#items-visible+1)))
    for row=0,visible-1 do
        local idx=start+row
        if items[idx] then
            local mark=idx==selected and "> " or "  "
            line(first+row,mark..items[idx].name,idx==selected and colors.cyan or colors.white)
        end
    end
    line(h-1,"UP/DOWN ENTER   U update",colors.lightGray)
end

while true do
    draw()
    local e,a=os.pullEvent()
    if e=="key" then
        if a==keys.up then selected=selected==1 and #items or selected-1
        elseif a==keys.down then selected=selected==#items and 1 or selected+1
        elseif a==keys.enter then
            term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1)
            local ok,err=pcall(items[selected].run)
            if not ok then print("App error: "..tostring(err)); sleep(2) end
        elseif a==keys.u or a==keys.f5 then updateSelf() end
    elseif e=="term_resize" then draw() end
end
