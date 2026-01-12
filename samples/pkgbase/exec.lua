-- Copyright (c) 2025 Ryan Moeller
--
-- SPDX-License-Identifier: ISC

local posix <const> = require("posix")

return function(argv)
    -- XXX: fbsd.exec() would be easier, but we want stdout and stderr to go
    -- through the same pipe so ordering is preserved.
    local r <const>, w <const> = assert(posix.unistd.pipe())
    local pid <const> = assert(posix.unistd.fork())
    if pid == 0 then
        local STDIN_FILENO <const> = 0
        local STDOUT_FILENO <const> = 1
        local STDERR_FILENO <const> = 2
        assert(posix.unistd.close(r))
        assert(posix.unistd.close(STDIN_FILENO))
        assert(posix.unistd.dup2(w, STDOUT_FILENO))
        assert(posix.unistd.dup2(w, STDERR_FILENO))
        assert(posix.unistd.close(w));
        -- XXX: Want posix.unistd.closefrom() here.
        -- XXX: This seems to work correctly only when argv[1] is "env".
        assert(posix.unistd.execp(argv[1], argv))
        posix.unistd._exit()
    end
    assert(posix.unistd.close(w))
    return r, pid
end

-- vim: set et sw=4:
