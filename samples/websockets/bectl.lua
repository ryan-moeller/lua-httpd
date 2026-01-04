--
-- Copyright (c) 2024-2025 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local _M <const> = {}

local be <const> = require("be")

local function init_quiet()
    local handle <const> = be.init()
    handle:print_on_error(false)
    return handle
end

function _M.list()
    local handle <close> = init_quiet()
    local props <const>, err <const>, rc <const> = handle:get_bootenv_props()
    if not props then
        return nil, err, rc
    end
    local bes <const> = {}
    for name in pairs(props) do
        table.insert(bes, name)
    end
    local function creation_descending(a, b)
        return props[a].creation > props[b].creation
    end
    table.sort(bes, creation_descending)
    local result <const> = {}
    for _, name in ipairs(bes) do
        table.insert(result, {
            name = name,
            active = props[name].active,
            used = be.nicenum(props[name].used) .. "B",
            creation = props[name].creation,
        })
    end
    return result
end

function _M.create(name)
    local handle <close> = init_quiet()
    return handle:create(name)
end

function _M.mount(name)
    local handle <close> = init_quiet()
    return handle:mount(name, nil, be.MNT_DEEP)
end

function _M.umount(name)
    local handle <close> = init_quiet()
    return handle:unmount(name, 0)
end

function _M.activate(name)
    local handle <close> = init_quiet()
    return handle:activate(name, false)
end

function _M.destroy(name, options)
    local handle <close> = init_quiet()
    return handle:destroy(name, options or 0)
end

return _M

-- vim: set et sw=4:
