-- vim: set et sw=4:
--
-- Copyright (c) 2024 Ryan Moeller <ryan-moeller@att.net>
--
-- Permission to use, copy, modify, and distribute this software for any
-- purpose with or without fee is hereby granted, provided that the above
-- copyright notice and this permission notice appear in all copies.
--
-- THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
-- WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
-- MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
-- ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
-- WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
-- ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
-- OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
--

local _M <const> = {}

local bectl <const> = require("bectl")
local lfs <const> = require("lfs")

local function freebsd_version()
    local f <close> = assert(io.popen("freebsd-version", "r"))
    local version <const> = f:read("*a"):match("([^\n]+)")
    return version
end

-- TODO: make these configurable
local basedir <const> = "/system"
local branch <const> = freebsd_version()
local distributions <const> = {"kernel.txz", "kernel-dbg.txz", "base.txz", "base-dbg.txz", "src.txz"}
local snapshots_site <const> = "https://download.freebsd.org/ftp/snapshots/amd64/amd64/"..branch
local config_files <const> = {"passwd", "group", "master.passwd", "services", "inetd.conf"}

function _M.snap_list()
    local ents <const> = {}
    -- We'll assume this works for now.
    for ent in lfs.dir(basedir) do
        local path <const> = basedir.."/"..ent
        if ent ~= "." and ent ~= ".." and lfs.attributes(path).mode == "directory" then
            table.insert(ents, ent)
        end
    end
    table.sort(ents, function(a, b) return a > b end)
    local snaps <const> = {}
    for _, ent in ipairs(ents) do
        local snap <const> = {}
        snap.name = ent
        snap.build_date = ent:match("([^-]+)-")
        snap.revision = ent:match("-([^-]+)")
        table.insert(snaps, snap)
    end
    return snaps
end

function _M.snap_delete(name)
    assert(os.execute("rm -rf "..basedir.."/"..name))
end

local function fetch_snapshot_meta(name)
    local f <close>, err <const> = io.popen("fetch -qo - "..snapshots_site.."/"..name)
    if not f then
        return nil, err
    end
    local t <const> = f:read("*a"):match("([^\n]+)")
    return t
end

function _M.latest()
    local builddate <const>, err <const> = fetch_snapshot_meta("BUILDDATE")
    if not builddate then
        return nil, err
    end
    local revision <const>, err <const> = fetch_snapshot_meta("REVISION")
    if not revision then
        return nil, err
    end
    return builddate.."-"..revision
end

function _M.update(set_progress)
    local steps <const> = 11 + #config_files + 2 * #distributions  -- total number of steps
    local step = 1
    local function progress(description)
        set_progress(step / steps, description)
        step = step + 1
    end

    progress("Fetching latest snapshot metadata")
    local name <const>, err <const> = _M.latest()
    if not name then
        return nil, err
    end

    local description = "Fetching archives"
    local sep = ": "
    progress(description)
    local archives <const> = basedir.."/"..name
    if not lfs.mkdir(archives) then
        local attrs <const>, err <const> = lfs.attributes(archives)
        if not attrs then
            return nil, err
        end
        if attrs.mode ~= "directory" then
            return nil, "Basedir is not a directory!"
        end
    end
    for _, f in ipairs(distributions) do
        description = description..sep..f
        sep = ", "
        progress(description)
        local path <const> = archives.."/"..f
        local url <const> = snapshots_site.."/"..f
        -- TODO: fire off a background task, show progress to user?
        local ok <const>, err <const>, rc <const> = os.execute("fetch -qmo "..path.." "..url)
        if not ok then
            return nil, err, rc
        end
    end

    progress("Creating boot environment")
    bectl.create(name)

    progress("Mounting boot environment")
    local mountpoint <const> = bectl.mount(name)

    progress("Setting filesystem flags")
    local ok <const>, err <const>, rc <const> = os.execute("chflags -R noschg "..mountpoint)
    if not ok then
        return nil, err, rc
    end

    local description = "Extracting archives"
    local sep = ": "
    progress(description)
    for _, f in ipairs(distributions) do
        description = description..sep..f
        sep = ", "
        progress(description)
        if f == "src.txz" then
            -- TODO: preserve local changes in /usr/src
            local ok <const>, err <const>, rc <const> = os.execute("rm -rf /usr/src/*")
            if not ok then
                return nil, err, rc
            end
            local ok <const>, err <const>, rc <const> = os.execute("tar -xf "..archives.."/"..f.." -C /")
            if not ok then
                return nil, err, rc
            end
        else
            -- TODO: remove obsolete files from cloned be
            local ok <const>, err <const>, rc <const> = os.execute("tar -xf "..archives.."/"..f.." -C "..mountpoint)
            if not ok then
                return nil, err, rc
            end
        end
    end

    local description = "Copying system config files"
    local sep = ": "
    progress(description)
    for _, f in ipairs(config_files) do
        description = description..sep..f
        sep = ", "
        progress(description)
        -- cat to preserve metadata (etcupdate does it this way)
        local ok <const>, err <const>, rc <const> = os.execute("cat /etc/"..f.." >"..mountpoint.."/etc/"..f)
        if not ok then
            return nil, err, rc
        end
    end

    progress("Regenerating system databases")
    local ok <const>, err <const>, rc <const> = os.execute("pwd_mkdb -d "..mountpoint.."/etc -p "..mountpoint.."/etc/master.passwd")
    if not ok then
        return nil, err, rc
    end
    local ok <const>, err <const>, rc <const> = os.execute("services_mkdb -q -o "..mountpoint.."/var/db/services.db "..mountpoint.."/etc/services")
    if not ok then
        return nil, err, rc
    end
    -- TODO: any other files that are overwritten by the archive extraction and need preservation,
    -- proper 3-way merge like etcupdate...

    progress("Unmounting boot environment")
    bectl.umount(name)

    progress("Activating boot environment")
    bectl.activate(name)

    progress("Update finished, please reboot")
    return true
end

return _M
