local UPDATE_JOURNAL = "/data/system/update-journal.json"

local function showBootError(message)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)

    print("BOOT ERROR")
    print("")
    print(tostring(message or "unknown error"))
    print("")
    print("Try 'update --recover' or the rescue updater.")
end

local function boot()
    if fs.exists(UPDATE_JOURNAL) then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.orange)
        term.clear()
        term.setCursorPos(1, 1)
        print("CORE UPDATE RECOVERY")
        print("")

        local recovered = shell.run("/update.lua", "--recover")

        if recovered == false or fs.exists(UPDATE_JOURNAL) then
            error("Core update recovery did not complete", 0)
        end
    end

    local started = shell.run("/main.lua")

    if started == false then
        error("main.lua failed to start", 0)
    end
end

local ok, err = pcall(boot)

if not ok then
    showBootError(err)
end
