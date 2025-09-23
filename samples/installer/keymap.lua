--
-- Copyright (c) 2020 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local keymap = keymap or {}

keymap.VT = "/usr/share/vt/keymaps"
keymap.SYSCONS = "/usr/share/syscons/keymaps"

function keymap.index(path)
    local index = {}
    local menu = {}
    local font = {}
    local f = assert(io.open(path .. "/INDEX.keymaps", "r"))
    local text = f:read("*a")
    f:close()
    for line in text:gmatch("([^\n]+)") do
	if line:find("^%s*#") == nil and line:find("^%s*$") == nil then
	    local layout, lang, desc = line:match("(.*):(.*):(.*)")
	    if lang == "" then
		lang = "en"
	    end
	    if layout == "MENU" then
		menu[lang] = desc
	    elseif layout == "FONT" then
		font[lang] = desc
	    else
		local list = index[lang] or {}
		local file = path .. "/" .. layout
		table.insert(list, { file=file, desc=desc })
		index[lang] = list
	    end
	end
    end
    return index, menu, font
end

return keymap

-- vim: set et sw=4:
