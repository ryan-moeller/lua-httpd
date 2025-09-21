# Pure Lua httpd

## Name

httpd.lua - simple HTTP server library with zero dependencies (except inetd)

## Synposis

Install httpd.lua in your package.path.

Write an executable server script, for example:
`/usr/local/bin/httpd`
```lua
#!/usr/bin/env lua

local httpd = require("httpd")
local server = httpd.create_server("/var/log/httpd.log")
server:add_route("GET", "/", function(request)
    return { status=200, reason="ok", body="hello, world!" }
end)
server:run(true)
```

Configure inetd:
`/etc/inetd.conf`
```conf
http    stream  tcp     nowait  www    /usr/local/bin/httpd      httpd
```

Prepare the log file:
```sh
touch /var/log/httpd.log
chown www /var/log/httpd.log
```

## Description

I didn't feel like cross-compiling a bunch of stuff for a MIPS router I
have.  It has Lua interpreter on it, and I like Lua, so I wrote this.

## Error logging

Inetd populates stdin, stdout, and stderr descriptors with the socket.  This is
not ideal for error logging, since errors will be sent to the client and break
the HTTP protocol.  To remedy, [ryan-moeller/flualibs][1] has a `fileno` library
that can be combined with FreeBSD's `posix.unistd.dup2` as follows:

```lua
do
    local posix <const> = require("posix")
    local STDERR_FILENO <const> = 2
    require("fileno") -- from ryan-moeller/flualibs
    local f <close> = io.open("/var/log/httpd-errors.log", "a+")
    f:setvbuf("no")
    assert(posix.unistd.dup2(f:fileno(), STDERR_FILENO) == STDERR_FILENO)
end
```

Placing the above early in your server script will ensure errors are logged to
a file on the server instead of confusing the client.

[1]: https://github.com/ryan-moeller/flualibs
