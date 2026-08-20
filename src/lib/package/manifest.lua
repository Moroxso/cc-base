local Manifest = {}

Manifest.SCHEMA = 1

local function isInteger(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
end

local function validId(value)
    return type(value) == "string"
        and value ~= ""
        and value:match("^[a-z0-9][a-z0-9%._%-]*$") ~= nil
end

local function validRelativePath(value)
    return type(value) == "string"
        and value ~= ""
        and value:sub(1, 1) ~= "/"
        and not value:find("..", 1, true)
end

local function copyArray(source)
    local result = {}

    for index, value in ipairs(source or {}) do
        result[index] = value
    end

    return result
end

local function normalizeFile(item, packageId, index)
    if type(item) ~= "table" then
        return nil, "package_file_not_table:" .. packageId .. ":" .. tostring(index)
    end

    if not validRelativePath(item.source) then
        return nil, "package_file_source_invalid:" .. packageId .. ":" .. tostring(index)
    end

    if not validRelativePath(item.target) then
        return nil, "package_file_target_invalid:" .. packageId .. ":" .. tostring(index)
    end

    if item.size ~= nil and not isInteger(item.size) then
        return nil, "package_file_size_invalid:" .. packageId .. ":" .. tostring(index)
    end

    if item.hash ~= nil and (type(item.hash) ~= "string" or item.hash == "") then
        return nil, "package_file_hash_invalid:" .. packageId .. ":" .. tostring(index)
    end

    return {
        source = item.source,
        target = item.target,
        size = item.size,
        hash = item.hash
    }
end

local function normalizePackage(item, index)
    if type(item) ~= "table" then
        return nil, "package_not_table:" .. tostring(index)
    end

    if not validId(item.id) then
        return nil, "package_id_invalid:" .. tostring(index)
    end

    if type(item.name) ~= "string" or item.name == "" then
        return nil, "package_name_invalid:" .. item.id
    end

    if type(item.version) ~= "string" or item.version == "" then
        return nil, "package_version_invalid:" .. item.id
    end

    local managedBy = item.managedBy or "package"

    if managedBy ~= "package" and managedBy ~= "deploy" then
        return nil, "package_manager_invalid:" .. item.id
    end

    if item.entrypoint ~= nil and not validRelativePath(item.entrypoint) then
        return nil, "package_entrypoint_invalid:" .. item.id
    end

    local dependencies = {}

    for dependencyIndex, dependency in ipairs(item.dependencies or {}) do
        if not validId(dependency) then
            return nil,
                "package_dependency_invalid:"
                .. item.id
                .. ":"
                .. tostring(dependencyIndex)
        end

        dependencies[#dependencies + 1] = dependency
    end

    local files = {}
    local declaredSize = 0
    local allSizesKnown = true

    for fileIndex, fileItem in ipairs(item.files or {}) do
        local file, err = normalizeFile(fileItem, item.id, fileIndex)

        if not file then
            return nil, err
        end

        files[#files + 1] = file

        if file.size == nil then
            allSizesKnown = false
        else
            declaredSize = declaredSize + file.size
        end
    end

    local installedSize = item.installedSize

    if installedSize ~= nil and not isInteger(installedSize) then
        return nil, "package_installed_size_invalid:" .. item.id
    end

    if installedSize == nil and allSizesKnown then
        installedSize = declaredSize
    end

    return {
        id = item.id,
        name = item.name,
        version = item.version,
        type = type(item.type) == "string" and item.type or "application",
        managedBy = managedBy,
        required = item.required == true,
        legacyBundled = item.legacyBundled == true,
        entrypoint = item.entrypoint,
        dependencies = copyArray(dependencies),
        files = files,
        installedSize = installedSize
    }
end

function Manifest.validateCatalog(value)
    if type(value) ~= "table" then
        return nil, "package_catalog_not_table"
    end

    if value.schema ~= Manifest.SCHEMA then
        return nil, "package_catalog_schema_unsupported"
    end

    if type(value.packages) ~= "table" then
        return nil, "package_catalog_packages_missing"
    end

    local result = {
        schema = Manifest.SCHEMA,
        generatedFor = tostring(value.generatedFor or "unknown"),
        hashAlgorithm = tostring(value.hashAlgorithm or "none"),
        packages = {},
        byId = {}
    }

    for index, item in ipairs(value.packages) do
        local packageItem, err = normalizePackage(item, index)

        if not packageItem then
            return nil, err
        end

        if result.byId[packageItem.id] then
            return nil, "package_catalog_duplicate_id:" .. packageItem.id
        end

        result.packages[#result.packages + 1] = packageItem
        result.byId[packageItem.id] = packageItem
    end

    return result
end

function Manifest.load(path)
    if type(path) ~= "string" or path == "" then
        return nil, "package_catalog_path_invalid"
    end

    if not fs.exists(path) or fs.isDir(path) then
        return nil, "package_catalog_missing"
    end

    local file = fs.open(path, "r")

    if not file then
        return nil, "package_catalog_open_failed"
    end

    local raw = file.readAll()
    file.close()

    local ok, value = pcall(textutils.unserializeJSON, raw)

    if not ok or type(value) ~= "table" then
        return nil, "package_catalog_json_invalid"
    end

    return Manifest.validateCatalog(value)
end

return Manifest
