-- vim: set et sw=4:
--
-- Copyright (c) 2024 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local _M <const> = {}

local fetch <const> = require("fetch")
local bectl <const> = require("bectl")
local lfs <const> = require("lfs")
local nicenum <const> = require("be").nicenum
local sysctl <const> = require("sysctl")

_M.logfile = "/dev/null"
_M.basedir = "/system"
_M.snapshots_site = "https://download.freebsd.org/ftp/snapshots"
_M.arch = sysctl("hw.machine"):value()
_M.branch = sysctl("kern.osrelease"):value()
_M.distributions = {"kernel.txz", "kernel-dbg.txz", "base.txz", "base-dbg.txz", "src.txz"}
_M.config_files = {"passwd", "group", "master.passwd", "services", "inetd.conf"}

local function snapshot_file_url(path)
    return table.concat({_M.snapshots_site, _M.arch, _M.branch, path}, "/")
end

function _M.snap_list()
    local ents <const> = {}
    -- We'll assume this works for now.
    for ent in lfs.dir(_M.basedir) do
        local path <const> = _M.basedir.."/"..ent
        if ent ~= "." and ent ~= ".." and lfs.attributes(path).mode == "directory" then
            table.insert(ents, ent)
        end
    end
    table.sort(ents, function(a, b) return a > b end)
    local snaps <const> = {}
    for _, ent in ipairs(ents) do
        local snap <const> = {}
        snap.name = ent
        local date <const> = ent:match("([^-]+)-")
        local year <const> = string.sub(date, 1, 4)
        local month <const> = string.sub(date, 5, 6)
        local day <const> = string.sub(date, 7, 8)
        snap.build_date = string.format("%s-%s-%s", year, month, day)
        snap.revision = ent:match("-([^-]+)")
        table.insert(snaps, snap)
    end
    return snaps
end

function _M.snap_delete(name)
    local cmd <const> = string.format("rm -rf %s/%s", _M.basedir, name)
    local redir <const> = string.format(" >>%s 2>>%s", _M.logfile, _M.logfile)
    assert(os.execute(cmd..redir))
end

local function fetch_snapshot_meta(name)
    local f <close>, err <const> = fetch.get(snapshot_file_url(name))
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

local function fetch_file(url, path, fetch_progress)
    local inf <close>, stat <const>, code <const> = fetch.xget(url)
    if not inf then
        local err <const> = stat
        return nil, err, code
    end
    local outf <close>, err <const>, code <const> = io.open(path, "w+")
    if not outf then
        return nil, err, code
    end
    local bufsize <const> = 16384 -- fetch.c MINBUFSIZE
    inf:setvbuf("full", bufsize)
    local fetched = 0
    local target <const> = stat.size
    repeat
        local buf <const>, err <const>, code <const> = inf:read(bufsize)
        if not buf then
            return nil, err, code
        end
        fetched = fetched + #buf
        fetch_progress(fetched, target)
        if #buf == 0 then
            break
        end
        local ok <const>, err <const>, code <const> = outf:write(buf)
        if not ok then
            return nil, err, code
        end
        if #buf < bufsize then
            break
        end
    until false
    return true
end

function _M.update(set_progress)
    local steps <const> = 11 + #_M.config_files + 2 * #_M.distributions  -- total number of steps
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
    local archives <const> = _M.basedir.."/"..name
    if not lfs.mkdir(archives) then
        local attrs <const>, err <const> = lfs.attributes(archives)
        if not attrs then
            return nil, err
        end
        if attrs.mode ~= "directory" then
            return nil, "Basedir is not a directory!"
        end
    end
    for _, f in ipairs(_M.distributions) do
        description = description..sep..f
        sep = ", "
        progress(description)
        function fetch_progress(fetched, target)
            local prevstep <const> = step - 1
            local size <const> = nicenum(fetched) .. "B"
            if target > 0 then
                local progress <const> = (prevstep + fetched / target) / steps
                local targetsize <const> = nicenum(target) .. "B"
                local desc <const> = string.format("%s (%s/%s)", description, size, targetsize)
                set_progress(progress, desc)
            else
                local progress <const> = prevstep / steps
                local desc <const> = string.format("%s (%s)", description, size)
                set_progress(progress, desc)
            end
        end
        local path <const> = archives.."/"..f
        local url <const> = snapshot_file_url(f)
        local ok <const>, err <const>, rc <const> =
            fetch_file(url, path, fetch_progress)
        if not ok then
            return nil, err, rc
        end
    end

    progress("Creating boot environment")
    bectl.create(name)

    progress("Mounting boot environment")
    local mountpoint <const> = bectl.mount(name)

    progress("Setting filesystem flags")
    local cmd <const> = string.format("chflags -R noschg %s", mountpoint)
    local redir <const> = string.format(" >>%s 2>>%s", _M.logfile, _M.logfile)
    local ok <const>, err <const>, rc <const> = os.execute(cmd..redir)
    if not ok then
        return nil, err, rc
    end

    local description = "Extracting archives"
    local sep = ": "
    progress(description)
    for _, f in ipairs(_M.distributions) do
        description = description..sep..f
        sep = ", "
        progress(description)
        if f == "src.txz" then
            -- XXX: won't preserve local changes in /usr/src
            local cmd <const> = "rm -rf /usr/src/*"
            local ok <const>, err <const>, rc <const> = os.execute(cmd..redir)
            if not ok then
                return nil, err, rc
            end
            local cmd <const> = string.format("tar -xf %s/%s -C /", archives, f)
            local ok <const>, err <const>, rc <const> = os.execute(cmd..redir)
            if not ok then
                return nil, err, rc
            end
        else
            -- TODO: remove obsolete files from cloned be
            local cmd <const> = string.format("tar -xf %s/%s -C %s", archives, f, mountpoint)
            local ok <const>, err <const>, rc <const> = os.execute(cmd..redir)
            if not ok then
                return nil, err, rc
            end
        end
    end

    local description = "Copying system config files"
    local sep = ": "
    progress(description)
    for _, f in ipairs(_M.config_files) do
        description = description..sep..f
        sep = ", "
        progress(description)
        -- cat to preserve metadata (etcupdate does it this way)
        local cmd <const> = string.format("cat /etc/%s >%s/etc/%s", f, mountpoint, f)
        local redir2 <const> = " 2>>".._M.logfile
        local ok <const>, err <const>, rc <const> = os.execute(cmd..redir2)
        if not ok then
            return nil, err, rc
        end
    end

    progress("Regenerating system databases")
    local cmd <const> = string.format("pwd_mkdb -d %s/etc -p %s/etc/master.passwd", mountpoint, mountpoint)
    local ok <const>, err <const>, rc <const> = os.execute(cmd..redir)
    if not ok then
        return nil, err, rc
    end
    local cmd <const> = string.format("services_mkdb -q -o %s/var/db/services.db %s/etc/services", mountpoint, mountpoint)
    local ok <const>, err <const>, rc <const> = os.execute(cmd..redir)
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
