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

local function printStatus()
    local catalog, catalogError = manager:loadCatalog()

    if not catalog then
        return fail(catalogError)
    end

    local registry, existedOrError = manager:loadRegistry()

    if not registry then
        return fail(existedOrError)
    end

    local storage = manager:storageStatus("/")

    print("BASE PACKAGE MANAGER")
    print("Catalog schema: " .. tostring(catalog.schema))
    print("Catalog release: " .. tostring(catalog.generatedFor))
    print("Packages: " .. tostring(#catalog.packages))
    print("Registry: " .. (manager.registryExisted and "present" or "not created"))
    print("Installed entries: " .. tostring(#manager:listInstalled()))
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
        local marker = installed[packageItem.id] and "[x]" or "[ ]"
        local size = manager:packageFootprint(packageItem)
        local sizeText = size and Storage.formatBytes(size) or "meta"

        print(
            marker
            .. " "
            .. packageItem.id
            .. "  "
            .. tostring(packageItem.version)
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
    local available, err = manager:listAvailable()

    if not available then
        return fail(err)
    end

    local failed = 0

    for _, packageItem in ipairs(available) do
        if #(packageItem.files or {}) > 0 then
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

    return failed == 0
end

local function usage()
    print("Usage: pkg <command>")
    print("  status")
    print("  list")
    print("  info <package-id>")
    print("  reconcile")
    print("  verify")
    print("")
    print("Install/remove arrive in the next 0.21 alpha.")
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
