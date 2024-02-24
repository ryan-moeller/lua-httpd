-- vim: set et:
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

local _M = {}

function _M.list()
    local f = assert(io.popen("bectl list -HC creation", "r"))
    local t = f:read("*a")
    f:close()
    local bes = {}
    local pat = "([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\n"
    for name, active, mountpoint, space, created in t:gmatch(pat) do
        table.insert(bes, {
            name = name,
            active = active,
            mountpoint = mountpoint,
            space = space,
            created = created,
        })
    end
    return bes
end

function _M.create(name)
    assert(os.execute("bectl create "..name))
end

function _M.mount(name)
    local f = assert(io.popen("bectl mount "..name, "r"))
    local mountpoint = f:read("*a"):match("([^\n]+)")
    f:close()
    return mountpoint
end

function _M.umount(name)
    assert(os.execute("bectl umount "..name))
end

function _M.activate(name)
    assert(os.execute("bectl activate "..name.." >/dev/null"))
end

return _M
