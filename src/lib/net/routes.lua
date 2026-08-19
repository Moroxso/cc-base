local Address = require("lib.net.address")

local Routes = {}

Routes.VERSION = 1
Routes.DEFAULT_PATH = "/data/network/routes.json"

local function defaultData()
    return {
        version = Routes.VERSION,
        forwarding = false,
        defaultGateway = nil,
        routes = {}
    }
end

local function ensureParent(path)
    local dir = fs.getDir(path)

    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function validPrefix(prefix)
    return type(prefix) == "number" and
        prefix == math.floor(prefix) and
        prefix >= 0 and prefix <= 32
end

local function normalizeRoute(route)
    if type(route) ~= "table" then
        return nil
    end

    local prefix = math.floor(tonumber(route.prefix) or -1)

    if not validPrefix(prefix) then
        return nil
    end

    local network = route.network

    if not Address.isIPv4(network) then
        return nil
    end

    network = Address.networkAddress(network, prefix)

    if not network then
        return nil
    end

    local gateway = route.gateway

    if gateway ~= nil and gateway ~= "" then
        if not Address.isValid(gateway) then
            return nil
        end
    else
        gateway = nil
    end

    return {
        network = network,
        prefix = prefix,
        gateway = gateway,
        metric = math.max(0, math.floor(tonumber(route.metric) or 1)),
        name = type(route.name) == "string" and route.name:sub(1, 32) or ""
    }
end

function Routes.normalize(data)
    if type(data) ~= "table" then
        return defaultData()
    end

    local result = defaultData()
    result.forwarding = data.forwarding == true

    if Address.isValid(data.defaultGateway) then
        result.defaultGateway = data.defaultGateway
    end

    for _, route in ipairs(data.routes or {}) do
        local normalized = normalizeRoute(route)

        if normalized then
            table.insert(result.routes, normalized)
        end
    end

    table.sort(result.routes, function(a, b)
        if a.prefix ~= b.prefix then
            return a.prefix > b.prefix
        end

        if a.metric ~= b.metric then
            return a.metric < b.metric
        end

        return a.network < b.network
    end)

    return result
end

local function decode(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end

    local ok, data = pcall(textutils.unserializeJSON, raw)

    if not ok or type(data) ~= "table" then
        return nil
    end

    return Routes.normalize(data)
end

local function readPath(path)
    if not fs.exists(path) then
        return nil
    end

    local file = fs.open(path, "r")

    if not file then
        return nil
    end

    local raw = file.readAll()
    file.close()

    return decode(raw)
end

function Routes.load(path)
    path = path or Routes.DEFAULT_PATH

    local data = readPath(path)

    if data then
        return data
    end

    data = readPath(path .. ".bak")

    if data then
        return data
    end

    data = readPath(path .. ".tmp")

    if data then
        return data
    end

    return defaultData()
end

function Routes.save(data, path)
    path = path or Routes.DEFAULT_PATH
    data = Routes.normalize(data)
    ensureParent(path)

    local serialized = textutils.serializeJSON(data)
    local tempPath = path .. ".tmp"
    local backupPath = path .. ".bak"

    if fs.exists(tempPath) then
        fs.delete(tempPath)
    end

    local file = fs.open(tempPath, "w")

    if not file then
        return false, "route_temp_open_failed"
    end

    file.write(serialized)
    file.close()

    if not readPath(tempPath) then
        fs.delete(tempPath)
        return false, "route_temp_validation_failed"
    end

    if fs.exists(backupPath) then
        fs.delete(backupPath)
    end

    if fs.exists(path) then
        fs.move(path, backupPath)
    end

    fs.move(tempPath, path)

    if not readPath(path) then
        if fs.exists(path) then
            fs.delete(path)
        end

        if fs.exists(backupPath) then
            fs.move(backupPath, path)
        end

        return false, "route_commit_validation_failed"
    end

    if fs.exists(backupPath) then
        fs.delete(backupPath)
    end

    return true
end

function Routes.setForwarding(data, enabled)
    data = Routes.normalize(data)
    data.forwarding = enabled == true
    return data
end

function Routes.setDefaultGateway(data, gateway)
    data = Routes.normalize(data)

    if gateway == nil or gateway == "" then
        data.defaultGateway = nil
        return data, true
    end

    if not Address.isValid(gateway) then
        return data, false, "invalid_gateway"
    end

    data.defaultGateway = gateway
    return data, true
end

function Routes.add(data, route)
    data = Routes.normalize(data)
    local normalized = normalizeRoute(route)

    if not normalized then
        return data, false, "invalid_route"
    end

    for index, existing in ipairs(data.routes) do
        if existing.network == normalized.network and
            existing.prefix == normalized.prefix
        then
            data.routes[index] = normalized
            return Routes.normalize(data), true
        end
    end

    table.insert(data.routes, normalized)
    return Routes.normalize(data), true
end

function Routes.remove(data, network, prefix)
    data = Routes.normalize(data)
    prefix = math.floor(tonumber(prefix) or -1)

    if not validPrefix(prefix) or not Address.isIPv4(network) then
        return data, false
    end

    network = Address.networkAddress(network, prefix)

    for index, route in ipairs(data.routes) do
        if route.network == network and route.prefix == prefix then
            table.remove(data.routes, index)
            return data, true
        end
    end

    return data, false
end

function Routes.resolve(data, destination)
    data = Routes.normalize(data)

    if not Address.isValid(destination) then
        return nil, "invalid_destination"
    end

    local selected = nil

    for _, route in ipairs(data.routes) do
        if Address.matches(destination, route.network, route.prefix) then
            if not selected or
                route.prefix > selected.prefix or
                (route.prefix == selected.prefix and route.metric < selected.metric)
            then
                selected = route
            end
        end
    end

    local gateway = selected and selected.gateway or nil

    if not selected and data.defaultGateway and
        destination ~= data.defaultGateway
    then
        gateway = data.defaultGateway
    end

    local nextHop = gateway or destination
    local peerId, err = Address.toComputerId(nextHop)

    if peerId == nil then
        return nil, err
    end

    return {
        destination = destination,
        nextHop = nextHop,
        peerId = peerId,
        kind = gateway and "gateway" or "direct",
        route = selected
    }
end

return Routes
