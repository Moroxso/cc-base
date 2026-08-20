local StorageManager = require("lib.system.storage_manager")

local Inspector = {}

local function lower(value)
    return string.lower(tostring(value or ""))
end

function Inspector.search(manager, root, query, options)
    manager = manager or StorageManager.new()
    options = type(options) == "table" and options or {}
    root = StorageManager.normalizePath(root or "/")
    query = lower(query)

    if query == "" then return nil, "search_query_empty" end
    if not fs.exists(root) or not fs.isDir(root) then
        return nil, "search_root_invalid"
    end

    local limit = math.max(1, math.min(tonumber(options.limit) or 80, 200))
    local maxDepth = math.max(1, math.min(tonumber(options.maxDepth) or 16, 32))
    local results = {}
    local stack = {{path = root, depth = 0}}
    local visited = 0

    while #stack > 0 and #results < limit do
        local node = table.remove(stack)
        local entries = manager:list(node.path)
        visited = visited + 1

        if type(entries) == "table" then
            for index = #entries, 1, -1 do
                local entry = entries[index]
                if lower(entry.name):find(query, 1, true) then
                    results[#results + 1] = entry
                    if #results >= limit then break end
                end

                if entry.isDir and node.depth < maxDepth then
                    stack[#stack + 1] = {
                        path = entry.path,
                        depth = node.depth + 1
                    }
                end
            end
        end
    end

    table.sort(results, function(a, b)
        return lower(a.path) < lower(b.path)
    end)

    return results, nil, {
        root = root,
        query = query,
        limit = limit,
        truncated = #results >= limit,
        directoriesVisited = visited
    }
end

function Inspector.ownership(manager, prefix, limit)
    manager = manager or StorageManager.new()
    manager:refreshOwnership()
    prefix = StorageManager.normalizePath(prefix or "/")
    limit = math.max(1, math.min(tonumber(limit) or 100, 300))

    local result = {}
    for path, owner in pairs(manager.owned or {}) do
        if prefix == "/"
            or path == prefix
            or path:sub(1, #prefix + 1) == prefix .. "/"
        then
            result[#result + 1] = {path = path, owner = owner}
        end
    end

    table.sort(result, function(a, b) return a.path < b.path end)

    local truncated = #result > limit
    while #result > limit do table.remove(result) end
    return result, truncated
end

function Inspector.cleanupReport()
    local coreJournal = "/data/system/update-journal.json"
    local packageJournal = "/data/system/package-journal.json"
    local activeTransaction = fs.exists(coreJournal)
        or fs.exists(coreJournal .. ".bak")
        or fs.exists(coreJournal .. ".tmp")
        or fs.exists(packageJournal)
        or fs.exists(packageJournal .. ".bak")
        or fs.exists(packageJournal .. ".tmp")

    local candidates = {
        {path = "/.cc_update_stage", kind = "legacy-stage"},
        {path = "/.cc_updater_next.lua", kind = "updater-next"},
        {path = "/.cc_updater_prev.lua", kind = "updater-prev"}
    }

    local present = {}
    for _, item in ipairs(candidates) do
        if fs.exists(item.path) then
            present[#present + 1] = item
        end
    end

    return {
        activeTransaction = activeTransaction,
        candidates = present,
        safeToRunUpdaterCleanup = not activeTransaction
    }
end

return Inspector
