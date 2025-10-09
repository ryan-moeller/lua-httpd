--
-- Copyright (c) 2016-2025 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local M = {}

M.VERSION = "0.5.0"


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
   -- The order of field lines with different names is not significant
   -- (RFC 9110 §5.3), so iterating table keys is acceptable.
   for name, value in pairs(headers or {}) do
      if type(value) == "table" then
         -- Accept an ordered list of values for repeated headers.
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


-- expects a server table and a response table
-- example response table:
-- { status=404, reason="not found", headers={}, cookies={},
--   body="404 Not Found" }
local function write_http_response(server, response)
   local output = server.output

   local status = response.status
   local reason = response.reason
   local headers = response.headers or {}
   local cookies = response.cookies
   local body = response.body

   -- TODO: normalize header names

   -- MUST generate a Date header field in certain cases (RFC 9110 §6.6.1)
   -- Doesn't hurt to always send one.
   if not headers["Date"] then
      headers["Date"] = os.date("!%a, %d %b %Y %H:%M:%S GMT")
   end

   if type(body) == "string" then
      headers["Content-Length"] = #body
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

   -- Close input and output file handles to complete the response.
   -- TODO: pipelining
   if server.input == io.stdin or server.output == io.stdout then
      -- We can't close stdin or stdout, we have to exit.
      os.exit()
   end
   -- TODO: Accommodate a persistent server with an accept loop.  For now, we
   -- must trash the server after every request/response.
   server.input:close()
   if server.output ~= server.input then
      server.output:close()
   end
   server.log:close()
end


-- Header format:
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
-- The `raw` and `elements` fields of a header invoke the parser on first access
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


