local _M = {}

_M.title = "NFS Exports"

_M.cols = {
    {"directory", "DIRECTORY"}
}

function _M.rows()
    local f = assert(io.popen("showmount -E"))
    local t = f:read("*a")
    f:close()
    local exports = {}
    for line in t:gmatch("([^\n]+)") do
        table.insert(exports, {
            ["directory"] = line
        })
    end
    return exports
end

return _M
