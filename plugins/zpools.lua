local _M = {}

_M.cols = {
    {"name", "NAME"},
    {"size", "SIZE"},
    {"allocated", "ALLOC"},
    {"free", "FREE"},
    {"checkpoint", "CKPOINT"},
    {"expanded-size", "EXPANDSZ"},
    {"fragmentation", "FRAG"},
    {"capacity", "CAP"},
    {"dedup", "DEDUP"},
    {"health", "HEALTH"},
    {"altroot", "ALTROOT"}
}

function _M.rows()
    local f = assert(io.popen("zpool list -H"))
    local t = f:read("*a")
    f:close()
    local pat = "([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t"..
                "([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\n"
    local pools = {}
    for name, size, alloc, free, ckpoint, expandsz, frag, cap, dedup, health, altroot in t:gmatch(pat) do
        table.insert(pools, {
            ["name"] = name,
            ["size"] = size,
            ["allocated"] = alloc,
            ["free"] = free,
            ["checkpoint"] = ckpoint,
            ["expanded-size"] = expandsz,
            ["fragmentation"] = frag,
            ["capacity"] = cap,
            ["dedup"] = dedup,
            ["health"] = health,
            ["altroot"] = altroot
        })
     end
     return pools
end

return _M
