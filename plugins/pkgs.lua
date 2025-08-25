local _M = {}

_M.title = "Installed Packages"

_M.cols = {
    {"name", "NAME"},
    --{"origin", "ORIGIN"},
    {"version", "VERSION"},
    {"comment", "COMMENT"},
    --{"www", "WWW"}
}

local function pkg_query(prop, pkg)
    local cmd <const> = table.concat({"pkg query", prop, pkg}, " ")
    local f <close> = assert(io.popen(cmd))
    return f:read("*a")
end

function _M.rows()
    local f <close> = assert(io.popen("pkg query -a %n"))
    local packages = {}
    for name in f:lines() do
        package = {
            name = name,
            version = pkg_query("%v", name),
            comment = pkg_query("%c", name),
        }
        table.insert(packages, package)
    end
    return packages
end

return _M

-- vim: set et sw=4:
