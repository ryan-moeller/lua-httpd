--
-- Copyright (c) 2016-2025 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local M = {}

M.VERSION = "0.10.0"


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
   RESPONSE = 3,
   CLOSED = -1, -- except here; we're already closed
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
      server.log:warn("invalid start-line in request")
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


-- Helper for writing a list of fields.
-- This includes the terminator.
local function write_fields(output, fields, cookies)
   -- The order of field lines with different names is not significant
   -- (RFC 9110 §5.3), so iterating table keys is acceptable.
   for name, value in pairs(fields or {}) do
      if type(value) == "table" then
         -- Accept an ordered list of values for repeated fields.
         for _, v in ipairs(value) do
            output:write(name, ": ", v, "\r\n")
         end
      else
         output:write(name, ": ", value, "\r\n")
      end
   end
   -- Servers SHOULD NOT set the same cookie-name more than once in a response
   -- (RFC 6265 §4.1.1), and the order in which cookies with different names
   -- are set is not specified to be significant, so iterating table keys is
   -- acceptable.
   for name, value in pairs(cookies or {}) do
      output:write("Set-Cookie: ", name, "=", value, "\r\n")
   end
   output:write("\r\n")
end


local response_field_methods = {
   contains_value = function(field, search_value)
      for _, value in ipairs(field) do
         -- XXX: doesn't handle params. parse response fields?
         if value == search_value then
            return true
         end
      end
      return false
   end,
}


local response_field_metatable = {__index=response_field_methods}


-- Add some convenience metamethods to a collection of response fields.
local function wrap_response_fields(fields)
   -- Return a proxy that provides case-insensitive lookup and proxies fields.
   return setmetatable({}, {
      -- case-insensitive field-name lookup
      __index = function(_, key)
         local lkey = key:lower()
         for name, field in pairs(fields) do
            if name:lower() == lkey then
               -- Normalize singleton fields into lists.
               if type(field) ~= "table" then
                  field = {field}
                  fields[name] = field
               end
               -- Add some convenience methods to the field, and return its
               -- original name.
               return setmetatable(field, response_field_metatable), name
            end
         end
      end,

      -- case-insensitive field assignment
      __newindex = function(self, name, value)
         local _, real_name = self[name]
         fields[real_name or name] = value
      end,

      __pairs = function()
         return pairs(fields)
      end,
   })
end


-- expects a server table and a response table
-- example response table:
-- { status=404, reason="Not Found", headers={}, cookies={},
--   body="404 Not Found" }
local function write_http_response(server, response)
   local output = server.output

   local status = response.status
   local reason = response.reason
   local headers = response.headers
   local cookies = response.cookies
   local body = response.body

   -- MUST generate a Date header field in certain cases (RFC 9110 §6.6.1)
   -- Doesn't hurt to always send one.
   if not headers["Date"] then
      headers["Date"] = os.date("!%a, %d %b %Y %H:%M:%S GMT")
   end

   if not headers["Content-Length"] then
      if not body then
         headers["Content-Length"] = 0
      elseif type(body) == "string" then
         headers["Content-Length"] = #body
      elseif type(body) == "function" then
         -- Send "Connection: close" when trying to send a body with unknown
         -- length and not using chunked transfer encoding.  Take care not to
         -- interfere with connection upgrades.
         local xfer_enc = headers["Transfer-Encoding"]
         if not xfer_enc or not xfer_enc:contains_value("chunked") then
            local connection = headers["Connection"]
            if connection then
               if not connection:contains_value("Upgrade") and
                  not connection:contains_value("close") then
                  table.insert(connection, "close")
               end
            else
               headers["Connection"] = "close"
            end
         end
      end
   end

   local statusline = string.format("HTTP/1.1 %03d %s\r\n", status, reason)
   output:write(statusline)

   write_fields(output, headers, cookies)

   -- MUST NOT send content in the response to HEAD (RFC 9110 §9.3.2)
   -- Also described in RFC 9112 §6.3 (rule 1).
   if server.request.method == "HEAD" then
      return
   end
   -- Not Modified or No Content or Informational responses end after headers.
   -- RFC 9112 §6.3 (rule 1)
   if response.status == 304 or response.status == 204 or
      (response.status >= 100 and response.status <= 199) then
      -- But when Switching Protocols, a response.body function may be used to
      -- handle the new protocol.
      if response.status ~= 101 or type(body) ~= "function" then
         return
      end
   end
   if type(body) == "string" then
      output:write(body)
   elseif type(body) == "function" then
      output:flush()
      body(output)
   end
end


local function close_connection(server)
   if server.input == io.stdin or server.output == io.stdout then
      -- We can't close stdin or stdout, we have to exit.
      os.exit()
   end
   server.input:close()
   if server.output ~= server.input then
      server.output:close()
   end
end


local function respond(server, response)
   local request = server.request

   server.log:info(request.method, " ", request.path, " ", response.status, " ",
      response.reason)
   response.headers = wrap_response_fields(response.headers or {})
   write_http_response(server, response)

   -- HTTP/1.1 connections are keep-alive by default.
   local req_connection = request.headers["connection"]
   local req_close = req_connection and req_connection:contains_value("close")
   local res_connection = response.headers["Connection"]
   local res_close = res_connection and res_connection:contains_value("close")
   if req_close or res_close then
      close_connection(server)
      -- TODO: Accommodate a persistent server with an accept loop.  For now, we
      -- must trash the server after closing the connection.
      if server.log ~= io.stderr then
         server.log:close()
      end
      return ServerState.CLOSED
   else
      server.output:flush()
   end
   return ServerState.START_LINE
end


