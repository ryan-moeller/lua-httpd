--
-- Copyright (c) 2016-2025 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local M = {}

M.VERSION = '0.0.4'


-- HTTP-message = start-line
--                *( header-field CRLF )
--                CRLF
--                [ message-body ]
--
-- The server reads HTTP-messages from stdin and parses the data in order
-- to route and dispatch to a handler for processing.
--
-- The server state is a waiting state. So if server.state == START_LINE,
-- we're looking for a start line next.
local ServerState = {
   START_LINE = 0,
   HEADER_FIELD = 1,
   TRAILER_FIELD = 2,
}


local function decode(s)
   local function char(hex)
      return string.char(tonumber(hex, 16))
   end

   s = string.gsub(s, "+", " ")
   s = string.gsub(s, "%%(%x%x)", char)
   s = string.gsub(s, "\r\n", "\n")

   return s
end


local function encode(s)
   local function hex(char)
      return string.format("%%%02X", string.byte(char))
   end

   s = string.gsub(s, "\n", "\r\n")
   s = string.gsub(s, "([^%w %-%_%.%~])", hex)
   s = string.gsub(s, " ", "+")

   return s
end


local function parse_request_query(query)
   local params = {}

   local function parse(kv)
      local encoded_key, encoded_value = string.match(kv, "^(.*)=(.*)$")
      if encoded_key ~= nil then
         local key = decode(encoded_key)
         local value = decode(encoded_value)
         local param = params[key] or {}
         table.insert(param, value)
         params[key] = param
      end
   end

   string.gsub(query, "([^;&]+)", parse)

   return params
end


local function parse_request_path(s)
   local encoded_path, encoded_query = string.match(s, "^(.*)%?(.*)$")
   if encoded_path == nil then
      return decode(s), {}
   end

   local path = decode(encoded_path)
   local params = parse_request_query(encoded_query)

   return path, params
end

local function handle_start_line(server, line)
   -- start-line = request-line / status-line
   -- request-line = method SP request-target SP HTTP-version CRLF
   -- method = token
   local method, rawpath, version = line:match("^(%g+) (%g+) (HTTP/1.1)\r$")
   if not method then
      -- No match.  We'll just log the oddity and try the next line.
      server.log:write("Invalid start-line in request.\n")
      return ServerState.START_LINE
   end
   local path, params = parse_request_path(rawpath)
   server.request = {
      server = server,
      method = method,
      path = path,
      params = params,
      version = version,
      headers = {},
      cookies = {}
   }
   return ServerState.HEADER_FIELD
end


-- Helper for writing a list of headers/trailers.
-- This includes the terminator.
local function write_headers(output, headers, cookies)
   for name, value in pairs(headers or {}) do
      output:write(name, ": ", value, "\r\n")
   end
   for name, value in pairs(cookies or {}) do
      output:write("Set-Cookie: ", name, "=", value, "\r\n")
   end
   output:write("\r\n")
end


-- expects a server table and a response table
-- example response table:
-- { status=404, reason="not found", headers={}, cookies={},
--   body="404 Not Found" }
local function write_http_response(server, response)
   local output = server.output

   local status = response.status
   local reason = response.reason
   local headers = response.headers or {}
   local cookies = response.cookies or {}
   local body = response.body

   if type(body) == "string" then
      headers['Content-Length'] = #body
   end

   local statusline = string.format("HTTP/1.1 %03d %s\r\n", status, reason)
   output:write(statusline)

   write_headers(output, headers, cookies)

   if type(body) == "string" then
      output:write(body)
   elseif type(body) == "function" then
      output:flush()
      body(output)
   end
end


