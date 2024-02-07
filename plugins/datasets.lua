local _M = {}

_M.cols = {
    {"name", "NAME"},
    {"used", "USED"},
    {"available", "AVAIL"},
    {"referenced", "REFER"},
    {"mountpoint", "MOUNTPOINT"}
}

function _M.rows()
    local f = assert(io.popen("zfs list -H"))
    local t = f:read("*a")
    f:close()
    local pat = "([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\n"
    local datasets = {}
    for name, used, avail, refer, mountpoint in t:gmatch(pat) do
        table.insert(datasets, {
            ["name"] = name,
            ["used"] = used,
            ["available"] = avail,
            ["referenced"] = refer,
            ["mountpoint"] = mountpoint
        })
    end
    return datasets
end

return _M
