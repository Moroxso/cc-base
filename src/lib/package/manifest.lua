local Manifest = {}

Manifest.SCHEMA = 1
Manifest.DEFAULT_DEPLOY_PATH = "/deploy.json"

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

local function validCommit(value)
    return type(value) == "string"
        and value:match("^[0-9a-fA-F]+$") ~= nil
        and (#value == 40 or #value == 64)
end

local function validHash(value, algorithm)
    if type(value) ~= "string" or value == "" then
        return false
    end

    if algorithm == "git-blob-sha1" then
        return #value == 40 and value:match("^[0-9a-fA-F]+$") ~= nil
    end

    return true
end

local function readJson(path)
    if type(path) ~= "string" or path == "" or not fs.exists(path) or fs.isDir(path) then
        return nil
    end

    local file = fs.open(path, "r")
    if not file then return nil end
    local raw = file.readAll()
    file.close()

    local ok, value = pcall(textutils.unserializeJSON, raw)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

local function copyArray(source)
    local result = {}
    for index, value in ipairs(source or {}) do result[index] = value end
    return result
end

local function normalizeFile(item, packageId, index, hashAlgorithm)
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
    if item.hash ~= nil and not validHash(item.hash, hashAlgorithm) then
        return nil, "package_file_hash_invalid:" .. packageId .. ":" .. tostring(index)
    end

    return {
        source = item.source,
        target = item.target,
        size = item.size,
        hash = item.hash and string.lower(item.hash) or nil
    }
end

local function normalizePackage(item, index, hashAlgorithm)
    if type(item) ~= "table" then return nil, "package_not_table:" .. tostring(index) end
    if not validId(item.id) then return nil, "package_id_invalid:" .. tostring(index) end
    if type(item.name) ~= "string" or item.name == "" then return nil, "package_name_invalid:" .. item.id end
    if type(item.version) ~= "string" or item.version == "" then return nil, "package_version_invalid:" .. item.id end

    local managedBy = item.managedBy or "package"
    if managedBy ~= "package" and managedBy ~= "deploy" then
        return nil, "package_manager_invalid:" .. item.id
    end
    if item.entrypoint ~= nil and not validRelativePath(item.entrypoint) then
        return nil, "package_entrypoint_invalid:" .. item.id
    end

    local dependencies = {}
    local dependencySeen = {}
    for dependencyIndex, dependency in ipairs(item.dependencies or {}) do
        if not validId(dependency) then
            return nil, "package_dependency_invalid:" .. item.id .. ":" .. tostring(dependencyIndex)
        end
        if dependency == item.id then return nil, "package_dependency_self:" .. item.id end
        if dependencySeen[dependency] then
            return nil, "package_dependency_duplicate:" .. item.id .. ":" .. dependency
        end
        dependencySeen[dependency] = true
        dependencies[#dependencies + 1] = dependency
    end

    local files = {}
    local fileTargets = {}
    local declaredSize = 0
    local allSizesKnown = true

    for fileIndex, fileItem in ipairs(item.files or {}) do
        local file, err = normalizeFile(fileItem, item.id, fileIndex, hashAlgorithm)
        if not file then return nil, err end
        if fileTargets[file.target] then
            return nil, "package_file_target_duplicate:" .. item.id .. ":" .. file.target
        end
        fileTargets[file.target] = true
        files[#files + 1] = file
        if file.size == nil then allSizesKnown = false else declaredSize = declaredSize + file.size end
    end

    local installedSize = item.installedSize
    if installedSize ~= nil and not isInteger(installedSize) then
        return nil, "package_installed_size_invalid:" .. item.id
    end
    if installedSize == nil and allSizesKnown then installedSize = declaredSize end
    if installedSize ~= nil and allSizesKnown and installedSize ~= declaredSize then
        return nil, "package_installed_size_mismatch:" .. item.id
    end

    if managedBy == "package" then
        for fileIndex, file in ipairs(files) do
            if file.size == nil or file.hash == nil then
                return nil, "package_file_integrity_missing:" .. item.id .. ":" .. tostring(fileIndex)
            end
        end
        if item.entrypoint and not fileTargets[item.entrypoint] then
            return nil, "package_entrypoint_not_owned:" .. item.id .. ":" .. item.entrypoint
        end
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

local function validateDependencyGraph(result)
    local state = {}
    local stack = {}
    local stackIndex = {}

    local function visit(id)
        if state[id] == 2 then return true end
        if state[id] == 1 then
            local cycle = {}
            local first = stackIndex[id] or 1
            for index = first, #stack do cycle[#cycle + 1] = stack[index] end
            cycle[#cycle + 1] = id
            return false, "package_dependency_cycle:" .. table.concat(cycle, "->")
        end

        state[id] = 1
        stack[#stack + 1] = id
        stackIndex[id] = #stack

        local packageItem = result.byId[id]
        for _, dependency in ipairs(packageItem.dependencies or {}) do
            local ok, err = visit(dependency)
            if not ok then return false, err end
        end

        stackIndex[id] = nil
        stack[#stack] = nil
        state[id] = 2
        return true
    end

    for _, packageItem in ipairs(result.packages) do
        local ok, err = visit(packageItem.id)
        if not ok then return false, err end
    end
    return true
end

local function validateTargetOwnership(result)
    local owners = {}
    for _, packageItem in ipairs(result.packages) do
        for _, file in ipairs(packageItem.files or {}) do
            local owner = owners[file.target]
            if owner and owner ~= packageItem.id then
                return false, "package_target_shared:" .. file.target .. ":" .. owner .. ":" .. packageItem.id
            end
            owners[file.target] = packageItem.id
        end
    end
    result.targetOwners = owners
    return true
end

function Manifest.validateCatalog(value)
    if type(value) ~= "table" then return nil, "package_catalog_not_table" end
    if value.schema ~= Manifest.SCHEMA then return nil, "package_catalog_schema_unsupported" end
    if type(value.packages) ~= "table" then return nil, "package_catalog_packages_missing" end

    local hashAlgorithm = tostring(value.hashAlgorithm or "none")
    local sourceCommit = value.sourceCommit
    if hashAlgorithm ~= "git-blob-sha1" then return nil, "package_catalog_hash_unsupported" end
    if not validCommit(sourceCommit) then return nil, "package_catalog_source_commit_invalid" end

    local result = {
        schema = Manifest.SCHEMA,
        generatedFor = tostring(value.generatedFor or "unknown"),
        hashAlgorithm = hashAlgorithm,
        sourceCommit = string.lower(sourceCommit),
        packages = {},
        byId = {},
        targetOwners = {}
    }

    for index, item in ipairs(value.packages) do
        local packageItem, err = normalizePackage(item, index, hashAlgorithm)
        if not packageItem then return nil, err end
        if result.byId[packageItem.id] then return nil, "package_catalog_duplicate_id:" .. packageItem.id end
        result.packages[#result.packages + 1] = packageItem
        result.byId[packageItem.id] = packageItem
    end

    for _, packageItem in ipairs(result.packages) do
        for _, dependency in ipairs(packageItem.dependencies) do
            if not result.byId[dependency] then
                return nil, "package_dependency_missing:" .. packageItem.id .. ":" .. dependency
            end
        end
    end

    local ownershipOk, ownershipError = validateTargetOwnership(result)
    if not ownershipOk then return nil, ownershipError end
    local graphOk, graphError = validateDependencyGraph(result)
    if not graphOk then return nil, graphError end
    return result
end

function Manifest.validateAgainstDeploy(catalog, deployPath)
    deployPath = deployPath or Manifest.DEFAULT_DEPLOY_PATH
    local deploy = readJson(deployPath)
    if not deploy or type(deploy.files) ~= "table" then
        return false, "package_deploy_manifest_unavailable"
    end

    local protected = {}
    for index, item in ipairs(deploy.files) do
        if type(item) ~= "table" or not validRelativePath(item.target) then
            return false, "package_deploy_target_invalid:" .. tostring(index)
        end
        protected[item.target] = true
    end

    for _, packageItem in ipairs(catalog.packages or {}) do
        if packageItem.managedBy == "package" then
            for _, file in ipairs(packageItem.files or {}) do
                if protected[file.target] then
                    return false, "package_target_conflicts_core:" .. packageItem.id .. ":" .. file.target
                end
            end
        end
    end

    return true
end

function Manifest.load(path)
    if type(path) ~= "string" or path == "" then return nil, "package_catalog_path_invalid" end
    if not fs.exists(path) or fs.isDir(path) then return nil, "package_catalog_missing" end

    local file = fs.open(path, "r")
    if not file then return nil, "package_catalog_open_failed" end
    local raw = file.readAll()
    file.close()

    local ok, value = pcall(textutils.unserializeJSON, raw)
    if not ok or type(value) ~= "table" then return nil, "package_catalog_json_invalid" end

    local catalog, err = Manifest.validateCatalog(value)
    if not catalog then return nil, err end

    local deployOk, deployError = Manifest.validateAgainstDeploy(catalog, Manifest.DEFAULT_DEPLOY_PATH)
    if not deployOk then return nil, deployError end
    return catalog
end

return Manifest