--[[
-- Log some debugging info
local function debug_server(server)
   local log = server.log
   local request = server.request
   local handlers = server.handlers[request.method]

   log:write("#server.handlers = " .. tostring(#server.handlers) .. "\n")
   log:write("#handlers = " .. tostring(#handlers) .. "\n")
   log:write(request.method .. "\n")
   if request.path ~= nil then
      log:write(request.path, "\n")
   end
   for k, v in pairs(request.headers) do
      log:write("> " .. k .. ": ")
      for k1, v1 in pairs(v) do
         log:write(k1, "->")
         for _, v2 in ipairs(v1) do
            log:write(v2 .. ", ")
         end
         log:write("; ")
      end
      log:write("\n")
   end
   for k, v in pairs(request.params) do
      log:write(k .. " = ")
      for _, v in ipairs(v) do
         log:write(v .. ", ")
      end
      log:write("\n")
   end
end
]]--


local function handle_request(server)
   local request = server.request
   local handlers = server.handlers[request.method]
   local response

   --debug_server(server)

   -- Check if we implement this method.
   if not handlers then
      response = { status=501, reason="Not Implemented", body="not implemented" }
      goto respond
   end

   -- Try to find a location matching the request.
   response = { status=404, reason="Not Found", body="not found" }
   for _, location in ipairs(handlers) do
      local pattern, handler = table.unpack(location)
      local matches = { string.match(request.path, pattern) }
      if #matches > 0 then
         request.matches = matches
         response = handler(request)
         break
      end
   end

   ::respond::
   write_http_response(server, response)

   -- Close all open file handles and exit to complete the response.
   -- TODO: pipelining
   os.exit()
end


-- TODO: strict parser FSM handling quoting and escapes according to spec
-- Try to handle some simple common quoted headers for now.


local function parse_header_value(header, value)
   header.raw = value

   local function parse(attrib)
      table.insert(header.list, attrib)
      local key, value = attrib:match("^%s*(.*)=\"?(.*)\"?%s*$")
      if key then
         local attrval = header.dict[key] or {}
         table.insert(attrval, value)
         header.dict[key] = attrval
      end
   end

   value:gsub("([^;]+)", parse)

   return header
end


local function parse_header_field(line)
   local name, value = line:match('^(%g+):%s*"([^";]+)"%s*\r$')
   if name and value then
      return name, value
   end
   return line:match("^(%g+):%s*(.*)%s*\r$")
end


local function update_trailer(server, name, value)
   local trailers = server.request.trailers
   -- Trailer may be repeated to form a list.
   local trailer = trailers[name] or { dict={}, list={} }
   trailers[name] = parse_header_value(trailer, value)
end


local function handle_trailer_field(server, line)
   if line == "\r" then
      -- When there are no trailers left we get just a blank line.
      -- That marks the end of this request.
      return ServerState.START_LINE
   else
      local name, value = parse_header_field(line)

      if name then
         -- Header field names are case-insensitive.
         local lname = string.lower(name)
         update_trailer(server, lname, value)
      else
         server.log:write("Ignoring invalid trailer: ", line, "\n")
      end

      -- Look for more trailers.
      return ServerState.TRAILER_FIELD
   end
end


local function handle_chunked_message_body(server)
   if server.verbose then
      server.log:write("body is chunked\n")
   end
   -- For a chunked transfer, the body field of the request object will be a
   -- function returning an iterator over the chunks, used like:
   -- for chunk, exts_dict, exts_str in request.body() do
   --     -- do things
   -- end
   -- This enables streaming content without having to fully buffer it.
   server.request.body = function()
      return function()
         local chunk_size_line = server.input:read("*l")
         if not chunk_size_line then
            server.log:write("unexpected EOF\n")
            return
         end
         local chunk_size_hex, exts_str = chunk_size_line:match("^(%x+)(.*)\r$")
         if not chunk_size_hex then
            server.log:write("invalid chunk size\n")
            return
         end
         local chunk_size = tonumber(chunk_size_hex, 16)
         if not chunk_size or chunk_size > server.max_chunk_size then
            server.log:write("invalid chunk size\n")
            -- TODO: There are a ton of these error conditions that should
            -- send a response before aborting.  Like 413 Payload Too Large...
            return
         end
         if server.verbose then
            server.log:write("chunk size = ", chunk_size, "\n")
            server.log:write("chunk extensions = ", exts_str, "\n")
         end
         if chunk_size == 0 then
            -- This is the end of the body.  Now read any trailer fields before
            -- returning control to the handler.
            server.request.trailers = {}
            for line in server.input:lines() do
               server.state = handle_trailer_field(server, line)
               if server.state ~= ServerState.TRAILER_FIELD then
                  break
               end
            end
            return
         end
         local chunk = ""
         repeat
            local buf = server.input:read(chunk_size - #chunk)
            if not buf or #buf == 0 then
               server.log:write("error reading body chunk\n")
               return
            end
            chunk = chunk .. buf
            assert(#chunk <= chunk_size)
         until #chunk == chunk_size
         local crlf = server.input:read(2)
         if crlf ~= "\r\n" then
            server.log:write("invalid chunk-data terminator\n")
            return
         end
         -- It is technically allowed for extension names to be repeated, so
         -- we provide multiple interpretations of the extensions for
         -- convenience.
         local exts_dict = {}
         for ext in exts_str:gmatch(";([^;]+)") do
            local name, value = ext:match('([^=]+)=?"?(.*)"?')
            local extension = exts_dict[name] or {}
            table.insert(extension, #value > 0 and value or true)
            exts_dict[name] = extension
         end
         return chunk, exts_dict, exts_str
      end
   end
   handle_request(server)
end


local function handle_message_body(server, content_length)
   local body = ""
   repeat
      local buf = server.input:read(content_length - #body)
      if buf then
         body = body .. buf
      else
         server.log:write("body shorter than specified content length\n")
         break
      end
   until #body == content_length

   if server.verbose then
      server.log:write("content length = ", content_length, "\n")
      server.log:write(body, "\n")
   end
   server.request.body = body
   handle_request(server)
end


local function handle_blank_line(server)
   local request = server.request
   local transfer_encoding_header = request.headers['transfer-encoding']
   local content_length_header = request.headers['content-length']

   if transfer_encoding_header then
      if transfer_encoding_header.raw == "chunked" then
         return handle_chunked_message_body(server)
      else
         server.log:write("unsupported transfer-encoding\n")
      end
   elseif content_length_header then
      local values = content_length_header.list
      local value = values[#values]
      local content_length = tonumber(value)
      if content_length then
         return handle_message_body(server, content_length)
      else
         server.log:write("invalid content-length\n")
      end
   end
   return handle_request(server)
end


local function set_cookie(server, cookie)
   -- Browsers do not send cookie attributes in requests.
   local name, value = string.match(cookie, "(.+)=(.*)")
   local cookie = server.request.cookies[name] or {}
   table.insert(cookie, value)
   server.request.cookies[name] = cookie
end


local function update_header(server, name, value)
   local headers = server.request.headers
   -- Header may be repeated to form a list.
   local header = headers[name] or { dict={}, list={} }
   headers[name] = parse_header_value(header, value)
end


local function handle_header_field(server, line)
   if line == "\r" then
      -- When there are no headers left we get just a blank line.
      return handle_blank_line(server)
   else
      local name, value = parse_header_field(line)

      if name then
         -- Header field names are case-insensitive.
         local lname = string.lower(name)
         if lname == "cookie" then
            set_cookie(server, value)
         else
            update_header(server, lname, value)
         end
      else
         server.log:write("Ignoring invalid header: ", line, "\n")
      end

      -- Look for more headers.
      return ServerState.HEADER_FIELD
   end
end


local function handle_request_line(server, line)
   local state = server.state

   if state == ServerState.START_LINE then
      return handle_start_line(server, line)

   elseif state == ServerState.HEADER_FIELD then
      return handle_header_field(server, line)

   else
      return ServerState.START_LINE

   end
end


M.default_max_chunk_size = 16 << 20 -- 16 MiB should be enough for anyone.


function M.create_server(logfile, input, output)
   local server = {
      state = ServerState.START_LINE,
      log = io.open(logfile, "a"),
      input = input or io.input(),
      output = output or io.output(),
      max_chunk_size = M.default_max_chunk_size,
      -- handlers is a map of method => { location, location, ... }
      -- locations are matched in the order given, first match wins
      -- a location is an ordered list of { pattern, handler }
      -- pattern is a Lua pattern for string matching the path
      -- handler is a function(request) returning a response table
      handlers = {},
   }

   server.log:setvbuf("no")

   function server:add_route(method, pattern, handler)
      local handlers = self.handlers[method] or {}
      table.insert(handlers, { pattern, handler })
      self.handlers[method] = handlers
   end

   function server:run(verbose)
      self.verbose = verbose
      for line in self.input:lines() do
         if verbose then
            self.log:write(line, "\n")
         end
         self.state = handle_request_line(self, line)
      end
   end

   return server
end


M.parse_query_string = parse_request_query
M.percent_decode = decode
M.percent_encode = encode


-- Helper for chunk-encoded body transfers
function M.write_chunk(output, chunk, exts)
   if exts and #exts > 0 then
      exts = ";" .. table.concat(exts, ";")
   else
      exts = ""
   end
   output:write(("%x%s\r\n"):format(#chunk, exts))
   output:write(chunk)
   output:write("\r\n")
end


-- Helper for concluding chunk-encoded body transfers
function M.write_trailers(output, trailers)
   output:write("0\r\n")
   write_headers(output, trailers)
end


return M

-- vim: set et sw=3:
