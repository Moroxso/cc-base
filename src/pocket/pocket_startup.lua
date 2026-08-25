if fs.exists("/fleet_watchdog.lua") then
    shell.run("/fleet_watchdog.lua")
else
    print("BASE Pocket watchdog missing. Run fleet_update repair pocket.")
end
