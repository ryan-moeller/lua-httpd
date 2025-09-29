# Pure Lua httpd

httpd.lua - simple HTTP server library with zero dependencies (except inetd)

## Synposis

Install httpd.lua in your package.path.

Write an executable server script, for example:

`/usr/local/bin/httpd`
```lua
#!/usr/bin/env lua

local httpd = require("httpd")
local server = httpd.create_server("/var/log/httpd.log")
server:add_route("GET", "^/$", function(request)
    return { status=200, reason="ok", body="hello, world!" }
end)
server:run(true)
```

On FreeBSD, use the shebang `#!/usr/libexec/flua` to invoke the base system's
Lua interpreter.  No packages required!

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

Apply the inetd configuration to start servicing requests:

```sh
service inetd restart
```

## Usage

### API

#### `httpd.create_server(logfile) → server`

Create a new HTTP server instance.

* `logfile`: Path to a file where logs will be written.
* Returns a `server` object.

#### `server:add_route(method, pattern, handler)`

Register a handler for a given HTTP method and Lua pattern.

* `method`: HTTP verb (e.g. `"GET"`, `"POST"`)
* `pattern`: Lua string pattern matched against the request path
* `handler`: Function called as `handler(request)` returning a response table

#### `server:run(verbose)`

Run the server. Reads lines from `stdin` and dispatches requests.

* `verbose`: If true, logs each input line to the log file.

### Request Object

Handler functions receive a `request` table with the following fields:

| Field      | Type               | Description                               |
| ---------- | ------------------ | ----------------------------------------- |
| `method`   | string             | HTTP method (e.g. `"GET"`)                |
| `path`     | string             | URL-decoded path component                |
| `params`   | table              | Query parameters (`key -> { values }`)    |
| `version`  | string             | HTTP version (e.g. `"HTTP/1.1"`)          |
| `headers`  | table              | Request headers (lowercased)              |
| `trailers` | table              | Request trailers (if present, lowercased) |
| `cookies`  | table              | Request cookies (`key -> { values }`)     |
| `body`     | string or function | Request body or chunk stream (if present) |
| `matches`  | table              | Captures or match from route Lua pattern  |

### Chunked Body Stream

If `request.body` is a function, it returns an iterator over the stream chunks:

```lua
for chunk, extensions_dict, extensions_string in response.body() do
    -- chunk: bytes
    -- extensions_dict: table of chunk extensions (name -> { values })
    -- extensions_string: the raw extensions part of the chunk size header
end
```

The body chunks iterator must be consumed for `response.trailers` to be set.

### Response Format

Handlers must return a response table:

| Field     | Type               | Description                                |
| --------- | ------------------ | ------------------------------------------ |
| `status`  | integer            | HTTP status code (e.g. `200`, `404`)       |
| `reason`  | string             | Reason phrase (e.g. `"OK"`, `"Not Found"`) |
| `headers` | table              | Optional headers to include                |
| `cookies` | table              | Optional cookies to set (`key -> value`)   |
| `body`    | string or function | Response body or writer function           |

If `body` is a function, it is called with `output` to write the response manually.

### Utility Functions

These functions are also available from the module:

* `httpd.percent_encode(str) → string`
  Encode a string using percent-encoding.

* `httpd.percent_decode(str) → string`
  Decode a percent-encoded string.

* `httpd.parse_query_string(query) → table`
  Parse a URL query string into a table of key → `{ values }`.

## Motivation

I didn't feel like cross-compiling a bunch of stuff for a MIPS router.
It had a Lua interpreter on it, and I like Lua, so I wrote this.

## Error Logging

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
