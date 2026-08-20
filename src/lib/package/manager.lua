local Manifest = require("lib.package.manifest")
local Registry = require("lib.package.registry")
local Storage = require("lib.package.storage")
local Hash = require("lib.package.hash")

local Manager = {}
Manager.__index = Manager

Manager.DEFAULT_CATALOG_PATH = "/packages.json"
Manager.DEFAULT_REGISTRY_PATH = Registry.DEFAULT_PATH
Manager.VERSION_PATH = "/.project-version"
Manager.SPACE_RESERVE = 8192
Manager.OWNER = "Moroxso"
Manager.REPO = "cc-base"

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

local function ensureParent(path)
    local directory = fs.getDir(path)

    if directory ~= "" and not fs.exists(directory) then
        fs.makeDir(directory)
    end
end

local function writeFile(path, content)
    ensureParent(path)

    local file, openError = fs.open(path, "w")

    if not file then
        return false, "package_file_open_failed:" .. tostring(openError)
    end

    local ok, writeError = pcall(function()
        file.write(content)
    end)

    pcall(function()
        file.close()
    end)

    if not ok then
        if fs.exists(path) then
            pcall(fs.delete, path)
        end

        return false, "package_file_write_failed:" .. tostring(writeError)
    end

    return true
end

local function absoluteTarget(target)
    return "/" .. tostring(target or ""):gsub("^/+", "")
end

local function sourceUrl(catalog, source)
    return "https://raw.githubusercontent.com/"
        .. Manager.OWNER
        .. "/"
        .. Manager.REPO
        .. "/"
        .. catalog.sourceCommit
        .. "/"
        .. source
end

local function download(url)
    if type(http) ~= "table" or type(http.get) ~= "function" then
        return nil, "http_unavailable"
    end

    local response, err = http.get(url)

    if not response then
        return nil, "package_download_failed:" .. tostring(err)
    end

    local ok, content = pcall(function()
        return response.readAll()
    end)

    pcall(function()
        response.close()
    end)

    if not ok or type(content) ~= "string" then
        return nil, "package_download_read_failed:" .. tostring(content)
    end

    return content
end

local function contains(array, value)
    for _, item in ipairs(array or {}) do
        if item == value then
            return true
        end
    end

    return false
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

