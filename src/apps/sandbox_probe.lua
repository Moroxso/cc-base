local checks = {}

local function add(name, ok, detail)
    table.insert(checks, {
        name = name,
        ok = ok == true,
        detail = tostring(detail or "")
    })
end

add("shell blocked", shell == nil, type(shell))
add("http blocked", http == nil, type(http))
add("rednet blocked", rednet == nil, type(rednet))
add("peripheral blocked", peripheral == nil, type(peripheral))
add("require blocked", require == nil, type(require))
add("loadfile blocked", loadfile == nil and dofile == nil and load == nil, "dynamic loaders")
add(
    "system control blocked",
    os.reboot == nil and os.shutdown == nil and os.run == nil and os.queueEvent == nil,
    "os privileged functions"
)
add("sandbox metadata", sandbox and sandbox.hostFilesystem == false, sandbox and sandbox.id or "missing")

local startup = fs.open("/startup.lua", "w")
local startupVirtual = startup ~= nil

if startup then
    startup.write("sandbox-only probe")
    startup.close()
end

add(
    "system path virtualized",
    startupVirtual and fs.exists("/startup.lua"),
    "virtual /startup.lua"
)

local dataFile = fs.open("/data/automation.json", "w")
local dataVirtual = dataFile ~= nil

if dataFile then
    dataFile.write("sandbox-only data")
    dataFile.close()
end

add(
    "data path virtualized",
    dataVirtual and fs.exists("/data/automation.json"),
    "virtual /data/automation.json"
)

local traversalBlocked = not pcall(function()
    fs.open("/../startup.lua", "w")
end)
add("parent traversal blocked", traversalBlocked, ".. denied")

local passed = 0

for _, item in ipairs(checks) do
    if item.ok then
        passed = passed + 1
    end
end

local report = {
    version = sandbox and sandbox.version or 0,
    sandboxId = sandbox and sandbox.id or "unknown",
    passed = passed,
    total = #checks,
    checks = checks
}

local file = fs.open("/report.json", "w")

if not file then
    error("Cannot write sandbox report")
end

file.write(textutils.serializeJSON(report))
file.close()
