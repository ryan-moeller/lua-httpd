local kldstat <const> = require("kldstat") -- from ryan-moeller/flualibs

local _M = {}

_M.title = "Kernel Modules"

_M.cols = {
    {"name", "NAME"}, 
    {"refs", "REFS"}, 
    {"id", "ID"}, 
    {"address", "ADDRESS"}, 
    {"size", "SIZE"}, 
    {"pathname", "PATH"}, 
}

function _M.rows()
    local klds = {}
    for kld in kldstat.kldstat() do
	table.insert(klds, kld)
    end
    return klds
end

return _M