function Manager:verifyContent(file, content)
    local catalog, catalogError = self:loadCatalog()

    if not catalog then
        return false, catalogError
    end

    if type(content) ~= "string" then
        return false, "package_content_invalid"
    end

    if file.size ~= nil and #content ~= file.size then
        return false, "package_size_mismatch"
    end

    if file.hash ~= nil then
        if catalog.hashAlgorithm ~= "git-blob-sha1" then
            return false, "package_hash_algorithm_unsupported"
        end

        local actual, hashError = Hash.gitBlob(content)

        if not actual then
            return false, hashError
        end

        if string.lower(actual) ~= string.lower(file.hash) then
            return false, "package_hash_mismatch"
        end
    end

    return true
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
            local content = readAll(path)

            if content == nil then
                result.complete = false
                result.mismatched[#result.mismatched + 1] = {
                    target = file.target,
                    reason = "unreadable"
                }
            else
                result.bytes = result.bytes + #content
                local valid, reason = self:verifyContent(file, content)

                if not valid then
                    result.complete = false
                    result.mismatched[#result.mismatched + 1] = {
                        target = file.target,
                        reason = reason
                    }
                end
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

                if not existing
                    or existing.version ~= packageItem.version
                    or existing.managedBy ~= "package"
                then
                    local drive = Storage.getDrive("/") or "unknown"

                    Registry.setInstalled(registry, packageItem.id, {
                        version = packageItem.version,
                        source = existing and existing.source or "legacy-bundle",
                        managedBy = "package",
                        mount = drive
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

function Manager:dependencyStatus(packageItem)
    local registry, registryError = self:loadRegistry()

    if not registry then
        return nil, registryError
    end

    local missing = {}

    for _, dependency in ipairs(packageItem.dependencies or {}) do
        if not Registry.isInstalled(registry, dependency) then
            missing[#missing + 1] = dependency
        end
    end

    return {
        ok = #missing == 0,
        missing = missing
    }
end

function Manager:planInstall(id)
    local packageItem, packageError = self:getPackage(id)

    if not packageItem then
        return nil, packageError
    end

    if packageItem.managedBy ~= "package" then
        return nil, "package_managed_by_deploy:" .. packageItem.id
    end

    local reconciled, reconcileError = self:reconcileCurrentInstallation()

    if not reconciled then
        return nil, reconcileError
    end

    local dependencyStatus, dependencyError = self:dependencyStatus(packageItem)

    if not dependencyStatus then
        return nil, dependencyError
    end

    if not dependencyStatus.ok then
        return nil, "package_dependencies_missing:" .. table.concat(dependencyStatus.missing, ",")
    end

    local installed = Registry.get(self.registry, packageItem.id)
    local state, stateError = self:inspectPackage(packageItem)

    if not state then
        return nil, stateError
    end

    if installed and state.complete and installed.version == packageItem.version then
        return {
            package = packageItem,
            alreadyInstalled = true,
            reused = #packageItem.files,
            download = {},
            finalDelta = 0,
            storage = Storage.plan("/", 0, 0, Manager.SPACE_RESERVE)
        }
    end

    local downloadFiles = {}
    local reused = 0
    local finalDelta = 0

    for _, file in ipairs(packageItem.files or {}) do
        local path = absoluteTarget(file.target)

        if fs.exists(path) then
            if fs.isDir(path) then
                return nil, "package_target_conflict:" .. file.target
            end

            local content = readAll(path)
            local valid, reason = self:verifyContent(file, content)

            if not valid then
                return nil, "package_target_conflict:" .. file.target .. ":" .. tostring(reason)
            end

            reused = reused + 1
        else
            downloadFiles[#downloadFiles + 1] = file
            finalDelta = finalDelta + (file.size or 0)
        end
    end

    local storage = Storage.plan("/", finalDelta, 0, Manager.SPACE_RESERVE)

    return {
        package = packageItem,
        alreadyInstalled = false,
        reused = reused,
        download = downloadFiles,
        finalDelta = finalDelta,
        storage = storage
    }
end

function Manager:refreshIntegrity()
    local loaded, Integrity = pcall(require, "lib.security.integrity")

    if not loaded or type(Integrity) ~= "table" or type(Integrity.createBaseline) ~= "function" then
        return false, "package_integrity_service_unavailable"
    end

    local baseline, err = Integrity.createBaseline()

    if not baseline then
        return false, err or "package_integrity_refresh_failed"
    end

    return true
end

function Manager:install(id)
    local plan, planError = self:planInstall(id)

    if not plan then
        return nil, planError
    end

    if plan.alreadyInstalled then
        return {
            id = plan.package.id,
            version = plan.package.version,
            alreadyInstalled = true,
            downloadedFiles = 0,
            reusedFiles = plan.reused,
            bytesWritten = 0,
            integrityRefreshed = true
        }
    end

    if plan.storage.free == nil then
        return nil, "package_space_unknown"
    end

    if not plan.storage.safe then
        return nil,
            "package_insufficient_space:required="
            .. tostring(plan.storage.required)
            .. ":free="
            .. tostring(plan.storage.free)
    end

    local catalog = self.catalog
    local created = {}
    local bytesWritten = 0

    local function rollback()
        for index = #created, 1, -1 do
            local path = created[index]

            if fs.exists(path) and not fs.isDir(path) then
                pcall(fs.delete, path)
            end
        end
    end

    for _, file in ipairs(plan.download) do
        local content, downloadError = download(sourceUrl(catalog, file.source))

        if not content then
            rollback()
            return nil, downloadError .. ":" .. file.source
        end

        local valid, verifyError = self:verifyContent(file, content)

        if not valid then
            rollback()
            return nil, verifyError .. ":" .. file.source
        end

        local free = Storage.getFreeSpace("/")

        if free ~= nil and free ~= math.huge and free < #content + Manager.SPACE_RESERVE then
            rollback()
            return nil, "package_space_exhausted_during_install:" .. file.target
        end

        local target = absoluteTarget(file.target)
        local writeOk, writeError = writeFile(target, content)

        if not writeOk then
            rollback()
            return nil, writeError .. ":" .. file.target
        end

        created[#created + 1] = target
        bytesWritten = bytesWritten + #content

        local written = readAll(target)
        local writtenValid, writtenError = self:verifyContent(file, written)

        if not writtenValid then
            rollback()
            return nil, "package_written_verification_failed:" .. file.target .. ":" .. tostring(writtenError)
        end
    end

    local finalState, stateError = self:inspectPackage(plan.package)

    if not finalState or not finalState.complete then
        rollback()
        return nil, stateError or "package_install_incomplete"
    end

    local drive = Storage.getDrive("/") or "unknown"
    Registry.setInstalled(self.registry, plan.package.id, {
        version = plan.package.version,
        source = "github:" .. catalog.sourceCommit,
        managedBy = "package",
        mount = drive
    })

    local saved, saveError = self:saveRegistry()

    if not saved then
        return nil, saveError
    end

    local integrityOk, integrityError = self:refreshIntegrity()

    return {
        id = plan.package.id,
        version = plan.package.version,
        alreadyInstalled = false,
        downloadedFiles = #plan.download,
        reusedFiles = plan.reused,
        bytesWritten = bytesWritten,
        integrityRefreshed = integrityOk,
        integrityError = integrityError
    }
end

function Manager:installedDependents(id)
    local catalog, catalogError = self:loadCatalog()

    if not catalog then
        return nil, catalogError
    end

    local registry, registryError = self:loadRegistry()

    if not registry then
        return nil, registryError
    end

    local result = {}

    for installedId in pairs(registry.installed or {}) do
        if installedId ~= id then
            local packageItem = catalog.byId[installedId]

            if packageItem and contains(packageItem.dependencies, id) then
                result[#result + 1] = installedId
            end
        end
    end

    table.sort(result)
    return result
end

function Manager:remove(id)
    local packageItem, packageError = self:getPackage(id)

    if not packageItem then
        return nil, packageError
    end

    if packageItem.managedBy ~= "package" or packageItem.required then
        return nil, "package_remove_forbidden:" .. packageItem.id
    end

    local registry, registryError = self:loadRegistry()

    if not registry then
        return nil, registryError
    end

    if not Registry.isInstalled(registry, id) then
        return nil, "package_not_installed:" .. id
    end

    local dependents, dependentError = self:installedDependents(id)

    if not dependents then
        return nil, dependentError
    end

    if #dependents > 0 then
        return nil, "package_has_dependents:" .. table.concat(dependents, ",")
    end

    local state, stateError = self:inspectPackage(packageItem)

    if not state then
        return nil, stateError
    end

    if not state.complete then
        return nil, "package_modified_or_incomplete:" .. id
    end

    for _, file in ipairs(packageItem.files or {}) do
        local path = absoluteTarget(file.target)

        if fs.exists(path) then
            local ok, deleteError = pcall(fs.delete, path)

            if not ok then
                return nil, "package_delete_failed:" .. file.target .. ":" .. tostring(deleteError)
            end
        end
    end

    Registry.removeInstalled(registry, id)

    local saved, saveError = self:saveRegistry()

    if not saved then
        return nil, saveError
    end

    local integrityOk, integrityError = self:refreshIntegrity()

    return {
        id = id,
        freedBytes = state.bytes,
        removedFiles = #packageItem.files,
        integrityRefreshed = integrityOk,
        integrityError = integrityError
    }
end

return Manager
