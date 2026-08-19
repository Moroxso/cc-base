local Pieces = {}

local order = {
    "I",
    "O",
    "T",
    "S",
    "Z",
    "J",
    "L"
}

local definitions = {
    I = {
        color = colors.cyan,
        rotations = {
            {{0,1},{1,1},{2,1},{3,1}},
            {{2,0},{2,1},{2,2},{2,3}},
            {{0,2},{1,2},{2,2},{3,2}},
            {{1,0},{1,1},{1,2},{1,3}}
        }
    },
    O = {
        color = colors.yellow,
        rotations = {
            {{1,0},{2,0},{1,1},{2,1}},
            {{1,0},{2,0},{1,1},{2,1}},
            {{1,0},{2,0},{1,1},{2,1}},
            {{1,0},{2,0},{1,1},{2,1}}
        }
    },
    T = {
        color = colors.purple,
        rotations = {
            {{1,0},{0,1},{1,1},{2,1}},
            {{1,0},{1,1},{2,1},{1,2}},
            {{0,1},{1,1},{2,1},{1,2}},
            {{1,0},{0,1},{1,1},{1,2}}
        }
    },
    S = {
        color = colors.lime,
        rotations = {
            {{1,0},{2,0},{0,1},{1,1}},
            {{1,0},{1,1},{2,1},{2,2}},
            {{1,1},{2,1},{0,2},{1,2}},
            {{0,0},{0,1},{1,1},{1,2}}
        }
    },
    Z = {
        color = colors.red,
        rotations = {
            {{0,0},{1,0},{1,1},{2,1}},
            {{2,0},{1,1},{2,1},{1,2}},
            {{0,1},{1,1},{1,2},{2,2}},
            {{1,0},{0,1},{1,1},{0,2}}
        }
    },
    J = {
        color = colors.blue,
        rotations = {
            {{0,0},{0,1},{1,1},{2,1}},
            {{1,0},{2,0},{1,1},{1,2}},
            {{0,1},{1,1},{2,1},{2,2}},
            {{1,0},{1,1},{0,2},{1,2}}
        }
    },
    L = {
        color = colors.orange,
        rotations = {
            {{2,0},{0,1},{1,1},{2,1}},
            {{1,0},{1,1},{1,2},{2,2}},
            {{0,1},{1,1},{2,1},{0,2}},
            {{0,0},{1,0},{1,1},{1,2}}
        }
    }
}

function Pieces.getKinds()
    return order
end

function Pieces.get(kind)
    return definitions[kind]
end

function Pieces.getCells(kind, rotation)
    local definition = definitions[kind]

    if not definition then
        return {}
    end

    rotation = ((rotation or 1) - 1) % 4 + 1
    return definition.rotations[rotation]
end

function Pieces.getColor(kind)
    local definition = definitions[kind]
    return definition and definition.color or colors.white
end

function Pieces.randomKind()
    return order[math.random(1, #order)]
end

function Pieces.createBag()
    local bag = {}

    for i, kind in ipairs(order) do
        bag[i] = kind
    end

    for i = #bag, 2, -1 do
        local j = math.random(1, i)
        bag[i], bag[j] = bag[j], bag[i]
    end

    return bag
end

return Pieces
