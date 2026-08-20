local Manifest = require("lib.package.manifest")
local Registry = require("lib.package.registry")
local Storage = require("lib.package.storage")

local Manager = {}
Manager.__index = Manager

Manager.DEFAULT_CATALOG_PATH = "/packages.json"
Manager.DEFAULT_REGISTRY_PATH = Registry.DEFAULT_PATH
Manager.VERSION_PATH = "/.project-version"

local function readAll(path)
    if not fs.exists(path) or fs.isDir(path) then
        return nil
    end

    local file = fs.open(path, "r")

    if not file then
        return nil
    end

    local content = file.readAll()
    file.close()
    return content
end

local function hashString(content)
    local hash = 5381

    for index = 1, #content do
        hash = (hash * 33 + string.byte(content, index)) % 4294967296
    end

    return string.format("%08x", hash)
end

local function absoluteTarget(target)
    return "/" .. tostring(target or ""):gsub("^/+", "")
end

function Manager.new(options)
    options = type(options) == "table" and options or {}

    return setmetatable({
        catalogPath = options.catalogPath or Manager.DEFAULT_CATALOG_PATH,
        registryPath = options.registryPath or Manager.DEFAULT_REGISTRY_PATH,
        catalog = nil,
        registry = nil,
        registryExisted = false
    }, Manager)
end

function Manager:loadCatalog(force)
    if self.catalog and not force then
        return self.catalog
    end

    local catalog, err = Manifest.load(self.catalogPath)

    if not catalog then
        return nil, err
    end

    self.catalog = catalog
    return catalog
end

function Manager:loadRegistry(force)
    if self.registry and not force then
        return self.registry, self.registryExisted
    end

    local registry, existedOrError = Registry.load(self.registryPath)

    if not registry then
        return nil, existedOrError
    end

    self.registry = registry
    self.registryExisted = existedOrError == true
    return registry, self.registryExisted
end

function Manager:saveRegistry()
    if not self.registry then
        return false, "package_registry_not_loaded"
    end

    local ok, err = Registry.save(self.registry, self.registryPath)

    if ok then
        self.registryExisted = true
    end

    return ok, err
end

function Manager:getPackage(id)
    local catalog, err = self:loadCatalog()

    if not catalog then
        return nil, err
    end

    local packageItem = catalog.byId[id]

    if not packageItem then
        return nil, "package_not_found:" .. tostring(id)
    end

    return packageItem
end

function Manager:listAvailable()
    local catalog, err = self:loadCatalog()

    if not catalog then
        return nil, err
    end

    local result = {}

    for _, packageItem in ipairs(catalog.packages) do
        result[#result + 1] = packageItem
    end

    table.sort(result, function(a, b)
        return a.id < b.id
    end)

    return result
end

function Manager:listInstalled()
    local registry, err = self:loadRegistry()

    if not registry then
        return nil, err
    end

    return Registry.listInstalled(registry)
end

function Manager:isInstalled(id)
    local registry, err = self:loadRegistry()

    if not registry then
        return false, err
    end

    return Registry.isInstalled(registry, id)
end

function Manager:packageFootprint(packageItem)
    if type(packageItem) ~= "table" then
        return nil
    end

    if packageItem.installedSize ~= nil then
        return packageItem.installedSize
    end

    local total = 0

    for _, file in ipairs(packageItem.files or {}) do
        if file.size == nil then
            return nil
        end

        total = total + file.size
    end

    return total
end

function Manager:inspectPackage(packageOrId)
    local packageItem = packageOrId

    if type(packageOrId) == "string" then
        local err
        packageItem, err = self:getPackage(packageOrId)

        if not packageItem then
            return nil, err
        end
    end

    if type(packageItem) ~= "table" then
        return nil, "package_invalid"
    end

    local catalog, catalogError = self:loadCatalog()

    if not catalog then
        return nil, catalogError
    end

    local result = {
        id = packageItem.id,
        complete = true,
        missing = {},
        mismatched = {},
        bytes = 0,
        fileCount = #(packageItem.files or {})
    }

    for _, file in ipairs(packageItem.files or {}) do
        local path = absoluteTarget(file.target)

        if not fs.exists(path) or fs.isDir(path) then
            result.complete = false
            result.missing[#result.missing + 1] = file.target
        else
            local size = Storage.fileSize(path)

            if size ~= nil then
                result.bytes = result.bytes + size
            end

            local mismatch = false
            local reason = nil

            if file.size ~= nil and size ~= file.size then
                mismatch = true
                reason = "size"
            elseif file.hash ~= nil and catalog.hashAlgorithm == "djb2-32" then
                local content = readAll(path)
                local actualHash = content and hashString(content) or nil

                if actualHash ~= file.hash then
                    mismatch = true
                    reason = "hash"
                end
            end

            if mismatch then
                result.complete = false
                result.mismatched[#result.mismatched + 1] = {
                    target = file.target,
                    reason = reason
                }
            end
        end
    end

    return result
end

function Manager:storageStatus(path)
    return Storage.snapshot(path or "/")
end

function Manager:reconcileCurrentInstallation()
    local catalog, catalogError = self:loadCatalog()

    if not catalog then
        return nil, catalogError
    end

    local registry, registryError = self:loadRegistry()

    if not registry then
        return nil, registryError
    end

    local changed = {}
    local currentVersion = readAll(Manager.VERSION_PATH)

    for _, packageItem in ipairs(catalog.packages) do
        if packageItem.managedBy == "deploy" then
            local version = packageItem.version

            if packageItem.id == "base.core" and currentVersion and currentVersion ~= "" then
                version = currentVersion
            end

            local existing = Registry.get(registry, packageItem.id)

            if not existing or existing.version ~= version or existing.managedBy ~= "deploy" then
                local drive = Storage.getDrive("/") or "unknown"
                Registry.setInstalled(registry, packageItem.id, {
                    version = version,
                    source = "deploy",
                    managedBy = "deploy",
                    mount = drive
                })

                changed[#changed + 1] = packageItem.id
            end
        elseif packageItem.legacyBundled then
            local state, inspectError = self:inspectPackage(packageItem)

            if not state then
                return nil, inspectError
            end

            if state.complete then
                local existing = Registry.get(registry, packageItem.id)

                if not existing then
                    local firstFile = packageItem.files and packageItem.files[1]
                    local drive = firstFile and Storage.getDrive(absoluteTarget(firstFile.target)) or nil

                    Registry.setInstalled(registry, packageItem.id, {
                        version = packageItem.version,
                        source = "legacy-bundle",
                        managedBy = "package",
                        mount = drive or "unknown"
                    })

                    changed[#changed + 1] = packageItem.id
                end
            end
        end
    end

    local ok, saveError = self:saveRegistry()

    if not ok then
        return nil, saveError
    end

    table.sort(changed)

    return {
        changed = changed,
        installed = Registry.listInstalled(registry)
    }
end

return Manager
