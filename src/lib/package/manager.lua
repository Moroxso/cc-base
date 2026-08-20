local Manifest = require("lib.package.manifest")
local Registry = require("lib.package.registry")
local Storage = require("lib.package.storage")
local Hash = require("lib.package.hash")
local Journal = require("lib.package.journal")

local Manager = {}
Manager.__index = Manager

Manager.DEFAULT_CATALOG_PATH = "/packages.json"
Manager.DEFAULT_REGISTRY_PATH = Registry.DEFAULT_PATH
Manager.DEFAULT_JOURNAL_PATH = Journal.DEFAULT_PATH
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

local function sourceUrl(sourceCommit, source)
    return "https://raw.githubusercontent.com/"
        .. Manager.OWNER
        .. "/"
        .. Manager.REPO
        .. "/"
        .. sourceCommit
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

local function copySpec(file)
    return {
        source = file.source,
        target = file.target,
        size = file.size,
        hash = file.hash
    }
end

local function packageSnapshot(packageItem)
    local files = {}

    for _, file in ipairs(packageItem.files or {}) do
        files[#files + 1] = {
            target = file.target,
            size = file.size,
            hash = file.hash
        }
    end

    return files
end

local function specMap(files)
    local result = {}

    for _, file in ipairs(files or {}) do
        result[file.target] = file
    end

    return result
end

function Manager.new(options)
    options = type(options) == "table" and options or {}

    return setmetatable({
        catalogPath = options.catalogPath or Manager.DEFAULT_CATALOG_PATH,
        registryPath = options.registryPath or Manager.DEFAULT_REGISTRY_PATH,
        journalPath = options.journalPath or Manager.DEFAULT_JOURNAL_PATH,
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

function Manager:verifySpec(file, content)
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
                local valid, reason = self:verifySpec(file, content)

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

            if not existing
                or existing.version ~= version
                or existing.managedBy ~= "deploy"
            then
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
                local needsSnapshot = not existing
                    or existing.version ~= packageItem.version
                    or existing.managedBy ~= "package"
                    or existing.sourceCommit ~= catalog.sourceCommit
                    or #(existing.files or {}) ~= #(packageItem.files or {})

                if needsSnapshot then
                    local drive = Storage.getDrive("/") or "unknown"

                    Registry.setInstalled(registry, packageItem.id, {
                        version = packageItem.version,
                        source = existing and existing.source or "legacy-bundle",
                        managedBy = "package",
                        mount = drive,
                        sourceCommit = catalog.sourceCommit,
                        files = packageSnapshot(packageItem)
                    })

                    changed[#changed + 1] = packageItem.id
                end
            end
        end
    end

    if #changed > 0 or not self.registryExisted then
        local ok, saveError = self:saveRegistry()

        if not ok then
            return nil, saveError
        end
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

function Manager:pendingTransaction()
    local journal, existsOrError = Journal.load(self.journalPath)

    if journal then
        local done, total = Journal.progress(journal)

        return {
            transaction = journal,
            done = done,
            total = total
        }
    end

    if existsOrError == false then
        return nil
    end

    return nil, existsOrError
end

function Manager:ensureNoPending()
    local pending, err = self:pendingTransaction()

    if err then
        return false, err
    end

    if pending then
        return false,
            "package_pending_transaction:"
            .. pending.transaction.operation
            .. ":"
            .. pending.transaction.packageId
    end

    return true
end

function Manager:refreshIntegrity()
    local loaded, Integrity = pcall(require, "lib.security.integrity")

    if not loaded
        or type(Integrity) ~= "table"
        or type(Integrity.createBaseline) ~= "function"
    then
        return false, "package_integrity_service_unavailable"
    end

    local baseline, err = Integrity.createBaseline()

    if not baseline then
        return false, err or "package_integrity_refresh_failed"
    end

    return true
end

function Manager:planSync(id, operation)
    local packageItem, packageError = self:getPackage(id)

    if not packageItem then
        return nil, packageError
    end

    if packageItem.managedBy ~= "package" then
        return nil, "package_managed_by_deploy:" .. packageItem.id
    end

    local noPending, pendingError = self:ensureNoPending()

    if not noPending then
        return nil, pendingError
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

    if operation ~= "install" and not installed then
        return nil, "package_not_installed:" .. packageItem.id
    end

    local state, stateError = self:inspectPackage(packageItem)

    if not state then
        return nil, stateError
    end

    if installed and state.complete and installed.version == packageItem.version then
        return {
            package = packageItem,
            operation = operation,
            alreadyCurrent = true,
            reused = #packageItem.files,
            files = {},
            removeFiles = {},
            finalDelta = 0,
            storage = Storage.plan("/", 0, 0, Manager.SPACE_RESERVE)
        }
    end

    local oldByTarget = installed and specMap(installed.files) or {}
    local newByTarget = specMap(packageItem.files)
    local files = {}
    local removeFiles = {}
    local reused = 0
    local finalDelta = 0

    for _, file in ipairs(packageItem.files or {}) do
        local path = absoluteTarget(file.target)
        local step = copySpec(file)
        step.state = "pending"

        if fs.exists(path) then
            if fs.isDir(path) then
                return nil, "package_target_conflict:" .. file.target
            end

            local content = readAll(path)

            if content == nil then
                return nil, "package_target_unreadable:" .. file.target
            end

            local currentValid = self:verifySpec(file, content)

            if currentValid then
                step.state = "done"
                reused = reused + 1
            else
                if not installed then
                    return nil, "package_target_conflict:" .. file.target
                end

                local oldSpec = oldByTarget[file.target]

                if not oldSpec then
                    return nil, "package_target_untracked:" .. file.target
                end

                local oldValid, oldReason = self:verifySpec(oldSpec, content)

                if not oldValid then
                    return nil,
                        "package_modified_file:"
                        .. file.target
                        .. ":"
                        .. tostring(oldReason)
                end

                step.oldHash = oldSpec.hash
                step.oldSize = oldSpec.size
                finalDelta = finalDelta
                    + math.max(0, (file.size or #content) - #content)
            end
        else
            finalDelta = finalDelta + (file.size or 0)
        end

        files[#files + 1] = step
    end

    if installed then
        for _, oldFile in ipairs(installed.files or {}) do
            if not newByTarget[oldFile.target] then
                local path = absoluteTarget(oldFile.target)

                if fs.exists(path) and not fs.isDir(path) then
                    local content = readAll(path)
                    local valid, reason = self:verifySpec(oldFile, content)

                    if not valid then
                        return nil,
                            "package_modified_obsolete_file:"
                            .. oldFile.target
                            .. ":"
                            .. tostring(reason)
                    end
                end

                removeFiles[#removeFiles + 1] = {
                    target = oldFile.target,
                    oldHash = oldFile.hash,
                    oldSize = oldFile.size,
                    state = "pending"
                }
            end
        end
    end

    local storage = Storage.plan("/", finalDelta, 0, Manager.SPACE_RESERVE)

    return {
        package = packageItem,
        operation = operation,
        alreadyCurrent = false,
        reused = reused,
        files = files,
        removeFiles = removeFiles,
        finalDelta = finalDelta,
        storage = storage
    }
end

function Manager:planInstall(id)
    return self:planSync(id, "install")
end

function Manager:planUpdate(id)
    return self:planSync(id, "update")
end

function Manager:createSyncJournal(plan)
    local catalog, catalogError = self:loadCatalog()

    if not catalog then
        return nil, catalogError
    end

    local journal = Journal.create(
        plan.operation,
        plan.package,
        catalog.sourceCommit,
        plan.files,
        plan.removeFiles
    )

    local ok, err = Journal.save(journal, self.journalPath)

    if not ok then
        return nil, err
    end

    return journal
end

function Manager:verifyJournalFile(step, content)
    return self:verifySpec({
        target = step.target,
        size = step.size,
        hash = step.hash
    }, content)
end

function Manager:executeSyncJournal(journal)
    local registry, registryError = self:loadRegistry(true)

    if not registry then
        return nil, registryError
    end

    local bytesWritten = 0
    local downloadedFiles = 0

    for _, step in ipairs(journal.files or {}) do
        local target = absoluteTarget(step.target)

        if step.state == "done" then
            local completedContent = readAll(target)
            local completedValid = self:verifyJournalFile(step, completedContent)

            if not completedValid then
                step.state = "pending"

                local saved, saveError = Journal.save(journal, self.journalPath)

                if not saved then
                    return nil, saveError
                end
            end
        end

        if step.state ~= "done" then
            local existing = readAll(target)

            if existing ~= nil then
                local alreadyNew = self:verifyJournalFile(step, existing)

                if alreadyNew then
                    step.state = "done"

                    local saved, saveError = Journal.save(journal, self.journalPath)

                    if not saved then
                        return nil, saveError
                    end
                else
                    if not step.oldHash then
                        return nil, "package_recovery_target_conflict:" .. step.target
                    end

                    local oldValid, oldReason = self:verifySpec({
                        target = step.target,
                        size = step.oldSize,
                        hash = step.oldHash
                    }, existing)

                    if not oldValid then
                        return nil,
                            "package_recovery_modified_file:"
                            .. step.target
                            .. ":"
                            .. tostring(oldReason)
                    end
                end
            end

            if step.state ~= "done" then
                local content, downloadError = download(
                    sourceUrl(journal.sourceCommit, step.source)
                )

                if not content then
                    return nil, downloadError .. ":" .. step.source
                end

                local valid, verifyError = self:verifyJournalFile(step, content)

                if not valid then
                    return nil, verifyError .. ":" .. step.source
                end

                local currentContent = readAll(target)
                local currentSize = currentContent and #currentContent or 0
                local free, freeError = Storage.getFreeSpace("/")

                if free == nil then
                    return nil, "package_space_unknown:" .. tostring(freeError)
                end

                if free ~= math.huge
                    and free + currentSize < #content + Manager.SPACE_RESERVE
                then
                    return nil, "package_space_exhausted_during_transaction:" .. step.target
                end

                if fs.exists(target) then
                    local deleted, deleteError = pcall(fs.delete, target)

                    if not deleted then
                        return nil,
                            "package_replace_delete_failed:"
                            .. step.target
                            .. ":"
                            .. tostring(deleteError)
                    end
                end

                local writeOk, writeError = writeFile(target, content)

                if not writeOk then
                    if currentContent ~= nil then
                        pcall(writeFile, target, currentContent)
                    end

                    return nil, writeError .. ":" .. step.target
                end

                local written = readAll(target)
                local writtenValid, writtenError = self:verifyJournalFile(step, written)

                if not writtenValid then
                    if fs.exists(target) then
                        pcall(fs.delete, target)
                    end

                    if currentContent ~= nil then
                        pcall(writeFile, target, currentContent)
                    end

                    return nil,
                        "package_written_verification_failed:"
                        .. step.target
                        .. ":"
                        .. tostring(writtenError)
                end

                bytesWritten = bytesWritten + #content
                downloadedFiles = downloadedFiles + 1
                step.state = "done"

                local saved, saveError = Journal.save(journal, self.journalPath)

                if not saved then
                    return nil, saveError
                end
            end
        end
    end

    for _, step in ipairs(journal.removeFiles or {}) do
        if step.state ~= "done" then
            local path = absoluteTarget(step.target)

            if fs.exists(path) then
                if fs.isDir(path) then
                    return nil, "package_remove_target_is_directory:" .. step.target
                end

                local content = readAll(path)

                if content == nil then
                    return nil, "package_remove_target_unreadable:" .. step.target
                end

                if step.oldHash then
                    local valid, reason = self:verifySpec({
                        target = step.target,
                        size = step.oldSize,
                        hash = step.oldHash
                    }, content)

                    if not valid then
                        return nil,
                            "package_remove_modified_file:"
                            .. step.target
                            .. ":"
                            .. tostring(reason)
                    end
                end

                local ok, deleteError = pcall(fs.delete, path)

                if not ok then
                    return nil,
                        "package_delete_failed:"
                        .. step.target
                        .. ":"
                        .. tostring(deleteError)
                end
            end

            step.state = "done"

            local saved, saveError = Journal.save(journal, self.journalPath)

            if not saved then
                return nil, saveError
            end
        end
    end

    for _, step in ipairs(journal.files or {}) do
        local content = readAll(absoluteTarget(step.target))
        local valid, reason = self:verifyJournalFile(step, content)

        if not valid then
            return nil,
                "package_transaction_incomplete:"
                .. step.target
                .. ":"
                .. tostring(reason)
        end
    end

    local drive = Storage.getDrive("/") or "unknown"
    local snapshot = {}

    for _, step in ipairs(journal.files or {}) do
        snapshot[#snapshot + 1] = {
            target = step.target,
            size = step.size,
            hash = step.hash
        }
    end

    Registry.setInstalled(registry, journal.packageId, {
        version = journal.version,
        source = "github:" .. journal.sourceCommit,
        managedBy = "package",
        mount = drive,
        sourceCommit = journal.sourceCommit,
        files = snapshot
    })

    local saved, saveError = self:saveRegistry()

    if not saved then
        return nil, saveError
    end

    local integrityOk, integrityError = self:refreshIntegrity()
    local cleared, clearError = Journal.clear(self.journalPath)

    if not cleared then
        return nil, clearError
    end

    return {
        id = journal.packageId,
        version = journal.version,
        operation = journal.operation,
        downloadedFiles = downloadedFiles,
        bytesWritten = bytesWritten,
        integrityRefreshed = integrityOk,
        integrityError = integrityError,
        recovered = false
    }
end

function Manager:executeRemoveJournal(journal)
    local registry, registryError = self:loadRegistry(true)

    if not registry then
        return nil, registryError
    end

    local freedBytes = 0
    local removedFiles = 0

    for _, step in ipairs(journal.removeFiles or {}) do
        if step.state ~= "done" then
            local path = absoluteTarget(step.target)

            if fs.exists(path) then
                if fs.isDir(path) then
                    return nil, "package_remove_target_is_directory:" .. step.target
                end

                local content = readAll(path)

                if content == nil then
                    return nil, "package_remove_target_unreadable:" .. step.target
                end

                if step.oldHash then
                    local valid, reason = self:verifySpec({
                        target = step.target,
                        size = step.oldSize,
                        hash = step.oldHash
                    }, content)

                    if not valid then
                        return nil,
                            "package_remove_modified_file:"
                            .. step.target
                            .. ":"
                            .. tostring(reason)
                    end
                end

                freedBytes = freedBytes + #content
                local ok, deleteError = pcall(fs.delete, path)

                if not ok then
                    return nil,
                        "package_delete_failed:"
                        .. step.target
                        .. ":"
                        .. tostring(deleteError)
                end

                removedFiles = removedFiles + 1
            end

            step.state = "done"

            local saved, saveError = Journal.save(journal, self.journalPath)

            if not saved then
                return nil, saveError
            end
        end
    end

    Registry.removeInstalled(registry, journal.packageId)

    local saved, saveError = self:saveRegistry()

    if not saved then
        return nil, saveError
    end

    local integrityOk, integrityError = self:refreshIntegrity()
    local cleared, clearError = Journal.clear(self.journalPath)

    if not cleared then
        return nil, clearError
    end

    return {
        id = journal.packageId,
        operation = "remove",
        freedBytes = freedBytes,
        removedFiles = removedFiles,
        integrityRefreshed = integrityOk,
        integrityError = integrityError,
        recovered = false
    }
end

function Manager:executeJournal(journal)
    if journal.operation == "remove" then
        return self:executeRemoveJournal(journal)
    end

    return self:executeSyncJournal(journal)
end

function Manager:recoverPending()
    local journal, existsOrError = Journal.load(self.journalPath)

    if not journal then
        if existsOrError == false then
            return {
                recovered = false,
                pending = false
            }
        end

        return nil, existsOrError
    end

    local result, err = self:executeJournal(journal)

    if not result then
        return nil, err
    end

    result.recovered = true
    result.pending = false
    return result
end

function Manager:install(id)
    local plan, planError = self:planInstall(id)

    if not plan then
        return nil, planError
    end

    if plan.alreadyCurrent then
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

    local journal, journalError = self:createSyncJournal(plan)

    if not journal then
        return nil, journalError
    end

    local result, executeError = self:executeSyncJournal(journal)

    if not result then
        return nil, executeError
    end

    result.reusedFiles = plan.reused
    result.alreadyInstalled = false
    return result
end

function Manager:update(id)
    local plan, planError = self:planUpdate(id)

    if not plan then
        return nil, planError
    end

    if plan.alreadyCurrent then
        return {
            id = plan.package.id,
            version = plan.package.version,
            alreadyCurrent = true,
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

    local journal, journalError = self:createSyncJournal(plan)

    if not journal then
        return nil, journalError
    end

    local result, executeError = self:executeSyncJournal(journal)

    if not result then
        return nil, executeError
    end

    result.reusedFiles = plan.reused
    result.alreadyCurrent = false
    return result
end

function Manager:repair(id)
    local plan, planError = self:planSync(id, "repair")

    if not plan then
        return nil, planError
    end

    if plan.alreadyCurrent then
        return {
            id = plan.package.id,
            version = plan.package.version,
            alreadyCurrent = true,
            downloadedFiles = 0,
            reusedFiles = plan.reused,
            bytesWritten = 0,
            integrityRefreshed = true
        }
    end

    if plan.storage.free == nil or not plan.storage.safe then
        return nil, "package_repair_insufficient_space"
    end

    local journal, journalError = self:createSyncJournal(plan)

    if not journal then
        return nil, journalError
    end

    local result, executeError = self:executeSyncJournal(journal)

    if not result then
        return nil, executeError
    end

    result.reusedFiles = plan.reused
    return result
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
    local noPending, pendingError = self:ensureNoPending()

    if not noPending then
        return nil, pendingError
    end

    local reconciled, reconcileError = self:reconcileCurrentInstallation()

    if not reconciled then
        return nil, reconcileError
    end

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

    local installed = Registry.get(registry, id)

    if not installed then
        return nil, "package_not_installed:" .. id
    end

    local dependents, dependentError = self:installedDependents(id)

    if not dependents then
        return nil, dependentError
    end

    if #dependents > 0 then
        return nil, "package_has_dependents:" .. table.concat(dependents, ",")
    end

    if #(installed.files or {}) == 0 then
        return nil, "package_registry_snapshot_missing:" .. id
    end

    local removeFiles = {}

    for _, oldFile in ipairs(installed.files or {}) do
        local path = absoluteTarget(oldFile.target)

        if fs.exists(path) then
            if fs.isDir(path) then
                return nil, "package_remove_target_is_directory:" .. oldFile.target
            end

            local content = readAll(path)
            local valid, reason = self:verifySpec(oldFile, content)

            if not valid then
                return nil,
                    "package_modified_or_incomplete:"
                    .. id
                    .. ":"
                    .. oldFile.target
                    .. ":"
                    .. tostring(reason)
            end
        end

        removeFiles[#removeFiles + 1] = {
            target = oldFile.target,
            oldHash = oldFile.hash,
            oldSize = oldFile.size,
            state = "pending"
        }
    end

    local journal = Journal.create(
        "remove",
        {
            id = id,
            version = installed.version
        },
        installed.sourceCommit,
        {},
        removeFiles
    )

    local saved, saveError = Journal.save(journal, self.journalPath)

    if not saved then
        return nil, saveError
    end

    return self:executeRemoveJournal(journal)
end

return Manager
