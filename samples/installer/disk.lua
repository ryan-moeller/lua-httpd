--
-- Copyright (c) 2020 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local disk = disk or {}

local function kern_disks()
    local f = io.popen("sysctl -n kern.disks | xargs -n1;" ..
                       "ggatel list;" ..
                       "mdconfig -l | xargs -n1;",
                       "r")
    local text = f:read("*a")
    f:close()
    return text
end

local function diskinfo(dev)
    local f = io.popen("diskinfo -v "..dev, "r")
    local text = f:read("*a")
    f:close()
    return text
end

function disk.info()
    local disks = {}
    local text = kern_disks()
    for dev in text:gmatch("([^ \n]+)") do
        local disk = {}
        local text = diskinfo(dev)
        for line in text:gmatch("([^\n]+)") do
            if line:find("#") ~= nil then
                local value, field = line:match("^\t([^\t]+)\t+# (.*)$")
                local f, v = field:match("(.*) %((.*)%)")
                if f ~= nil then
                        disk[f] = value
                        disk[f .. " human"] = v
                else
                        disk[field] = value
                end
            end
        end
        disks[dev] = disk
    end
    return disks
end

return disk

-- vim: set et sw=4:
