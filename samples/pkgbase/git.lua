-- Copyright (c) 2025 Ryan Moeller
--
-- SPDX-License-Identifier: ISC

local exec <const> = require("exec")

local _M <const> = {}

function _M.git(self, ...)
    return table.concat({
        "git", "-C", self.path, ...,
    }, " ")
end

function _M:worktree_list()
    local cmd <const> = self:git("worktree", "list", "--porcelain")
    local f <close>, err <const>, code <const> = io.popen(cmd)
    if not f then
        return nil, err, code
    end
    local list <const> = {}
    local tree = {}
    for line in f:lines() do
        local _, _, field <const>, value = line:find("([^ ]+) ?(.*)")
        if not field then
            table.insert(list, tree)
            tree = {}
        else
            if value == "" then
                value = true
            end
            tree[field] = value
        end
    end
    return list
end

function _M:upstreams()
    local format <const> = "'%(refname)\t%(upstream)'"
    local cmd <const> = self:git("branch", "--list", "--format", format)
    local f <close>, err <const>, code <const> = io.popen(cmd)
    if not f then
        return nil, err, code
    end
    local upstreams <const> = {}
    for line in f:lines() do
        local _, _, ref <const>, upstream <const> = line:find("([^\t]+)\t?(.*)")
        if upstream ~= "" then
            upstreams[ref] = upstream
        end
    end
    return upstreams
end

function _M:pull()
    return exec{"env", "-i", "git", "-C", self.path, "pull", "--ff-only"}
end

function _M.repo(path)
    return setmetatable({path=path}, {__index=_M})
end

return _M

-- vim: set et sw=4:
