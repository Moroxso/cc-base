local ok, err =
    pcall(
        function()
            shell.run("/main.lua")
        end
    )

if not ok then
    term.setBackgroundColor(
        colors.black
    )

    term.setTextColor(
        colors.red
    )

    term.clear()
    term.setCursorPos(1, 1)

    print("BOOT ERROR")
    print("")
    print(err)
    print("")
    print(
        "Type 'update' or edit files."
    )
end