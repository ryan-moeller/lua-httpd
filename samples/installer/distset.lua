--
-- Copyright (c) 2020 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local distset = distset or {}

local DISTDIR = "/usr/freebsd-dist/MANIFEST"

function distset.list(distfile)
    local list = {}
    local f = assert(io.open(distfile, "r"))
    local text = f:read("*a")
    f:close()
    for line in text:gmatch("([^\n]+)") do
	if line:find("^%s*#") == nil and line:find("^%s*$") == nil then
	    local file, cksm, size, name, desc, sele = 
		line:match('^(.+)\t(%x+)\t(%d+)\t(.*)\t"?([^"]+)"?\t(.*)$')
	    size = tonumber(size)
	    sele = sele == "on"
	    table.insert(list,
			 { file=file,
			   cksm=cksm,
			   size=size,
			   name=name,
			   desc=desc,
			   sele=sele })
	end
    end
    return list
end

return distset

-- vim: set et sw=4:
