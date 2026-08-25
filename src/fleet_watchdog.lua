local PROFILE_PATH = "/data/fleet_profile.json"
local FORCE_UPDATE_PATH = "/data/fleet_force_update"

local function readJson(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f=fs.open(path,"r"); if not f then return nil end
    local raw=f.readAll(); f.close(); local ok,value=pcall(textutils.unserializeJSON,raw)
    return ok and type(value)=="table" and value or nil
end

local profile=readJson(PROFILE_PATH)
if not profile or type(profile.profile)~="string" then
    print("BASE Fleet: profile not configured. Run fleet_update install <profile>.")
    return
end

local PROGRAMS={assault="/assault_agent.lua",relay="/assault_agent.lua",pocket="/pocket_os.lua"}
local program=PROGRAMS[profile.profile]
if not program then print("BASE Fleet: unknown profile "..tostring(profile.profile)); return end

local function runUpdater(force)
    if not fs.exists("/fleet_update.lua") then return false end
    local action=force and "repair" or "update"
    return shell.run("/fleet_update.lua",action,profile.profile,"--quiet")~=false
end

local forced=fs.exists(FORCE_UPDATE_PATH)
if forced then pcall(fs.delete,FORCE_UPDATE_PATH) end
pcall(runUpdater,forced)

while true do
    if not fs.exists(program) then pcall(runUpdater,true) end
    local ok,err=pcall(function() return shell.run(program) end)
    if not ok then print("Fleet runtime crashed: "..tostring(err)) end
    sleep(1)
    if fs.exists(FORCE_UPDATE_PATH) then
        pcall(fs.delete,FORCE_UPDATE_PATH)
        pcall(runUpdater,true)
    else
        pcall(runUpdater,false)
    end
end