-- Log some debugging info.
local function debug_server(server)
   local log = server.log
   local request = server.request
   local handlers = server.handlers[request.method]

   log:debug("method = ", request.method)
   log:debug("#handlers = ", tostring(#handlers))
   if request.path ~= nil then
      log:debug("path = ", request.path)
   end
   for k, v in pairs(request.params) do
      local values = type(v) == "table" and v or {v}
      log:debug(">P ", k, " = ", table.concat(v, ", "))
   end
   for k, v in pairs(request.headers) do
      log:debug(">H ", k, " -> ", table.concat(v.unvalidated, ", "))
   end
end


local function handle_request(server)
   local request = server.request
   local handlers = server.handlers[request.method]

   if server.log.level >= M.DEBUG then
      debug_server(server)
   end

   -- Check if we implement this method.
   if not handlers then
      return respond(server, {
         status=501, reason="Not Implemented", body="not implemented",
      })
   end

   -- Try to find a location matching the request.
   for _, location in ipairs(handlers) do
      local pattern, handler = table.unpack(location)
      local matches = { string.match(request.path, pattern) }
      if #matches > 0 then
         request.matches = matches
         server.state = ServerState.RESPONSE
         local response = handler(request)
         if server.state ~= ServerState.RESPONSE then
            -- An error occurred in the handler.
            return server.state
         end
         return respond(server, response)
      end
   end
   return respond(server, {status=404, reason="Not Found", body="not found"})
end


-- Field format:
--
-- {
--    unvalidated = { "t;n=v;a (comment) (and (a nested comment) too)", ... },
--    raw = { "t;n=v;a (comment) (and (a nested comment) too)", ... },
--    elements = {
--       {
--          value = "t", -- token or quoted-string
--          params = {
--             { name = "n", value = "v" }, -- names may be repeated
--             { attribute = "a" }, -- attributes may also be repeated
--             ...
--          },
--          comments = {
--             "comment",
--             { "and", { "a nested comment" }, "too" },
--             ...
--          }
--       },
--       ...
--    }
-- }
--
-- The `raw` and `elements` members of a field invoke the parser on first access
-- and cache the result.
--
-- The `value`, `params`, and `comments` attributes of an element are optional.
--
-- The fields of a parameter are either `name` and `value` or `attribute`.
--
-- Unvalidated fields:
-- `unvalidated`: list of unvalidated field values verbatim, in order received
--
-- Validated fields:
-- `raw`: list of unparsed, validated field values verbatim, in order received
-- `elements`: reflects the parsed, structured forms described in RFC 9110 §5.6,
--             listed in order of reception


-- Field value lexer FSM states
local FieldValueLexerState = {
   -- REMEMBER: these must be contiguous values in order starting from 0
   OWS = 0,
   TOKEN = 1,
   LIST_DELIMITER = 2,
   QUOTED_STRING_BEGIN = 3,
   QUOTED_STRING = 4,
   QUOTED_STRING_END = 5,
   ESCAPE = 6,
   COMMENT_OPEN = 7,
   COMMENT = 8,
   COMMENT_CLOSE = 9,
   PARAMETER = 10,
   PARAMETER_NAME = 11,
   PARAMETER_VALUE = 12,
   CONTENT = 13,
   ERROR = 14, -- keep ERROR at the end
}


-- Which states are in the set of accept states for structured data?
local FieldValueLexerAccept = {
   -- REMEMBER: these must be contiguous keys in order starting from 1 (thus +1)
   [FieldValueLexerState.OWS + 1] = true,
   [FieldValueLexerState.TOKEN + 1] = true,
   [FieldValueLexerState.LIST_DELIMITER + 1] = true,
   [FieldValueLexerState.QUOTED_STRING_BEGIN + 1] = false,
   [FieldValueLexerState.QUOTED_STRING + 1] = false,
   [FieldValueLexerState.QUOTED_STRING_END + 1] = true,
   [FieldValueLexerState.ESCAPE + 1] = false,
   [FieldValueLexerState.COMMENT_OPEN + 1] = false,
   [FieldValueLexerState.COMMENT + 1] = false,
   [FieldValueLexerState.COMMENT_CLOSE + 1] = true,
   [FieldValueLexerState.PARAMETER + 1] = true, -- optional in parameters
   [FieldValueLexerState.PARAMETER_NAME + 1] = true,
   [FieldValueLexerState.PARAMETER_VALUE + 1] = false, -- "=" must be followed
   [FieldValueLexerState.CONTENT + 1] = false, -- not structured
   -- We can omit ERROR, as transitioning into ERROR halts the FSM.
}
-- Sanity check the array layout.
assert(#FieldValueLexerAccept == FieldValueLexerState.ERROR)


-- The lexer FSM initialization is deferred until we parse a field.
local FieldValueLexerFSM = nil


-- Compile the production rules for the FSM into a VM-optimimized table.
local function build_lexer_fsm()
   -- A single array-backed table should be the fastest representation in Lua.
   -- It has better space efficiency and cache locality than nested tables, and
   -- it uses only VM operations for lookup (as opposed to string.byte, which is
   -- a call out of the VM into C).  The table is on the order of 8x less space
   -- efficient than using a byte string, but it's still relatively small.
   local fsm = {}

   -- States are numbered starting from 0 and occupy the higher-order bits of
   -- the index.  The input byte occupies the low byte of the index.  Note that
   -- the +1 offset is required for Lua's array-backed tables, which expect
   -- indices to start at 1 for optimal performance.
   --
   -- As a micro-optimization, the table indexing math is inlined everywhere:
   -- local function index(state, byte) return ((state << 8) | byte) + 1 end
   --
   -- We populate the table for every possible state and input byte to ensure
   -- array optimizations are possible.  Sparse keys would require use of the
   -- hash table internal format.  We want the flat array format.  The shift
   -- gives us space for 256 * the number of states, i.e. Nstates * Nbytes.
   --
   -- There isn't a convenient way to get the number of entries in a hash table,
   -- so we use the size of the FieldValueLexerAccept array instead.  The FSM
   -- and Accept tables exclude the ERROR state to avoid wasting time and space.
   for i = 1, (#FieldValueLexerAccept) << 8 do
      -- Anything not caught by the rules below is invalid.
      fsm[i] = FieldValueLexerState.ERROR
   end

   -- The setters table provides the different methods for interpreting the
   -- various key types used by rules.
   --
   -- setters[type(key)] => function(state, key, value)
   local setters = {}

   -- Expand a production rule into FSM transition rules.
   local function expand(state, rule)
      local key = rule[1]
      local value = rule[2]
      setters[type(key)](state, key, value)
   end

   -- Number keys are used directly.
   function setters.number(state, key, value)
      fsm[((state << 8) | key) + 1] = value
   end

   -- String keys are iterated as a sequence of bytes.
   function setters.string(state, key, value)
      for i = 1, #key do
         fsm[((state << 8 ) | key:byte(i)) + 1] = value
      end
   end

   -- Table keys can be either a range or an array of keys.
   function setters.table(state, key, value)
      if key.start then
         -- Range form
         for byte = key.start, key.stop do
            fsm[((state << 8) | byte) + 1] = value
         end
      else
         -- Array form
         for _, key1 in ipairs(key) do
            expand(state, {key1, value})
         end
      end
   end

   -- Some common ABNF rules
   local function range(start, stop) return {start=start, stop=stop} end
   local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
   local DIGIT = "0123456789"
   local DQUOTE = 0x22 -- " (double quote)
   local VCHAR = range(0x21, 0x7e)
   -- Other handy keys
   local WSP = " \t"
   local obs_text = range(0x80, 0xff)
   local field_vchar = { VCHAR, obs_text }
   local tchar = table.concat({"!#$%&'*+-.^_`|~", ALPHA, DIGIT})
   local comma = 0x2c -- , (comma)
   local lparen = 0x28 -- ( (left parenthesis)
   local rparen = 0x29 -- ) (right parenthesis)
   local semicolon = 0x3b -- ; (semicolon)
   local equals = 0x3d -- = (equal sign)
   local backslash = 0x5c -- \ (backslash)

   -- Add a list of rules to the FSM.
   local function state_rules(state, rules)
      -- §5.5 Field Values
      expand(state, {{WSP, field_vchar}, FieldValueLexerState.CONTENT})
      -- §5.6 Common Rules for Defining Field Values (optimistic)
      for _, rule in ipairs(rules) do
         expand(state, rule)
      end
   end

   -- Build the lookup table for the field value lexer FSM.
   --
   -- We declare the table in a more human-friendly form which is expanded to a
   -- machine-optimized form at runtime.  The human-friendly version uses rules
   -- specified as lists of `{key, value}` pairs for each state:
   --
   --  * A number key gives the production rule for a single byte of input.
   --
   --  * A string key gives a collection of bytes producing the same state.
   --
   --  * A table key in {start=byte, stop=byte} form gives a range of bytes
   --    producing the same state.
   --
   --  * A table key in array form lists keys producing the same state.
   --
   --  * The value specifies the state to produce for input matching the key.
   --
   -- Input not matching the key for any rule produces the ERROR state.
   -- Overlapping key specifications overwrite the transition table in the
   -- order given.
   --
   -- Every state has an implicit rule for field-content -> CONTENT and need
   -- only add more specific rules.
   --
   -- References: RFC 9110 §5.5, §5.6
   local element_rules = {
      -- §5.6.1 Lists, §5.6.6 Parameters
      {WSP, FieldValueLexerState.OWS},
      -- §5.6.1 Lists
      {comma, FieldValueLexerState.LIST_DELIMITER},
      -- §5.6.2 Tokens
      {tchar, FieldValueLexerState.TOKEN},
      -- §5.6.4 Quoted Strings
      {DQUOTE, FieldValueLexerState.QUOTED_STRING_BEGIN},
      -- §5.6.5 Comments
      {lparen, FieldValueLexerState.COMMENT_OPEN},
      -- §5.6.6 Parameters
      {semicolon, FieldValueLexerState.PARAMETER},
   }
   local string_rules = {
      -- §5.6.4 Quoted Strings
      -- Note: Exceptions from this range are made by the later rules.
      {{WSP, VCHAR, obs_text}, FieldValueLexerState.QUOTED_STRING},
      {DQUOTE, FieldValueLexerState.QUOTED_STRING_END},
      {backslash, FieldValueLexerState.ESCAPE},
   }
   local comment_rules = {
      -- §5.6.5 Comments
      -- Note: Exceptions from this range are made by the later rules.
      {{WSP, VCHAR, obs_text}, FieldValueLexerState.COMMENT},
      {lparen, FieldValueLexerState.COMMENT_OPEN},
      {rparen, FieldValueLexerState.COMMENT_CLOSE},
      {backslash, FieldValueLexerState.ESCAPE},
   }
   state_rules(FieldValueLexerState.OWS, element_rules)
   state_rules(FieldValueLexerState.TOKEN, {
      -- §5.6.1 Lists, §5.6.6 Parameters
      {WSP, FieldValueLexerState.OWS},
      -- §5.6.1 Lists
      {comma, FieldValueLexerState.LIST_DELIMITER},
      -- §5.6.2 Tokens
      {tchar, FieldValueLexerState.TOKEN},
      -- §5.6.5 Comments
      {lparen, FieldValueLexerState.COMMENT_OPEN},
      -- §5.6.6 Parameters
      {semicolon, FieldValueLexerState.PARAMETER},
   })
   state_rules(FieldValueLexerState.LIST_DELIMITER, element_rules)
   state_rules(FieldValueLexerState.QUOTED_STRING_BEGIN, string_rules)
   state_rules(FieldValueLexerState.QUOTED_STRING, string_rules)
   state_rules(FieldValueLexerState.QUOTED_STRING_END, {
      -- §5.6.1 Lists, §5.6.6 Parameters
      {WSP, FieldValueLexerState.OWS},
      -- §5.6.1 Lists
      {comma, FieldValueLexerState.LIST_DELIMITER},
      -- §5.6.5 Comments
      {lparen, FieldValueLexerState.COMMENT_OPEN},
      -- §5.6.6 Parameters
      {semicolon, FieldValueLexerState.PARAMETER},
   })
   state_rules(FieldValueLexerState.ESCAPE, {
      -- §5.6.4 Quoted Strings, §5.6.5 Comments
      -- Note: The parser is responsible for interpreting ESCAPE->ESCAPE as a
      -- return to either QUOTED_STRING or COMMENT.
      {{WSP, VCHAR, obs_text}, FieldValueLexerState.ESCAPE},
   })
   state_rules(FieldValueLexerState.COMMENT_OPEN, comment_rules)
   state_rules(FieldValueLexerState.COMMENT, comment_rules)
   -- Note: The grammar defines comments recursively, allowing arbitrary
   -- nesting via balanced pairs of parentheses.  It is the parser's
   -- responsibility to track the nesting depth and avoid treating the
   -- comment as closed until the final ")" is encountered.  If the comment
   -- is still open after a transition to COMMENT_CLOSE, then the parser
   -- must advance the FSM to the COMMENT state instead of COMMENT_CLOSE.
   --
   -- The following rules encode the transitions when the comment IS closed.
   state_rules(FieldValueLexerState.COMMENT_CLOSE, element_rules)
   state_rules(FieldValueLexerState.PARAMETER, {
      -- §5.6.6 Parameters
      {{WSP, semicolon}, FieldValueLexerState.PARAMETER},
      {tchar, FieldValueLexerState.PARAMETER_NAME},
   })
   state_rules(FieldValueLexerState.PARAMETER_NAME, {
      -- §5.6.1 Lists, §5.6.6 Parameters
      {WSP, FieldValueLexerState.OWS},
      -- §5.6.1 Lists
      {comma, FieldValueLexerState.LIST_DELIMITER},
      -- §5.6.2 Tokens, §5.6.6 Parameters
      {semicolon, FieldValueLexerState.PARAMETER},
      {tchar, FieldValueLexerState.PARAMETER_NAME},
      {equals, FieldValueLexerState.PARAMETER_VALUE},
   })
   state_rules(FieldValueLexerState.PARAMETER_VALUE, {
      -- §5.6.6 Parameters
      -- §5.6.2 Tokens
      {tchar, FieldValueLexerState.TOKEN},
      -- §5.6.4 Quoted Strings
      {DQUOTE, FieldValueLexerState.QUOTED_STRING_BEGIN},
   })
   state_rules(FieldValueLexerState.CONTENT, {
      -- §5.5 Field Values
      -- The content rules are implicit.  We just need to call state_rules with
      -- an empty table to fill in the default rules.
   })
   -- The ERROR state immediately terminates the FSM, there is no way out.

   -- TODO: This table stores a number for each entry, but it uses only 4 bits.
   -- For embedded systems such as an ESP8266, that's the difference between
   -- using all of the available memory and using only a fraction of it.
   --
   -- We could compress the table by packing the integers - keeping the table
   -- small and fast but at the expense of some extra bit math.
   return fsm
end


-- The field value parser encodes its behavior in a LUT.  The index into the LUT
-- is constructed from the lexer state transition (s, n), where s is the current
-- state of the lexer and n is the next state of the lexer.  Concretely, the
-- index is `((s << 4) | n) + 1`.  There are ten lexer states, so we need four
-- lower bits and four higher bits.  The +1 offset is required for Lua's
-- array-backed tables, which expect indices to start at 1 for optimal
-- performance.
--
-- The parser LUT stores an opcode for each state transition.  The opcode is a
-- bitfield encoding the operations to be performed on the parser state.  Each
-- FieldValueParserOp represents a bit in the opcode and a corresponding
-- function in the FieldValueParserOpCode table.  The op is used as a shift
-- amount in the opcode bitfield and as an index in the FieldValueParserOpCode
-- table.  The FieldValueParserOpCode table is again constrained to 1-based
-- indexing by Lua's array-backed table, so the least-significant bit of
-- the opcode (corresponding to the unused shift amount 0) is available for
-- future use.
local FieldValueParserOp = {
   -- REMEMBER: these must be contiguous values in order starting from 1
   ESCAPE = 1,
   MARK = 2,
   COMMENT = 3,
   START_ITEM = 4,
   PUSH_TOKEN = 5,
   PUSH_QUOTED = 6,
   PUSH_COMMENT = 7,
   SET_PARAM = 8,
   END_ITEM = 9,
   RETURN = 10,
   --TRACE = 11,
}


-- Implement the set of parser operations.  Each operation performs a mutation
-- on a parser object.  Multiple operations can be combined to form an opcode.
-- This table contains the code for the operations, not opcodes.
local FieldValueParserOpCode = {
   -- REMEMBER: these must contiguous values in order starting from 1
   [FieldValueParserOp.ESCAPE] = function(parser)
      local chunk = parser.value:sub(parser.mark, parser.pos - 1)
      table.insert(parser.stack, chunk)
   end,
   [FieldValueParserOp.MARK] = function(parser)
      parser.mark = parser.pos
   end,
   [FieldValueParserOp.COMMENT] = function(parser)
      -- TODO: save the comment structure?
      parser.comment_depth = parser.comment_depth + 1
   end,
   [FieldValueParserOp.START_ITEM] = function(parser)
      parser.current_element = parser.current_element or {}
   end,
   [FieldValueParserOp.PUSH_TOKEN] = function(parser)
      local value = parser.value:sub(parser.mark, parser.pos - 1)

      local element = parser.current_element
      assert(element, "PUSH_TOKEN: no current element")

      local name = parser.param_name

      if parser.lexer_state == FieldValueLexerState.PARAMETER_NAME then
         element.params = element.params or {}
         parser.param_name = value
      elseif name then
         table.insert(element.params, {name=name, value=value})
         parser.param_name = nil
      elseif element.value == nil then
         element.value = value
      else
         -- If a value was already set then this is not a valid structure.
         -- Discard any staged elements and validate the rest as raw content.
         parser.staged_elements = {}
         parser.next_lexer_state = FieldValueLexerState.CONTENT
      end
   end,
   [FieldValueParserOp.PUSH_QUOTED] = function(parser)
      local chunk = parser.value:sub(parser.mark, parser.pos - 1)
      table.insert(parser.stack, chunk)

      local value = table.concat(parser.stack)
      parser.stack = {}

      local element = parser.current_element
      assert(element, "PUSH_QUOTED: no current element")

      local name = parser.param_name

      if name then
         table.insert(element.params, {name=name, value=value})
         parser.param_name = nil
      elseif element.value == nil then
         element.value = value
      else
         -- If a value was already set then this is not a valid structure.
         -- Discard any staged elements and validate the rest as raw content.
         parser.staged_elements = {}
         parser.next_lexer_state = FieldValueLexerState.CONTENT
      end
   end,
   [FieldValueParserOp.PUSH_COMMENT] = function(parser)
      local depth = parser.comment_depth - 1
      assert(depth >= 0)
      if depth > 0 then
         parser.next_lexer_state = FieldValueLexerState.COMMENT
         -- TODO: save the comment structure?
      end
      parser.comment_depth = depth
      -- Clear any escape chunks for now.  Revise when comments are saved.
      parser.stack = {}
   end,
   [FieldValueParserOp.SET_PARAM] = function(parser)
      assert(parser.param_name, "SET_PARAM: no param name")
      table.insert(parser.current_element.params, {attribute=parser.param_name})
      parser.param_name = nil
   end,
   [FieldValueParserOp.END_ITEM] = function(parser)
      local element = parser.current_element
      assert(element, "END_ITEM: no current element")
      table.insert(parser.staged_elements, element)
      parser.current_element = nil
   end,
   [FieldValueParserOp.RETURN] = function(parser)
      local prev_lexer_state = parser.prev_lexer_state
      if prev_lexer_state == FieldValueLexerState.QUOTED_STRING_BEGIN then
         parser.next_lexer_state = FieldValueLexerState.QUOTED_STRING
      elseif prev_lexer_state == FieldValueLexerState.COMMENT_OPEN then
         parser.next_lexer_state = FieldValueLexerState.COMMENT
      else
         parser.next_lexer_state = prev_lexer_state
      end
   end,
   --[[ DEBUG
   [FieldValueParserOp.TRACE] = function(parser)
      io.stderr:write(("trace on opcode=%#x byte=%#x\n")
         :format(parser.opcode, parser.byte))
   end,
   ]]--
}


-- Initialization of the parser LUTs is deferred until we parse a field.
local FieldValueParserLUT, FieldValueParserFinalLUT = nil, nil


-- Compile the parser operations performed on lexer state transitions into
-- a VM-optimized table of opcodes.
local function build_parser_luts()
   local lut = {}
   local final = {}

   local S = FieldValueLexerState
   local O = FieldValueParserOp

   -- The parser LUT index is two 4-bit fields, so 8 bits total = 256 entries.
   for i = 1, 256 do
      lut[i] = 0 -- NOP
   end

   -- There is no direct way to get the number of states, but it is the size of
   -- the lexer FSM / 256, i.e. eliminating the input byte portion of the index.
   -- Note the parentheses to avoid being parsed as #(FieldValueLexerFSM >> 8).
   for i = 1, (#FieldValueLexerFSM) >> 8 do
      final[i] = 0 -- NOP
   end

   local function opcode(...)
      local code = 0
      for _, op in ipairs{...} do
         code = code | (1 << op)
      end
      --return (1 << O.TRACE) | code
      return code
   end

   local function encode_lut(s, n, ...)
      lut[((s << 4) | n) + 1] = opcode(...)
   end

   local function encode_final(s, ...)
      final[s + 1] = opcode(...)
   end

   -- Encode the parser LUT.
   encode_lut(S.OWS, S.LIST_DELIMITER,      O.END_ITEM)
   encode_lut(S.OWS, S.TOKEN,               O.MARK, O.START_ITEM)
   encode_lut(S.OWS, S.QUOTED_STRING_BEGIN, O.START_ITEM)
   encode_lut(S.OWS, S.COMMENT_OPEN,        O.COMMENT, O.START_ITEM)
   encode_lut(S.OWS, S.PARAMETER,           O.START_ITEM)

   encode_lut(S.TOKEN, S.OWS,            O.PUSH_TOKEN)
   encode_lut(S.TOKEN, S.LIST_DELIMITER, O.PUSH_TOKEN, O.END_ITEM)
   encode_lut(S.TOKEN, S.COMMENT_OPEN,   O.COMMENT, O.PUSH_TOKEN)
   encode_lut(S.TOKEN, S.PARAMETER,      O.PUSH_TOKEN)

   encode_lut(S.LIST_DELIMITER, S.TOKEN,               O.MARK, O.START_ITEM)
   encode_lut(S.LIST_DELIMITER, S.QUOTED_STRING_BEGIN, O.START_ITEM)
   encode_lut(S.LIST_DELIMITER, S.COMMENT_OPEN,        O.COMMENT, O.START_ITEM)
   encode_lut(S.LIST_DELIMITER, S.PARAMETER,           O.START_ITEM)

   encode_lut(S.QUOTED_STRING_BEGIN, S.QUOTED_STRING,     O.MARK)
   encode_lut(S.QUOTED_STRING_BEGIN, S.QUOTED_STRING_END, O.MARK, O.PUSH_QUOTED)
   -- QUOTED_STRING_BEGIN->ESCAPE: NOP ; the string will begin after the escape

   encode_lut(S.QUOTED_STRING, S.QUOTED_STRING_END, O.PUSH_QUOTED)
   encode_lut(S.QUOTED_STRING, S.ESCAPE,            O.ESCAPE)

   encode_lut(S.QUOTED_STRING_END, S.LIST_DELIMITER, O.END_ITEM)
   encode_lut(S.QUOTED_STRING_END, S.COMMENT_OPEN,   O.COMMENT)
   -- QUOTED_STRING_END->PARAMETER: NOP ; parameter applies to current_element

   encode_lut(S.ESCAPE, S.ESCAPE, O.MARK, O.RETURN) -- O.RETURN sets next state

   encode_lut(S.COMMENT_OPEN, S.COMMENT,       O.MARK)
   encode_lut(S.COMMENT_OPEN, S.COMMENT_OPEN,  O.COMMENT)
   encode_lut(S.COMMENT_OPEN, S.COMMENT_CLOSE, O.MARK, O.PUSH_COMMENT) -- empty
   -- COMMENT_OPEN->ESCAPE: NOP ; the comment will begin after the escape

   encode_lut(S.COMMENT, S.COMMENT_OPEN,  O.COMMENT)
   encode_lut(S.COMMENT, S.COMMENT_CLOSE, O.PUSH_COMMENT)
   encode_lut(S.COMMENT, S.ESCAPE,        O.ESCAPE)

   encode_lut(S.COMMENT_CLOSE, S.LIST_DELIMITER,      O.END_ITEM)
   encode_lut(S.COMMENT_CLOSE, S.TOKEN,               O.MARK)
   -- COMMENT_CLOSE->QUOTED_STRING_BEGIN: NOP ; string applies to current_item
   encode_lut(S.COMMENT_CLOSE, S.COMMENT_OPEN,        O.COMMENT)
   -- COMMENT_CLOSE->PARAMETER: NOP ; parameter applies to current_element

   encode_lut(S.PARAMETER, S.PARAMETER_NAME, O.MARK)

   encode_lut(S.PARAMETER_NAME, S.OWS,             O.PUSH_TOKEN, O.SET_PARAM)
   encode_lut(S.PARAMETER_NAME, S.LIST_DELIMITER,  O.PUSH_TOKEN, O.SET_PARAM,
                                                   O.END_ITEM)
   encode_lut(S.PARAMETER_NAME, S.PARAMETER,       O.PUSH_TOKEN, O.SET_PARAM)
   encode_lut(S.PARAMETER_NAME, S.PARAMETER_VALUE, O.PUSH_TOKEN)

   encode_lut(S.PARAMETER_VALUE, S.TOKEN,               O.MARK)
   -- PARAMETER_VALUE->QUOTED_STRING_BEGIN: NOP ; just eat the "="

   -- Encode a LUT for the final step of the parser separately to avoid
   -- conditional behavior in the ops.
   encode_final(S.TOKEN,             O.PUSH_TOKEN, O.END_ITEM)
   -- LIST_DELIMITER: NOP ; don't include the empty item
   encode_final(S.QUOTED_STRING_END, O.END_ITEM)
   encode_final(S.COMMENT_CLOSE,     O.END_ITEM)
   encode_final(S.PARAMETER,         O.END_ITEM)
   encode_final(S.PARAMETER_NAME,    O.PUSH_TOKEN, O.SET_PARAM, O.END_ITEM)

   return lut, final
end


local function execute_parser_opcode(parser, opcode)
   if opcode == 0 then
      return -- NOP
   end
   --parser.opcode = opcode -- DEBUG
   for op = 1, #FieldValueParserOpCode do
      if (opcode & (1 << op)) ~= 0 then
         FieldValueParserOpCode[op](parser)
      end
   end
end


-- Abuse mitigations
--
-- These limits are lenient by a huge margin but help the parser ignore
-- pathological input.  If you're expecting huge quoted strings with an
-- absurd number of escapes in your fields and run into this limit, it
-- can be raised on the module table before running the server.
M.field_value_parser_stack_size_limit = 1000
M.field_value_parser_comment_depth_limit = 100


local function parse_field_value_impl(field, value)
   local stack = {}
   local stack_size_limit = M.field_value_parser_stack_size_limit
   local comment_depth_limit = M.field_value_parser_comment_depth_limit
   local parser = {
      value = value,
      next_lexer_state = FieldValueLexerState.OWS,
      pos = 1,
      stack = stack,
      comment_depth = 0,
      staged_elements = {},
   }

   while parser.pos <= #value do
      local byte = value:byte(parser.pos)
      local lexer_state = parser.next_lexer_state
      local lexer_index = ((lexer_state << 8) | byte) + 1
      local next_lexer_state = assert(FieldValueLexerFSM[lexer_index])

      if next_lexer_state == FieldValueLexerState.ERROR or
         -- Ignore pathological input.
         #stack > stack_size_limit or
         parser.comment_depth > comment_depth_limit then
         -- Abort! This message is bunk!
         return
      end

      local parser_index = ((lexer_state << 4) | next_lexer_state) + 1
      local opcode = assert(FieldValueParserLUT[parser_index])

      parser.byte = byte
      parser.prev_lexer_state = parser.lexer_state
      parser.lexer_state = lexer_state
      parser.next_lexer_state = next_lexer_state
      execute_parser_opcode(parser, opcode)
      parser.pos = parser.pos + 1
   end

   -- Finalize any pending structures.
   local lexer_state = parser.next_lexer_state
   local opcode = assert(FieldValueParserFinalLUT[lexer_state + 1])

   parser.byte = 0
   parser.prev_lexer_state = parser.lexer_state
   parser.lexer_state = lexer_state
   parser.next_lexer_state = nil
   execute_parser_opcode(parser, opcode)

   -- Update the field.
   if FieldValueLexerAccept[lexer_state + 1] then
      for _, element in ipairs(parser.staged_elements) do
         table.insert(field.elements, element)
      end
   end
   table.insert(field.raw, value)
end


local function parse_field_value(field, value)
   -- Lazy lexer/parser construction
   --
   -- Some requests may not require field inspection at all.  We don't need the
   -- lexer/parser machinery unless we end up here.
   FieldValueLexerFSM = build_lexer_fsm()
   FieldValueParserLUT, FieldValueParserFinalLUT = build_parser_luts()
   -- This little trick avoids adding a branch to check for initialization every
   -- time we parse a field.
   parse_field_value = parse_field_value_impl
   parse_field_value(field, value)
end


local field_methods = {
   concat = function(field, ...)
      return table.concat(field.raw, ...)
   end,

   contains_value = function(field, value)
      for _, element in ipairs(field.elements) do
         if element.value == value then
            return true
         end
      end
      return false
   end,

   find_elements = function(field, value)
      local matches = {}
      for _, element in ipairs(field.elements) do
         if element.value == value then
            table.insert(matches, element)
         end
      end
      return matches
   end,

   -- TODO: add some more convenience methods
}


local field_metatable = {
   __index = function(field, key)
      if key ~= "raw" and key ~= "elements" then
         return field_methods[key]
      end
      field.raw = {} -- list of all raw (but validated) field values
      field.elements = {} -- list of structured elements
      for _, value in ipairs(field.unvalidated) do
         parse_field_value(field, value)
      end
      return field[key]
   end,
}


local function new_field()
   return setmetatable({unvalidated={}}, field_metatable)
end


--[[ TESTS
log = io.stderr
local values = {
   "token",
   "token1, token2",
   "token; param=value",
   ";attribute;param=value",
   '"quoted string"',
   '"\\""',
   '"\\"quotes in a quoted string\\""',
   "token (comment)",
   "(comment \\( with escape)",
   "x,,",
   "x;y;;z;",
   "x,(y);",
   "Sun, 06 Nov 1994 08:49:37 GMT",
}
local ucl = require("ucl")
for _, value in ipairs(values) do
   print("field value: ", value)
   local field = new_field()
   table.insert(field.unvalidated, value)
   -- Note if tracing is added to parse_field_value() that it is invoked once
   -- for `raw` but not again for `elements`, because the result is memoized.
   print("raw: ", ucl.to_json(field.raw))
   print("elements: ", ucl.to_json(field.elements))
end
--]]--


local function update_fields(fields, name, value)
   -- Field parsing is deferred until either field.raw or field.elements is
   -- accessed (potentially by a convenience method).
   --
   -- Just accumulate unvalidated input values in a list for now.
   --
   -- TODO: Validation/parsing for all fields could be forced by a server
   -- configuration parameter.
   local field = fields[name] or new_field()
   table.insert(field.unvalidated, value)
   fields[name] = field
end


local function parse_field(line)
   return line:match("^(%g+):[ \t]*(.-)[ \t]*\r$")
end


local function handle_trailer_field(server, line)
   if line == "\r" then
      -- When there are no trailers left we get just a blank line.
      -- That marks the end of this request.
      return ServerState.RESPONSE
   else
      local name, value = parse_field(line)

      if name then
         -- Field names are case-insensitive.
         local lname = string.lower(name)
         -- Cookies received in trailers are intentionally ignored.
         -- We'll just throw them in with the trailers instead.
         update_fields(server.request.trailers, name, value)
      else
         server.log:warn("ignoring invalid trailer: ", line)
      end

      -- Look for more trailers.
      return ServerState.TRAILER_FIELD
   end
end


local function handle_chunked_message_body(server)
   server.log:debug("body is chunked")
   -- For a chunked transfer, the body field of the request object will be a
   -- function returning an iterator over the chunks, used like:
   -- for chunk, exts_dict, exts_str in request.body() do
   --     -- do things
   -- end
   -- This enables streaming content without having to fully buffer it.
   server.request.body = function()
      return function()
         -- REMEMBER: Do not return a state on error; this is an iterator.
         local chunk_size_line = server.input:read("*l")
         if not chunk_size_line then
            server.log:error("unexpected EOF")
            server.state = respond(server, {
               status=400, reason="Bad Request", body="unexpected EOF",
               headers={["Connection"]="close"},
            })
            return
         end
         local chunk_size_hex, exts_str = chunk_size_line:match("^(%x+)(.*)\r$")
         if not chunk_size_hex then
            server.log:error("invalid chunk size")
            server.state = respond(server, {
               status=400, reason="Bad Request", body="invalid chunk size",
               headers={["Connection"]="close"},
            })
            return
         end
         local chunk_size = tonumber(chunk_size_hex, 16)
         if not chunk_size or chunk_size > server.max_chunk_size then
            server.log:error("invalid chunk size")
            server.state = respond(server, {
               status=400, reason="Bad Request", body="invalid chunk size",
               headers={["Connection"]="close"},
            })
            return
         end
         server.log:debug("chunk size = ", chunk_size)
         server.log:debug("chunk extensions = ", exts_str)
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
            local buf, err = server.input:read(chunk_size - #chunk)
            if not buf or #buf == 0 then
               server.log:error("reading body chunk failed: ", err or "EOF")
               server.state = respond(server, {
                  status=400, reason="Bad Request", body="reading body failed",
                  headers={["Connection"]="close"},
               })
               return
            end
            chunk = chunk .. buf
            assert(#chunk <= chunk_size)
         until #chunk == chunk_size
         local crlf = server.input:read(2)
         if crlf ~= "\r\n" then
            server.log:error("invalid chunk-data terminator")
            server.state = respond(server, {
               status=400, reason="Bad Request", body="invalid chunk-data",
               headers={["Connection"]="close"},
            })
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
         if server.log.level >= M.TRACE then
            for line in chunk:gmatch("[^\r\n]+") do
               server.log:trace(">B ", line)
            end
         end
         return chunk, exts_dict, exts_str
      end
   end
end


local function handle_message_body(server, content_length)
   local body = ""
   while #body < content_length do
      local buf = server.input:read(content_length - #body)
      if not buf or #buf == 0 then
         -- MUST respond 400 and close (RFC 9112 §6.3)
         server.log:error("body shorter than specified content length")
         return respond(server, {
            status=400, reason="Bad Request", body="body truncated",
            headers={["Connection"]="close"},
         })
      end
      body = body .. buf
   end

   server.log:debug("content length = ", content_length)
   if server.log.level >= M.TRACE then
      for line in body:gmatch("[^\r\n]+") do
         server.log:trace(">B ", line)
      end
   end
   server.request.body = body
end


local function handle_blank_line(server)
   local request = server.request
   local transfer_encoding_header = request.headers["transfer-encoding"]
   local content_length_header = request.headers["content-length"]

   -- Transfer-Encoding overrides Content-Length (RFC 9112 §6.3)
   if transfer_encoding_header then
      local codings = transfer_encoding_header.elements
      local final_transfer_coding = codings[#codings]

      -- Sender MUST apply chunked as the final transfer coding (RFC 9112 §6.1)
      if final_transfer_coding and final_transfer_coding.value == "chunked" then
         -- Decode the chunked framing.  Further decoding is up to the handler.
         handle_chunked_message_body(server)
      else
         server.log:error("invalid transfer-encoding")
         return respond(server, {
            status=400, reason="Bad Request", body="invalid transfer-encoding",
            headers={["Connection"]="close"},
         })
      end
   elseif content_length_header then
      -- Be lenient and only use the last received content-length header value.
      local elements = content_length_header.elements
      local content_length = tonumber(elements[#elements].value)
      if content_length then
         local err = handle_message_body(server, content_length)
         if err then
            return err
         end
      else
         server.log:error("invalid content-length")
         return respond(server, {
            status=400, reason="Bad Request", body="invalid content-length",
            headers={["Connection"]="close"},
         })
      end
   end
   return handle_request(server)
end


-- cookie-string = cookie-pair *( ";" SP cookie-pair )
-- cookie-pair   = cookie-name "=" cookie-value
-- cookie-name   = token
-- cookie-value  = *cookie-octet / ( DQUOTE *cookie-octet DQUOTE )
-- cookie-octet  = %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E
-- token         = 1*<any CHAR except CTLs or separators>
-- separators    = "(" | ")" | "<" | ">" | "@"
--               | "," | ";" | ":" | "\" | <">
--               | "/" | "[" | "]" | "?" | "="
--               | "{" | "}" | SP | HT
-- CHAR          = <any US-ASCII character (octets 0 - 127)>
-- CTL           = <any US-ASCII control character
--                 (octets 0 - 31) and DEL (127)>
--
-- References: RFC 6265 §4.1.1 & §4.2.1, RFC 2616 §2.2
local function set_cookies(server, cookie)
   -- Browsers do not send cookie attributes in requests.
   local pattern = table.concat({
      "^",                                                  -- no skipping ahead
      '([^%c%(%)<>@,;:\\"/[%]?={} \t\128-\255]+)',          -- cookie-name
      '=("?)',                                              -- "=" DQUOTE?
      -- Note "%\x5d" below: "\x5d" is "]", which must be escaped as "%]".
      -- However, an escaped character cannot be used to specify a range, so the
      -- next character ("\x5e") is required to start the final range.
      "([\x21\x23-\x2b\x2d-\x3a\x3c-\x5b%\x5d\x5e-\x7e]*)", -- cookie-value
      "%2(;? ?)",                                           -- DQUOTE? "; "?
   })
   local cookies = {}
   local tail = ""
   local pos = 1
   local valid = false
   -- Cookie header is only allowed to appear once.  Ignore repeats.
   if #server.cookies > 0 then
      goto check_valid
   end
   while pos <= #cookie do
      local start_pos, end_pos, name, _quote, value, sep =
         cookie:find(pattern, pos)
      if not start_pos or (sep ~= "; " and sep ~= "") then
         goto check_valid
      end
      tail = sep
      table.insert(cookies, {name=name, value=value})
      pos = end_pos + 1
   end
   valid = tail == ""
   ::check_valid::
   if not valid then
      server.log:warn("ignoring invalid Cookie header")
      return
   end
   server.cookies = cookies
end


--[[ TESTS
local ucl = require("ucl")
local values = {
  'sessionid=abc123; user="john_doe"; theme=dark', -- valid
  "sessionid=abc123 ;user=badsep",                 -- invalid
  "foo@bar=baz",                                   -- invalid
  "a=b; ",                                         -- invalid
  "a=b",                                           -- valid
}
for _, value in ipairs(values) do
   local server = {
      cookies = {},
      log = io.stderr,
   }
   print("Cookie:", value)
   set_cookies(server, value)
   --print("server:", ucl.to_json(server)) -- libucl segfaults on server.log!
   print("cookies:", ucl.to_json(server.cookies))
end
--]]--


local function handle_header_field(server, line)
   if line == "\r" then
      -- When there are no headers left we get just a blank line.
      return handle_blank_line(server)
   else
      local name, value = parse_field(line)

      if name then
         -- Field names are case-insensitive.
         local lname = string.lower(name)
         if lname == "cookie" then
            set_cookies(server, value)
         else
            update_fields(server.request.headers, lname, value)
         end
      else
         server.log:warn("ignoring invalid header: ", line)
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

   elseif state == ServerState.CLOSED then
      return ServerState.CLOSED

   end

   error("unreachable state")
end


-- Define the set of log levels.
local log_levels = {"FATAL", "ERROR", "WARN", "INFO", "DEBUG", "TRACE"}
for i, level in ipairs(log_levels) do
   M[level] = i
end


-- Wrap a log file to add convenience methods.
local function logger(log)
   local log = type(log) == "string" and io.open(log, "a") or log
   if log.setvbuf then
      log:setvbuf("no")
   end
   local pid = (function()
      local f = assert(io.popen("echo $PPID"))
      local pid = f:read("*l")
      f:close()
      return pid
   end)()
   local timestamp = ""
   local time = 0
   local function write(level, ...)
      local now = os.time()
      if time ~= now then
         timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ", now)
         time = now
      end
      local values = {...}
      for i, value in ipairs(values) do
         values[i] = tostring(value)
      end
      local msg = table.concat(values)
      return log:write(("%s %s %s: %s\n"):format(timestamp, pid, level, msg))
   end
   local methods = {}
   function methods.close()
      if log.close then
         return log:close()
      end
   end
   for i, level in ipairs(log_levels) do
      methods[level:lower()] = function(self, ...)
         if self.level >= i then
            return write(level, ...)
         end
      end
   end
   return setmetatable({level=M.FATAL}, {__index=methods})
end


M.default_max_chunk_size = 16 << 20 -- 16 MiB should be enough for anyone.


function M.create_server(log, input, output)
   local server = {
      state = ServerState.START_LINE,
      log = logger(log or io.stderr),
      input = input or io.stdin,
      output = output or io.stdout,
      max_chunk_size = M.default_max_chunk_size,
      -- handlers is a map of method => { location, location, ... }
      -- locations are matched in the order given, first match wins
      -- a location is an ordered list of { pattern, handler }
      -- pattern is a Lua pattern for string matching the path
      -- handler is a function(request) returning a response table
      handlers = {},
   }

   function server:add_route(method, pattern, handler)
      local handlers = self.handlers[method] or {}
      table.insert(handlers, { pattern, handler })
      self.handlers[method] = handlers
   end

   function server:run(log_level)
      self.log.level = log_level
      for line in self.input:lines() do
         self.log:trace(">C ", line)
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
   write_fields(output, trailers)
end


return M

-- vim: set et sw=3:
