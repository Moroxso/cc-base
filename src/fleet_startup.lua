-- BASE Fleet startup hook. Installed as /startup/90_base_fleet.lua.
if fs.exists("/fleet_watchdog.lua") then
    shell.run("/fleet_watchdog.lua")
end
