local linker <const> = require("sys.linker") -- from ryan-moeller/flualibs

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

local function iter_klds()
	return function (_, fileid)
		return linker.kldnext(fileid)
	end, nil, 0
end

function _M.rows()
    local klds = {}
    for fileid in iter_klds() do
	local kld = assert(linker.kldstat(fileid))
	kld.address = tostring(kld.address):match(' (.*)')
	table.insert(klds, kld)
    end
    return klds
end

return _M
