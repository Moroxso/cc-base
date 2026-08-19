local ui = {}

function ui.resetColors(target)
    target = target or term

    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
end

function ui.clear(target)
    target = target or term

    ui.resetColors(target)
    target.clear()
    target.setCursorPos(1, 1)
end

function ui.centerText(target, y, text, textColor, backgroundColor)
    target = target or term

    local width = target.getSize()

    if backgroundColor then
        target.setBackgroundColor(backgroundColor)
    end

    if textColor then
        target.setTextColor(textColor)
    end

    local x = math.floor(
        (width - #text) / 2
    ) + 1

    target.setCursorPos(x, y)
    target.write(text)
end

function ui.fillLine(target, y, backgroundColor)
    target = target or term

    local width = target.getSize()

    target.setBackgroundColor(
        backgroundColor or colors.black
    )

    target.setCursorPos(1, y)
    target.write(string.rep(" ", width))
end

function ui.drawHeader(title)
    local width = term.getSize()

    ui.resetColors(term)
    term.clear()

    term.setBackgroundColor(colors.blue)

    for y = 1, 3 do
        term.setCursorPos(1, y)
        term.write(string.rep(" ", width))
    end

    ui.centerText(
        term,
        2,
        title,
        colors.white,
        colors.blue
    )

    ui.resetColors(term)
end

function ui.drawFooter(text)
    local width, height = term.getSize()

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)

    term.setCursorPos(1, height)
    term.write(string.rep(" ", width))

    ui.centerText(
        term,
        height,
        text,
        colors.white,
        colors.gray
    )

    ui.resetColors(term)
end

return ui