-- Header value lexer FSM states
local HeaderValueLexerState = {
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
local HeaderValueLexerAccept = {
   -- REMEMBER: these must be contiguous keys in order starting from 1 (thus +1)
   [HeaderValueLexerState.OWS + 1] = true,
   [HeaderValueLexerState.TOKEN + 1] = true,
   [HeaderValueLexerState.LIST_DELIMITER + 1] = true,
   [HeaderValueLexerState.QUOTED_STRING_BEGIN + 1] = false,
   [HeaderValueLexerState.QUOTED_STRING + 1] = false,
   [HeaderValueLexerState.QUOTED_STRING_END + 1] = true,
   [HeaderValueLexerState.ESCAPE + 1] = false,
   [HeaderValueLexerState.COMMENT_OPEN + 1] = false,
   [HeaderValueLexerState.COMMENT + 1] = false,
   [HeaderValueLexerState.COMMENT_CLOSE + 1] = true,
   [HeaderValueLexerState.PARAMETER + 1] = true, -- optional in parameters
   [HeaderValueLexerState.PARAMETER_NAME + 1] = true,
   [HeaderValueLexerState.PARAMETER_VALUE + 1] = false, -- "=" must be followed
   [HeaderValueLexerState.CONTENT + 1] = false, -- not structured
   -- We can omit ERROR, as transitioning into ERROR halts the FSM.
}
-- Sanity check the array layout.
assert(#HeaderValueLexerAccept == HeaderValueLexerState.ERROR)


-- The lexer FSM initialization is deferred until we parse a header.
local HeaderValueLexerFSM = nil


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
   -- so we use the size of the HeaderValueLexerAccept array instead.  The FSM
   -- and Accept tables exclude the ERROR state to avoid wasting time and space.
   for i = 1, (#HeaderValueLexerAccept) << 8 do
      -- Anything not caught by the rules below is invalid.
      fsm[i] = HeaderValueLexerState.ERROR
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
      expand(state, {{WSP, field_vchar}, HeaderValueLexerState.CONTENT})
      -- §5.6 Common Rules for Defining Field Values (optimistic)
      for _, rule in ipairs(rules) do
         expand(state, rule)
      end
   end

   -- Build the lookup table for the header value lexer FSM.
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
      {WSP, HeaderValueLexerState.OWS},
      -- §5.6.1 Lists
      {comma, HeaderValueLexerState.LIST_DELIMITER},
      -- §5.6.2 Tokens
      {tchar, HeaderValueLexerState.TOKEN},
      -- §5.6.4 Quoted Strings
      {DQUOTE, HeaderValueLexerState.QUOTED_STRING_BEGIN},
      -- §5.6.5 Comments
      {lparen, HeaderValueLexerState.COMMENT_OPEN},
      -- §5.6.6 Parameters
      {semicolon, HeaderValueLexerState.PARAMETER},
   }
   local string_rules = {
      -- §5.6.4 Quoted Strings
      -- Note: Exceptions from this range are made by the later rules.
      {{WSP, VCHAR, obs_text}, HeaderValueLexerState.QUOTED_STRING},
      {DQUOTE, HeaderValueLexerState.QUOTED_STRING_END},
      {backslash, HeaderValueLexerState.ESCAPE},
   }
   local comment_rules = {
      -- §5.6.5 Comments
      -- Note: Exceptions from this range are made by the later rules.
      {{WSP, VCHAR, obs_text}, HeaderValueLexerState.COMMENT},
      {lparen, HeaderValueLexerState.COMMENT_OPEN},
      {rparen, HeaderValueLexerState.COMMENT_CLOSE},
      {backslash, HeaderValueLexerState.ESCAPE},
   }
   state_rules(HeaderValueLexerState.OWS, element_rules)
   state_rules(HeaderValueLexerState.TOKEN, {
      -- §5.6.1 Lists, §5.6.6 Parameters
      {WSP, HeaderValueLexerState.OWS},
      -- §5.6.1 Lists
      {comma, HeaderValueLexerState.LIST_DELIMITER},
      -- §5.6.2 Tokens
      {tchar, HeaderValueLexerState.TOKEN},
      -- §5.6.5 Comments
      {lparen, HeaderValueLexerState.COMMENT_OPEN},
      -- §5.6.6 Parameters
      {semicolon, HeaderValueLexerState.PARAMETER},
   })
   state_rules(HeaderValueLexerState.LIST_DELIMITER, element_rules)
   state_rules(HeaderValueLexerState.QUOTED_STRING_BEGIN, string_rules)
   state_rules(HeaderValueLexerState.QUOTED_STRING, string_rules)
   state_rules(HeaderValueLexerState.QUOTED_STRING_END, {
      -- §5.6.1 Lists, §5.6.6 Parameters
      {WSP, HeaderValueLexerState.OWS},
      -- §5.6.1 Lists
      {comma, HeaderValueLexerState.LIST_DELIMITER},
      -- §5.6.5 Comments
      {lparen, HeaderValueLexerState.COMMENT_OPEN},
      -- §5.6.6 Parameters
      {semicolon, HeaderValueLexerState.PARAMETER},
   })
   state_rules(HeaderValueLexerState.ESCAPE, {
      -- §5.6.4 Quoted Strings, §5.6.5 Comments
      -- Note: The parser is responsible for interpreting ESCAPE->ESCAPE as a
      -- return to either QUOTED_STRING or COMMENT.
      {{WSP, VCHAR, obs_text}, HeaderValueLexerState.ESCAPE},
   })
   state_rules(HeaderValueLexerState.COMMENT_OPEN, comment_rules)
   state_rules(HeaderValueLexerState.COMMENT, comment_rules)
   -- Note: The grammar defines comments recursively, allowing arbitrary
   -- nesting via balanced pairs of parentheses.  It is the parser's
   -- responsibility to track the nesting depth and avoid treating the
   -- comment as closed until the final ")" is encountered.  If the comment
   -- is still open after a transition to COMMENT_CLOSE, then the parser
   -- must advance the FSM to the COMMENT state instead of COMMENT_CLOSE.
   --
   -- The following rules encode the transitions when the comment IS closed.
   state_rules(HeaderValueLexerState.COMMENT_CLOSE, element_rules)
   state_rules(HeaderValueLexerState.PARAMETER, {
      -- §5.6.6 Parameters
      {{WSP, semicolon}, HeaderValueLexerState.PARAMETER},
      {tchar, HeaderValueLexerState.PARAMETER_NAME},
   })
   state_rules(HeaderValueLexerState.PARAMETER_NAME, {
      -- §5.6.1 Lists, §5.6.6 Parameters
      {WSP, HeaderValueLexerState.OWS},
      -- §5.6.1 Lists
      {comma, HeaderValueLexerState.LIST_DELIMITER},
      -- §5.6.2 Tokens, §5.6.6 Parameters
      {semicolon, HeaderValueLexerState.PARAMETER},
      {tchar, HeaderValueLexerState.PARAMETER_NAME},
      {equals, HeaderValueLexerState.PARAMETER_VALUE},
   })
   state_rules(HeaderValueLexerState.PARAMETER_VALUE, {
      -- §5.6.6 Parameters
      -- §5.6.2 Tokens
      {tchar, HeaderValueLexerState.TOKEN},
      -- §5.6.4 Quoted Strings
      {DQUOTE, HeaderValueLexerState.QUOTED_STRING_BEGIN},
   })
   state_rules(HeaderValueLexerState.CONTENT, {
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


-- The header value parser encodes its behavior in a LUT.  The index into the
-- LUT is constructed from the lexer state transition (s, n), where s is the
-- current state of the lexer and n is the next state of the lexer.  Concretely,
-- the index is `((s << 4) | n) + 1`.  There are ten lexer states, so we need
-- four lower bits and four higher bits.  The +1 offset is required for Lua's
-- array-backed tables, which expect indices to start at 1 for optimal
-- performance.
--
-- The parser LUT stores an opcode for each state transition.  The opcode is a
-- bitfield encoding the operations to be performed on the parser state.  Each
-- HeaderValueParserOp represents a bit in the opcode and a corresponding
-- function in the HeaderValueParserOpCode table.  The op is used as a shift
-- amount in the opcode bitfield and as an index in the HeaderValueParserOpCode
-- table.  The HeaderValueParserOpCode table is again constrained to 1-based
-- indexing by Lua's array-backed table, so the least-significant bit of
-- the opcode (corresponding to the unused shift amount 0) is available for
-- future use.
local HeaderValueParserOp = {
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
local HeaderValueParserOpCode = {
   -- REMEMBER: these must contiguous values in order starting from 1
   [HeaderValueParserOp.ESCAPE] = function(parser)
      local chunk = parser.value:sub(parser.mark, parser.pos - 1)
      table.insert(parser.stack, chunk)
   end,
   [HeaderValueParserOp.MARK] = function(parser)
      parser.mark = parser.pos
   end,
   [HeaderValueParserOp.COMMENT] = function(parser)
      -- TODO: save the comment structure?
      parser.comment_depth = parser.comment_depth + 1
   end,
   [HeaderValueParserOp.START_ITEM] = function(parser)
      parser.current_element = parser.current_element or {}
   end,
   [HeaderValueParserOp.PUSH_TOKEN] = function(parser)
      local value = parser.value:sub(parser.mark, parser.pos - 1)

      local element = parser.current_element
      assert(element, "PUSH_TOKEN: no current element")

      local name = parser.param_name

      if parser.lexer_state == HeaderValueLexerState.PARAMETER_NAME then
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
         parser.next_lexer_state = HeaderValueLexerState.CONTENT
      end
   end,
   [HeaderValueParserOp.PUSH_QUOTED] = function(parser)
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
         parser.next_lexer_state = HeaderValueLexerState.CONTENT
      end
   end,
   [HeaderValueParserOp.PUSH_COMMENT] = function(parser)
      local depth = parser.comment_depth - 1
      assert(depth >= 0)
      if depth > 0 then
         parser.next_lexer_state = HeaderValueLexerState.COMMENT
         -- TODO: save the comment structure?
      end
      parser.comment_depth = depth
      -- Clear any escape chunks for now.  Revise when comments are saved.
      parser.stack = {}
   end,
   [HeaderValueParserOp.SET_PARAM] = function(parser)
      assert(parser.param_name, "SET_PARAM: no param name")
      table.insert(parser.current_element.params, {attribute=parser.param_name})
      parser.param_name = nil
   end,
   [HeaderValueParserOp.END_ITEM] = function(parser)
      local element = parser.current_element
      assert(element, "END_ITEM: no current element")
      table.insert(parser.staged_elements, element)
      parser.current_element = nil
   end,
   [HeaderValueParserOp.RETURN] = function(parser)
      local prev_lexer_state = parser.prev_lexer_state
      if prev_lexer_state == HeaderValueLexerState.QUOTED_STRING_BEGIN then
         parser.next_lexer_state = HeaderValueLexerState.QUOTED_STRING
      elseif prev_lexer_state == HeaderValueLexerState.COMMENT_OPEN then
         parser.next_lexer_state = HeaderValueLexerState.COMMENT
      else
         parser.next_lexer_state = prev_lexer_state
      end
   end,
   --[[ DEBUG
   [HeaderValueParserOp.TRACE] = function(parser)
      io.stderr:write(("trace on opcode=%#x byte=%#x\n")
         :format(parser.opcode, parser.byte))
   end,
   ]]--
}


-- Initialization of the parser LUTs is deferred until we parse a header.
local HeaderValueParserLUT, HeaderValueParserFinalLUT = nil, nil


-- Compile the parser operations performed on lexer state transitions into
-- a VM-optimized table of opcodes.
local function build_parser_luts()
   local lut = {}
   local final = {}

   local S = HeaderValueLexerState
   local O = HeaderValueParserOp

   -- The parser LUT index is two 4-bit fields, so 8 bits total = 256 entries.
   for i = 1, 256 do
      lut[i] = 0 -- NOP
   end

   -- There is no direct way to get the number of states, but it is the size of
   -- the lexer FSM / 256, i.e. eliminating the input byte portion of the index.
   -- Note the parentheses to avoid being parsed as #(HeaderValueLexerFSM >> 8).
   for i = 1, (#HeaderValueLexerFSM) >> 8 do
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
   for op = 1, #HeaderValueParserOpCode do
      if (opcode & (1 << op)) ~= 0 then
         HeaderValueParserOpCode[op](parser)
      end
   end
end


-- Abuse mitigations
--
-- These limits are lenient by a huge margin but help the parser ignore
-- pathological input.  If you're expecting huge quoted strings with an
-- absurd number of escapes in your headers and run into this limit, it
-- can be raised on the module table before running the server.
M.header_value_parser_stack_size_limit = 1000
M.header_value_parser_comment_depth_limit = 100


local function parse_header_value_impl(header, value)
   local stack = {}
   local stack_size_limit = M.header_value_parser_stack_size_limit
   local comment_depth_limit = M.header_value_parser_comment_depth_limit
   local parser = {
      header = header,
      value = value,
      next_lexer_state = HeaderValueLexerState.OWS,
      pos = 1,
      stack = stack,
      comment_depth = 0,
      staged_elements = {},
   }

   while parser.pos <= #value do
      local byte = value:byte(parser.pos)
      local lexer_state = parser.next_lexer_state
      local lexer_index = ((lexer_state << 8) | byte) + 1
      local next_lexer_state = assert(HeaderValueLexerFSM[lexer_index])

      if next_lexer_state == HeaderValueLexerState.ERROR or
         -- Ignore pathological input.
         #stack > stack_size_limit or
         parser.comment_depth > comment_depth_limit then
         -- Abort! This message is bunk!
         return
      end

      local parser_index = ((lexer_state << 4) | next_lexer_state) + 1
      local opcode = assert(HeaderValueParserLUT[parser_index])

      parser.byte = byte
      parser.prev_lexer_state = parser.lexer_state
      parser.lexer_state = lexer_state
      parser.next_lexer_state = next_lexer_state
      execute_parser_opcode(parser, opcode)
      parser.pos = parser.pos + 1
   end

   -- Finalize any pending structures.
   local lexer_state = parser.next_lexer_state
   local opcode = assert(HeaderValueParserFinalLUT[lexer_state + 1])

   parser.byte = 0
   parser.prev_lexer_state = parser.lexer_state
   parser.lexer_state = lexer_state
   parser.next_lexer_state = nil
   execute_parser_opcode(parser, opcode)

   -- Update the header.
   if HeaderValueLexerAccept[lexer_state + 1] then
      for _, element in ipairs(parser.staged_elements) do
         table.insert(header.elements, element)
      end
   end
   table.insert(header.raw, value)
end


local function parse_header_value(header, value)
   -- Lazy lexer/parser construction
   --
   -- Some requests may not require header inspection at all.  We don't need the
   -- lexer/parser machinery unless we end up here.
   HeaderValueLexerFSM = build_lexer_fsm()
   HeaderValueParserLUT, HeaderValueParserFinalLUT = build_parser_luts()
   -- This little trick avoids adding a branch to check for initialization every
   -- time we parse a header.
   parse_header_value = parse_header_value_impl
   parse_header_value(header, value)
end


local header_methods = {
   concat = function(header, ...)
      return table.concat(header.raw, ...)
   end,

   contains_value = function(header, value)
      for _, element in ipairs(header.elements) do
         if element.value == value then
            return true
         end
      end
      return false
   end,

   find_elements = function(header, value)
      local matches = {}
      for _, element in ipairs(header.elements) do
         if element.value == value then
            table.insert(matches, element)
         end
      end
      return matches
   end,

   -- TODO: add some more convenience methods
}


local header_metatable = {
   __index = function(header, key)
      if key ~= "raw" and key ~= "elements" then
         return header_methods[key]
      end
      header.raw = {} -- list of all raw (but validated) field values
      header.elements = {} -- list of structured elements
      for _, value in ipairs(header.unvalidated) do
         parse_header_value(header, value)
      end
      return header[key]
   end,
}


local function new_header()
   return setmetatable({unvalidated={}}, header_metatable)
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
   local header = new_header()
   table.insert(header.unvalidated, value)
   -- Note if tracing is added to parse_header_value() that it is invoked once
   -- for `raw` but not again for `elements`, because the result is memoized.
   print("raw: ", ucl.to_json(header.raw))
   print("elements: ", ucl.to_json(header.elements))
end
--]]--


local function update_header_table(t, name, value)
   -- Header parsing is deferred until either header.raw or header.elements is
   -- accessed (potentially by a convenience method).
   --
   -- Just accumulate unvalidated input values in a list for now.
   --
   -- TODO: Validation/parsing for all headers could be forced by a server
   -- configuration parameter.
   local header = t[name] or new_header()
   table.insert(header.unvalidated, value)
   t[name] = header
end


local function parse_header_field(line)
   return line:match("^(%g+):[ \t]*(.-)[ \t]*\r$")
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
         -- Cookies received in trailers are intentionally ignored.
         -- We'll just throw them in with the trailers instead.
         update_header_table(server.request.trailers, name, value)
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
   local transfer_encoding_header = request.headers["transfer-encoding"]
   local content_length_header = request.headers["content-length"]

   if transfer_encoding_header then
      if transfer_encoding_header:concat() == "chunked" then
         return handle_chunked_message_body(server)
      else
         server.log:write("unsupported transfer-encoding\n")
      end
   elseif content_length_header then
      -- Be lenient and only use the last received content-length header value.
      local elements = content_length_header.elements
      local content_length = tonumber(elements[#elements].value)
      if content_length then
         return handle_message_body(server, content_length)
      else
         server.log:write("invalid content-length\n")
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
      server.log:write("Ignoring invalid Cookie header\n")
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
      local name, value = parse_header_field(line)

      if name then
         -- Header field names are case-insensitive.
         local lname = string.lower(name)
         if lname == "cookie" then
            set_cookies(server, value)
         else
            update_header_table(server.request.headers, lname, value)
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
      log = logfile and io.open(logfile, "a") or io.stderr,
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
