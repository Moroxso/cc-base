local loader, err = loadfile("/lib/pocket/pointer_host.lua", "t", _ENV)
if not loader then error(err, 0) end
local Host = loader()
Host.run("/fleet_performance_core.lua", "performance")
