local OWNER = "Moroxso"
local REPO = "cc-base"
local BRANCH = "main"

local BASE_URL =
    "https://raw.githubusercontent.com/"
    .. OWNER
    .. "/"
    .. REPO
    .. "/refs/heads/"
    .. BRANCH
    .. "/"

local MANIFEST_URL =
    BASE_URL .. "deploy.json"

local STAGE_DIR =
    "/.cc_update_stage"

local VERSION_FILE =
    "/.project-version"


local function download(url)
    local response, err = http.get(url)

    if not response then
        return nil, err
    end

    local content =
        response.readAll()

    response.close()

    return content
end


local function ensureParent(path)
    local directory =
        fs.getDir(path)

    if
        directory ~= ""
        and not fs.exists(directory)
    then
        fs.makeDir(directory)
    end
end


local function writeFile(path, content)
    ensureParent(path)

    local file =
        fs.open(path, "w")

    if not file then
        error(
            "Cannot write file: "
            .. path
        )
    end

    file.write(content)
    file.close()
end


local function clearStage()
    if fs.exists(STAGE_DIR) then
        fs.delete(STAGE_DIR)
    end

    fs.makeDir(STAGE_DIR)
end


local function validateTarget(path)
    if type(path) ~= "string" then
        return false
    end

    if path == "" then
        return false
    end

    if path:sub(1, 1) == "/" then
        return false
    end

    if path:find("..", 1, true) then
        return false
    end

    return true
end


print("CC UPDATE")
print("")

print("Downloading manifest...")

local manifestData, manifestError =
    download(MANIFEST_URL)

if not manifestData then
    error(
        "Manifest download failed: "
        .. tostring(manifestError)
    )
end


local manifest =
    textutils.unserializeJSON(
        manifestData
    )

if type(manifest) ~= "table" then
    error("Invalid manifest")
end

if type(manifest.files) ~= "table" then
    error("Manifest has no files")
end


print(
    "Version: "
    .. tostring(
        manifest.version
        or "unknown"
    )
)

print("")

clearStage()


for index, item in ipairs(manifest.files) do

    if
        type(item.source) ~= "string"
        or not validateTarget(item.target)
    then
        error(
            "Invalid manifest entry #"
            .. index
        )
    end

    print(
        "[" ..
        index ..
        "/" ..
        #manifest.files ..
        "] " ..
        item.target
    )

    local content, err =
        download(
            BASE_URL
            .. item.source
        )

    if not content then
        fs.delete(STAGE_DIR)

        error(
            "Download failed: "
            .. item.source
            .. "\n"
            .. tostring(err)
        )
    end

    local stagePath =
        fs.combine(
            STAGE_DIR,
            item.target
        )

    writeFile(
        stagePath,
        content
    )
end


print("")
print("Installing...")


for _, item in ipairs(manifest.files) do

    local source =
        fs.combine(
            STAGE_DIR,
            item.target
        )

    local target =
        "/" .. item.target

    ensureParent(target)

    if fs.exists(target) then
        fs.delete(target)
    end

    fs.move(
        source,
        target
    )
end


if fs.exists(STAGE_DIR) then
    fs.delete(STAGE_DIR)
end


writeFile(
    VERSION_FILE,
    tostring(
        manifest.version
        or "unknown"
    )
)


print("")
print("Update complete.")

print(
    "Installed version: "
    .. tostring(
        manifest.version
        or "unknown"
    )
)