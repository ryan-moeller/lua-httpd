# Pure Lua httpd

httpd.lua - simple HTTP server library with "zero" dependencies

## Synposis

Servers using `httpd.lua` perform the following core set of actions:

1. Load the `httpd` module:

```lua
local httpd = require("httpd")
```

2. Create a server object:

```lua
local server = httpd.create_server()
```

3. Add routes to the server:

```lua
server:add_route(method, pattern, handler)
```

4. Run the server:

```lua
server:run()
```

The server script is commonly executed by some inetd-style listener.

Lua 5.3 or newer is required.  Some operating systems (FreeBSD, NetBSD) include
a Lua interpreter as part of the base system.  On FreeBSD, it is installed as
`/usr/libexec/flua`.  On other systems, Lua must be obtained separately.

## Listeners

Lua's standard libraries do not include built-in APIs for low-level socket
management or connection handling.  Typical Unix-like operating systems include
a socket-activation service, such as `inetd`, `launchd`, or `systemd`, to fill
this role.  Tools like `socat` and `ncat` can also be used in simpler or more
specialized scenarios.  Advanced users can provide their own custom listener
to `server:run`.

The following sections provide examples for configuring some common listeners.

The sample servers assume `httpd.lua` is somewhere in your `package.path`.

### inetd

Typical BSD operating systems include `inetd` as part of the base system and
generally have it installed by default.

Write an executable server script, for example:

`/usr/local/bin/httpd`
```lua
#!/usr/bin/env lua
local httpd = require("httpd")
local server = httpd.create_server(httpd.INFO, "/var/log/httpd.log")
server:add_route("GET", "^/$", function(request)
    return { status=200, reason="ok", body="hello, world!" }
end)
server:run()
```

On FreeBSD, use the shebang `#!/usr/libexec/flua` to invoke the base system's
Lua interpreter.  No packages required!

Configure `inetd`:

`/etc/inetd.conf`
```conf
http    stream  tcp     nowait  www    /usr/local/bin/httpd      httpd
```

Prepare the log file:

```sh
touch /var/log/httpd.log
chown www /var/log/httpd.log
```

Apply the `inetd` configuration to start servicing requests:

```sh
service inetd restart
```

### socat

See `socat(1)` for details.

Install `socat`:

```sh
# On FreeBSD:
pkg install socat
```

Write a server script:

`server.lua`
```lua
local httpd = require("httpd")
local server = httpd.create_server(httpd.INFO)
server:add_route("GET", "^/", function(request)
    return { status=200, reason="ok", body="hello, world!" }
end)
server:run()
```

Start listening for connections to the server:

```sh
# listen on *:8080
socat TCP-LISTEN:8080,fork EXEC:"lua server.lua"

# listen on localhost:80, allow binding to a recently used port
socat \
  TCP-LISTEN:80,bind=localhost,reuseaddr,fork \
  EXEC:"lua server.lua"

# listen on *:https, using existing key.pem, cert.pem, and cacert.pem files
socat \
  OPENSSL-LISTEN:443,reuseaddr,fork,key=key.pem,cert=cert.pem,cafile=ca.pem \
  EXEC:"lua server.lua"

# listen on a Unix-domain socket /var/run/server
socat UNIX-LISTEN:/var/run/server,fork EXEC:"lua server.lua"
```

### ncat

See `ncat(1)` for details.

```sh
# install ncat (part of nmap)
pkg install nmap
# listen on *:8080
ncat -k -l 8080 --lua-exec server.lua
# listen on *:https, using existing key.pem, cert.pem, and cacert.pem files
ncat \
  --keep-open \
  --listen 443 \
  --ssl \
  --ssl-key key.pem \
  --ssl-cert cert.pem \
  --ssl-trustfile ca.pem \
  --lua-exec server.lua
```

### launchd

Launchd supports inetd-style processes.  See `launchd.plist(5)` and Apple's
[Dameons and Services Programming Guide][Emulating inetd] for configuration
details.

[Emulating inetd]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html#//apple_ref/doc/uid/10000172i-SW7-SW9

