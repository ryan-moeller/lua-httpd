-- Copyright (c) 2025 Ryan Moeller
--
-- SPDX-License-Identifier: ISC

local exec <const> = require("exec")
local lfs <const> = require("lfs")
local posix <const> = require("posix")
local sysctl <const> = require("sys.sysctl")

local ncpu <const> = sysctl.sysctl("hw.ncpu"):value()

local _M <const> = {}

function _M.new(srctop, makeobjdirprefix, kernconf)
    return setmetatable({
        srctop = srctop,
        makeobjdirprefix = makeobjdirprefix,
        kernconf = kernconf or "GENERIC", -- TODO: how to keep track of this?
    }, {__index=_M})
end

local function path(...)
    return table.concat(table.pack(...), "/")
end

function _M:repo_list()
    local repos <const> = {}
    local repodir <const> = path(self.makeobjdirprefix, self.srctop, "repo")
    local st <const> = lfs.attributes(repodir)
    if not st or st.mode ~= "directory" then
        return nil
    end
    for repoent in lfs.dir(repodir) do
        if repoent ~= "." and repoent ~= ".." then
            local abidir <const> = path(repodir, repoent)
            local st <const> = lfs.attributes(abidir)
            if st and st.mode == "directory" then
                local repo <const> = { pkg_abi = repoent, versions = {} }
                for abient in lfs.dir(abidir) do
                    if abient ~= "." and abient ~= ".." then
                        local verdir <const> = path(abidir, abient)
                        local st <const> = lfs.attributes(verdir)
                        if st and st.mode == "directory" then
                            if abient == "latest" then
                                local realpath <const> = posix.stdlib.realpath(verdir)
                                repo.latest = posix.libgen.basename(realpath)
                            else
                                table.insert(repo.versions, abient)
                            end
                        end
                    end
                end
                table.insert(repos, repo)
            end
        end
    end
    return repos
end

-- Returns an interator that yields a pipe fd, pid, and target for each step of
-- the build.  The caller must wait() the pids and close() the pipes.  Set
-- `fake' to something like "echo" for testing.
function _M:start_build(j, fake)
    j = tonumber(j)
    if not j or j < 1 or j > (ncpu + 1) then
        j = ncpu + 1
    end
    local function srcmake(target)
        local r <const>, pid <const> = exec{
            "env", "-i",
            "MAKEOBJDIRPREFIX="..self.makeobjdirprefix,
            "KERNCONF="..self.kernconf,
            fake or "make",
            "-C", self.srctop,
            "-j"..tostring(j),
            "-DWITH_META_MODE",
            "-DWITH_CCACHE_BUILD",
            "-DNO_ROOT",
            "-DDB_FROM_SRC",
            "-DKERNFAST="..self.kernconf,
            target
        }
        return r, pid, target
    end
    local step = 0
    local targets <const> = { "buildworld", "buildkernel", "packages" }
    return function()
        step = step + 1
        local target <const> = targets[step]
        if target then
            return srcmake(target)
        end
    end
end

function _M:delete_build(pkg_abi, version)
    local builddir <const> =
        path(self.makeobjdirprefix, self.srctop, "repo", pkg_abi, version)
    -- TODO: check real path is safe
    -- TODO: actually traverse the tree and check each file is safe to remove...
    -- TODO: relink latest
    return exec{"env", "-i", "rm", "-frvx", "--", builddir}
end

return _M

-- vim: set et sw=4:
