local Manager = require("lib.package.manager")
local Storage = require("lib.package.storage")

local manager = Manager.new()
local args = {...}
local command = args[1] or "status"

local function fail(message)
    print("PKG ERROR")
    print(tostring(message or "unknown error"))
    return false
end

local function installedSet()
    local installed, err = manager:listInstalled()

    if not installed then
        return nil, err
    end

    local result = {}

    for _, item in ipairs(installed) do
        result[item.id] = item
    end

    return result
end

local function printPending()
    local pending, err = manager:pendingTransaction()

    if err then
        print("Transaction journal: ERROR " .. tostring(err))
        return
    end

    if not pending then
        print("Transaction journal: clean")
        return
    end

    print(
        "Transaction journal: "
        .. pending.transaction.operation
        .. " "
        .. pending.transaction.packageId
        .. " "
        .. tostring(pending.done)
        .. "/"
        .. tostring(pending.total)
    )
end

local function printStatus()
    local catalog, catalogError = manager:loadCatalog()

    if not catalog then
        return fail(catalogError)
    end

    local registry, existedOrError = manager:loadRegistry()

    if not registry then
        return fail(existedOrError)
    end

    local installed, installedError = manager:listInstalled()

    if not installed then
        return fail(installedError)
    end

    local storage = manager:storageStatus("/")

    print("BASE PACKAGE MANAGER")
    print("Catalog schema: " .. tostring(catalog.schema))
    print("Catalog release: " .. tostring(catalog.generatedFor))
    print("Source commit: " .. tostring(catalog.sourceCommit):sub(1, 12))
    print("Packages: " .. tostring(#catalog.packages))
    print("Registry: " .. (manager.registryExisted and "present" or "not created"))
    print("Installed entries: " .. tostring(#installed))
    printPending()
    print("")
    print("Storage")
    print("Drive: " .. tostring(storage.drive or "unknown"))
    print("Capacity: " .. Storage.formatBytes(storage.capacity))
    print("Used: " .. Storage.formatBytes(storage.used))
    print("Free: " .. Storage.formatBytes(storage.free))

    return true
end

local function printList()
    local available, availableError = manager:listAvailable()

    if not available then
        return fail(availableError)
    end

    local installed, installedError = installedSet()

    if not installed then
        return fail(installedError)
    end

    print("AVAILABLE PACKAGES")

    for _, packageItem in ipairs(available) do
        local installedItem = installed[packageItem.id]
        local marker = installedItem and "[x]" or "[ ]"
        local size = manager:packageFootprint(packageItem)
        local sizeText = size and Storage.formatBytes(size) or "meta"
        local versionText = tostring(packageItem.version)

        if installedItem and installedItem.version ~= packageItem.version then
            versionText = tostring(installedItem.version) .. " -> " .. packageItem.version
        end

        print(
            marker
            .. " "
            .. packageItem.id
            .. "  "
            .. versionText
            .. "  "
            .. sizeText
        )
    end

    return true
end

local function printInfo(id)
    if not id or id == "" then
        return fail("Usage: pkg info <package-id>")
    end

    local packageItem, err = manager:getPackage(id)

    if not packageItem then
        return fail(err)
    end

    local installed, installedError = manager:isInstalled(id)

    if installedError then
        return fail(installedError)
    end

    print(packageItem.name)
    print("ID: " .. packageItem.id)
    print("Version: " .. packageItem.version)
    print("Type: " .. packageItem.type)
    print("Managed by: " .. packageItem.managedBy)
    print("Installed: " .. (installed and "yes" or "no"))
    print("Size: " .. Storage.formatBytes(manager:packageFootprint(packageItem)))

    if packageItem.entrypoint then
        print("Entrypoint: /" .. packageItem.entrypoint)
    end

    if #(packageItem.dependencies or {}) > 0 then
        print("Depends: " .. table.concat(packageItem.dependencies, ", "))
    end

    if #(packageItem.files or {}) > 0 then
        local state, inspectError = manager:inspectPackage(packageItem)

        if state then
            print("Files: " .. tostring(state.fileCount))
            print("Current files complete: " .. (state.complete and "yes" or "no"))
            print("Current bytes: " .. Storage.formatBytes(state.bytes))
        else
            print("File inspection: " .. tostring(inspectError))
        end
    end

    return true
end

local function reconcile()
    local result, err = manager:reconcileCurrentInstallation()

    if not result then
        return fail(err)
    end

    print("PACKAGE REGISTRY RECONCILED")

    if #result.changed == 0 then
        print("No changes.")
    else
        for _, id in ipairs(result.changed) do
            print("Registered: " .. id)
        end
    end

    print("Installed entries: " .. tostring(#result.installed))
    return true
end

local function verify()
    local installed, installedError = manager:listInstalled()

    if not installed then
        return fail(installedError)
    end

    local failed = 0

    for _, installedItem in ipairs(installed) do
        local packageItem, packageError = manager:getPackage(installedItem.id)

        if not packageItem then
            print("[ERR] " .. installedItem.id .. ": " .. tostring(packageError))
            failed = failed + 1
        elseif #(packageItem.files or {}) > 0 then
            local state, inspectError = manager:inspectPackage(packageItem)

            if not state then
                print("[ERR] " .. packageItem.id .. ": " .. tostring(inspectError))
                failed = failed + 1
            elseif state.complete then
                print("[OK]  " .. packageItem.id)
            else
                print(
                    "[BAD] "
                    .. packageItem.id
                    .. " missing="
                    .. tostring(#state.missing)
                    .. " mismatch="
                    .. tostring(#state.mismatched)
                )
                failed = failed + 1
            end
        end
    end

    if #installed == 0 then
        print("No installed packages in registry.")
    end

    return failed == 0
end

local function printPlan(result, title)
    print(title)
    print("Package: " .. result.package.id .. " " .. result.package.version)
    print("Already current: " .. (result.alreadyCurrent and "yes" or "no"))
    print("Reuse files: " .. tostring(result.reused))
    print("Transaction files: " .. tostring(#result.files))
    print("Remove obsolete: " .. tostring(#result.removeFiles))
    print("Net growth: " .. Storage.formatBytes(result.finalDelta))
    print("Reserve: " .. Storage.formatBytes(result.storage.reserve))
    print("Required free: " .. Storage.formatBytes(result.storage.required))
    print("Current free: " .. Storage.formatBytes(result.storage.free))
    print("Safe: " .. (result.storage.safe and "yes" or "no"))
end

local function plan(id, updateMode)
    if not id or id == "" then
        return fail("Usage: pkg plan <package-id> [update]")
    end

    local result, err

    if updateMode then
        result, err = manager:planUpdate(id)
    else
        result, err = manager:planInstall(id)
    end

    if not result then
        return fail(err)
    end

    printPlan(result, updateMode and "UPDATE PLAN" or "INSTALL PLAN")
    return true
end

local function showResult(result, verb)
    if result.alreadyInstalled then
        print("Already installed: " .. result.id .. " " .. result.version)
    elseif result.alreadyCurrent then
        print("Already current: " .. result.id .. " " .. result.version)
    else
        print(verb .. ": " .. result.id .. " " .. tostring(result.version or ""))
        print("Downloaded files: " .. tostring(result.downloadedFiles or 0))
        print("Reused files: " .. tostring(result.reusedFiles or 0))
        print("Written: " .. Storage.formatBytes(result.bytesWritten or 0))
    end

    if result.integrityRefreshed == false then
        print("Integrity baseline: WARNING " .. tostring(result.integrityError))
    else
        print("Integrity baseline: refreshed")
    end
end

local function install(id)
    if not id or id == "" then
        return fail("Usage: pkg install <package-id>")
    end

    print("Installing " .. id .. "...")

    local result, err = manager:install(id)

    if not result then
        return fail(err)
    end

    showResult(result, "Installed")
    return true
end

local function updateOne(id)
    if not id or id == "" then
        return fail("Usage: pkg update <package-id>")
    end

    print("Updating " .. id .. "...")

    local result, err = manager:update(id)

    if not result then
        return fail(err)
    end

    showResult(result, "Updated")
    return true
end

local function updateAll()
    local installed, installedError = manager:listInstalled()

    if not installed then
        return fail(installedError)
    end

    local attempted = 0

    for _, installedItem in ipairs(installed) do
        local packageItem = manager:getPackage(installedItem.id)

        if packageItem and packageItem.managedBy == "package" then
            attempted = attempted + 1
            print("[" .. tostring(attempted) .. "] " .. packageItem.id)

            local result, err = manager:update(packageItem.id)

            if not result then
                return fail(err)
            end

            if result.alreadyCurrent then
                print("  current")
            else
                print("  updated to " .. result.version)
            end
        end
    end

    if attempted == 0 then
        print("No package-managed installations.")
    end

    return true
end

local function repair(id)
    if not id or id == "" then
        return fail("Usage: pkg repair <package-id>")
    end

    print("Repairing " .. id .. "...")

    local result, err = manager:repair(id)

    if not result then
        return fail(err)
    end

    showResult(result, "Repaired")
    return true
end

local function remove(id)
    if not id or id == "" then
        return fail("Usage: pkg remove <package-id>")
    end

    print("Removing " .. id .. "...")

    local result, err = manager:remove(id)

    if not result then
        return fail(err)
    end

    print("Removed: " .. result.id)
    print("Removed files: " .. tostring(result.removedFiles))
    print("Freed this run: " .. Storage.formatBytes(result.freedBytes))

    if result.integrityRefreshed == false then
        print("Integrity baseline: WARNING " .. tostring(result.integrityError))
    else
        print("Integrity baseline: refreshed")
    end

    return true
end

local function recover()
    print("Checking package transaction journal...")

    local result, err = manager:recoverPending()

    if not result then
        return fail(err)
    end

    if not result.recovered then
        print("No pending transaction.")
        return true
    end

    print(
        "Recovered: "
        .. tostring(result.operation)
        .. " "
        .. tostring(result.id)
    )

    if result.integrityRefreshed == false then
        print("Integrity baseline: WARNING " .. tostring(result.integrityError))
    else
        print("Integrity baseline: refreshed")
    end

    return true
end

local function usage()
    print("Usage: pkg <command>")
    print("  status")
    print("  list")
    print("  info <package-id>")
    print("  reconcile")
    print("  verify")
    print("  plan <package-id>")
    print("  plan-update <package-id>")
    print("  install <package-id>")
    print("  update [package-id]")
    print("  repair <package-id>")
    print("  remove <package-id>")
    print("  recover")
end

local ok

if command == "status" then
    ok = printStatus()
elseif command == "list" then
    ok = printList()
elseif command == "info" then
    ok = printInfo(args[2])
elseif command == "reconcile" then
    ok = reconcile()
elseif command == "verify" then
    ok = verify()
elseif command == "plan" then
    ok = plan(args[2], false)
elseif command == "plan-update" then
    ok = plan(args[2], true)
elseif command == "install" then
    ok = install(args[2])
elseif command == "update" then
    if args[2] then
        ok = updateOne(args[2])
    else
        ok = updateAll()
    end
elseif command == "repair" then
    ok = repair(args[2])
elseif command == "remove" then
    ok = remove(args[2])
elseif command == "recover" then
    ok = recover()
elseif command == "help" or command == "--help" or command == "-h" then
    usage()
    ok = true
else
    usage()
    ok = false
end

if ok == false then
    error("pkg command failed", 0)
end