For example, using `lua54` installed from [MacPorts](https://www.macports.org):

`com.example.server.plist`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
 <dict>
  <key>Label</key>
  <string>com.example.server</string>
  <key>ProgramArguments</key>
  <array>
   <string>/opt/local/bin/lua5.4</string>
   <string>server.lua</string>
  </array>
  <key>inetdCompatibility</key>
  <dict>
   <key>Wait</key>
   <false/>
  </dict>
  <key>Sockets</key>
  <dict>
   <key>Listeners</key>
   <dict>
    <key>SocketServiceName</key>
    <string>8080</string>
   </dict>
  </dict>
 </dict>
</plist>
```

```sh
launchctl load com.example.server.plist
```

### systemd

Systemd socket activation can be used to invoke the server.  Broadly, this
involves installing a [`server.socket`][systemd.socket] unit and a
[`server@.service`][systemd.exec] unit.

[systemd.socket]: https://www.freedesktop.org/software/systemd/man/254/systemd.socket.html
[systemd.exec]: https://www.freedesktop.org/software/systemd/man/254/systemd.exec.html

For example:

`server.socket`
```ini
[Unit]
Description=Socket for Lua HTTP server

[Socket]
ListenStream=8080
Accept=yes

[Install]
WantedBy=server.target
```

`server@.service`
```ini
[Unit]
Description=Lua HTTP server

[Service]
ExecStart=lua server.lua
```

```sh
systemctl enable server.socket
systemctl start server.socket
```

## Usage

### API

#### `httpd.create_server([log_level[, log[, id]]]) → server`

Create a new HTTP server instance.

* `log_level`: Optional log output level.  `httpd.FATAL` by default.
* `log`: Optional log path or file-like object.  `io.stderr` by default.
* `id`: Optional identifier for log messages.  PID of the server by default.
* Returns a `server` object.

The following log levels are defined:

| Level | Name          | Description                        |
| ----- | ------------- | ---------------------------------- |
| 1     | `httpd.FATAL` | Errors requiring disconnect        |
| 2     | `httpd.ERROR` | Errors requiring negative response |
| 3     | `httpd.WARN`  | Errors that may be ignored         |
| 4     | `httpd.INFO`  | Brief status information           |
| 5     | `httpd.DEBUG` | Detailed state information         |
| 6     | `httpd.TRACE` | Full request logging               |

#### `server:add_route(method, pattern, handler)`

Register a handler for a given HTTP method and Lua pattern.

* `method`: HTTP verb (e.g. `"GET"`, `"POST"`)
* `pattern`: Lua string pattern matched against the request path
* `handler`: Function called as `handler(request)` returning a response table

#### `server:accept([input[, output[, label]]])`

Handle an accepted connection.  Reads lines from `input` and dispatches requests
to handlers, writing responses to `output`.

* `input`: Optional input file-like object.  `io.stdin` by default.
* `output`: Optional output file-like object.  `io.stdout` by default.
* `label`: Optional client label string.  `"(client)"` by default.

#### `server:run([listener])`

Run the server.  A listener provides an `:accept()` method that takes no
parameters and returns an iterator producing `input, output, label`, to pass to
`server:accept()`, where `input` and `output` are file-like streams and `label`
is a string to identify the client.  The default listener produces
`io.stdin, io.stdout, "(stdio)"` once.

### Server Object

The server object has one field of interest: `server.log`.  The log object is a
wrapper around the `log` parameter to `httpd.create_server` (or `io.stderr`)
with the methods for writing lines to the log:

* `:fatal`
* `:error`
* `:warn`
* `:info`
* `:debug`
* `:trace`

Each method takes any number of parameters.  If `server.log.level` is at least
as severe, it converts the parameters to strings with `tostring`, concatenates
them with `table.concat`, and writes a line to the log file.  Each line begins
with a timestamp, process identifier, context label, and log level, followed by
the joined parameters, and ending with a newline.

For example:

```lua
log:trace("number=", 13)
```

writes something like

```
2025-10-12T15:42:05Z 16811 (stdio) TRACE: number=13
```

The context label is stored in `log.label` while servicing a client connection.
It is simply a string used to label log messages.

### Request Object

Handler functions receive a `request` table with the following fields:

| Field        | Type               | Description                              |
| ------------ | ------------------ | ---------------------------------------- |
| `method`     | string             | HTTP method (e.g. `"GET"`)               |
| `path`       | string             | URL-decoded path component               |
| `params`     | table              | Query parameters (`key -> { values }`)   |
| `version`    | string             | HTTP version (e.g. `"HTTP/1.1"`)         |
| `headers`    | table              | Request headers (lowercased)             |
| `trailers`   | table              | Request trailers (if any, lowercased)    |
| `cookies`    | table              | Request cookies set by `Cookie` header   |
| `body`       | string or function | Request body or chunk stream (if any)    |
| `matches`    | table              | Captures or match from route Lua pattern |
| `connection` | table              | Reference to the connection object       |

### Request Headers and Trailers

The `request.headers` and `request.trailers` tables use lowercased names as keys
and tables with the following structure as values:

| Field         | Type  | Description                                        |
| ------------- | ----- | -------------------------------------------------- |
| `unvalidated` | table | List of unvalidated field values in order received |
| `raw`         | table | List of validated field values in order received   |
| `elements`    | table | List of parsed field values in order received      |

The `elements` field contains the list of elements parsed from the field values
received for this header field.  An `element` is a table with the following
optional fields:

| Field    | Type   | Description                                              |
| -------- | ------ | -------------------------------------------------------- |
| `value`  | string | A token/quoted-string value (quotes/escapes removed)     |
| `params` | table  | List of element parameters in order received (see below) |

One or both fields may be present.

The `params` list contains parameters in either name-value or attribute form.

The name-value form is as follows:

| Field   | Type   | Description                                            |
| ------- | ------ | ------------------------------------------------------ |
| `name`  | string | The token preceding "=" in the parameter               |
| `value` | string | The token/quoted-string value (quotes/escapes removed) |

The attribute form:

| Field       | Type   | Description              |
| ----------- | ------ | ------------------------ |
| `attribute` | string | The attribute name token |

A few convenience methods are also provided on header/trailer objects:

| Method                   | Description                                       |
| ------------------------ | ------------------------------------------------- |
| `:concat(...)`           | Returns `table.concat(self.raw, ...)`             |
| `:contains_value(value)` | Tests if any element value field equals `value`   |
| `:find_elements(value)`  | Returns a list of the elements with value `value` |

Headers are validated and parsed lazily, so headers that are not accessed via
`raw`, `elements`, or a convenience method do not get validated or parsed.

### Request Cookies

The `request.cookies` table is a list of validated and parsed cookies from the
`Cookie` header, or an empty table if no valid `Cookie` header was received.
Validation and parsing only checks cookie syntax, not semantics.  A cookie is
parsed as a cookie-pair with the following form:

| Field   | Type   | Description                                     |
| ------- | ------ | ----------------------------------------------- |
| `name`  | string | The cookie-name token                           |
| `value` | string | The cookie-value cookie-octets (quotes removed) |

### Chunked Body Stream

If `request.body` is a function, it returns an iterator over the stream chunks:

```lua
for chunk, extensions_dict, extensions_string in request.body() do
    -- chunk: bytes
    -- extensions_dict: table of chunk extensions (name -> { values })
    -- extensions_string: the raw extensions part of the chunk size header
end
```

The body chunks iterator must be consumed for `response.trailers` to be set.

To send a chunked response body, include a "Transfer-Encoding: chunked" header
in the response object and use `httpd.write_chunk(output, chunk, exts)` and
`httpd.write_trailers(output, trailers)` in the reponse body function.

### Response Format

Handlers must return a response table:

| Field     | Type               | Description                                |
| --------- | ------------------ | ------------------------------------------ |
| `status`  | integer            | HTTP status code (e.g. `200`, `404`)       |
| `reason`  | string             | Reason phrase (e.g. `"OK"`, `"Not Found"`) |
| `headers` | table              | Optional headers to send (`name -> value`) |
| `cookies` | table              | Optional cookies to set (`name -> value`)  |
| `body`    | string or function | Response body or writer function           |

To send multiple headers with the same name, set the value to a list of strings.
Each string will be sent in order as a separate header field.

A Date header is automatically added if not present in `response.headers`.

A Content-Length header is automatically added when `response.body` is a string.

Handlers are responsible for incorporating any cookie attributes into the value
string.

If `body` is a function, it is called with a `connection` object and must write
the response manually.  The `connection` object is described in further detail
below.

### Connection Object

The connection object passed to a `body` function has the following fields of
interest:

| Field     | Type      | Description                              |
| --------- | --------- | ---------------------------------------- |
| `request` | table     | The request object passed to the handler |
| `server`  | table     | Reference to the server object           |
| `input`   | file-like | The input stream (from `server:accept`)  |
| `output`  | file-like | The output stream (from `server:accept`) |

The connection object also provides the following convenience methods:

| Method                            | Description                            |
| --------------------------------- | -------------------------------------- |
| `:read(...)`                      | Proxy for `self.input:read(...)`       |
| `:lines(...)`                     | Proxy for `self.input:lines(...)`      |
| `:write(...)`                     | Proxy for `self.output:write(...)`     |
| `:write_chunk(chunk[, exts])`     | Chunk-encode a string to `self.output` |
| `:last_chunk([trailers[, exts]])` | End a chunk-encoded transfer           |

`:write_chunk` encodes and writes a chunk (bytes) to the connection output,
optionally with a list of extensions.

`:last_chunk` writes the last-chunk to the connection output, optionally with a
list of extensions, then writes any trailer fields, and finally writes CRLF to
terminate the response.

Chunk extensions are given as a list of strings.

### Utility Functions

These functions are also available from the module:

* `httpd.percent_encode(str) → string`
  Encode a string using percent-encoding.

* `httpd.percent_decode(str) → string`
  Decode a percent-encoded string.

* `httpd.parse_query_string(query) → table`
  Parse a URL query string into a table of key → `{ values }`.

* `httpd.format_date([time]) -> string`
  Format an HTTP Date string using `os.date()` with the appropriate format.

* `httpd.parse_date(str) -> number`
  Parse an HTTP Date string into a time using `os.time()` with the appropriate
  parts of `str`.

## Motivation

I didn't feel like cross-compiling a bunch of stuff for a MIPS router.
It had a Lua interpreter on it, and I like Lua, so I wrote this.

## Error Logging under Inetd

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

This is for capturing Lua errors specifically, not error level messages to the
server log.  The server log and stderr may be directed to the same file, or not.

[1]: https://github.com/ryan-moeller/flualibs
