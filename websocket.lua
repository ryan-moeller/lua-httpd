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

local _M = {}

package.cpath = "/home/ryan/flualibs/libmd/?.so;" .. package.cpath
package.cpath = "/home/ryan/flualibs/libroken/?.so;" .. package.cpath
package.cpath = "/home/ryan/flualibs/libxor/?.so;" .. package.cpath

local b64 = require("roken")
local md = require("md")
local xor = require("xor")

_M.WS_FL_FIN = 0x8

_M.WS_OP_TEXT = 0x1
_M.WS_OP_BINARY = 0x2
_M.WS_OP_CLOSE = 0x8
_M.WS_OP_PING = 0x9
_M.WS_OP_PONG = 0xA

function _M.accept(key)
    local magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    local sha1 = md.sha1_init()
    sha1:update(key .. magic)
    local s = sha1:final()
    return b64.encode(s)
end

function _M.receive(input)
    local hdr0 = input:read(2)
    local byte0, byte1 = string.unpack("BB", hdr0)
    local flags = (byte0 >> 4) & 0xf
    local opcode = byte0 & 0xf
    local masked = (byte1 >> 7) & 0x1
    if not masked then
        return nil, "invalid ws header"
    end
    local len = byte1 & 0x7f
    if len == 126 then
        local hdr1 = input:read(2)
        len = string.unpack(">I2", hdr1)
    elseif len == 127 then
        local hdr1 = input:read(8)
        len = string.unpack(">I8", hdr1)
    end
    local hdr2 = input:read(4)
    local key0, key1, key2, key3, _ = string.unpack("BBBB", hdr2)
    local key = { key0, key1, key2, key3 }
    if len == 0 then
        return nil, len, opcode, flags
    end
    local payload = input:read(len)
    return xor.unmask(payload, key), len, opcode, flags
end

function _M.send(output, payload, opcode, flags)
    local byte0 = (flags << 4) | opcode
    local len = payload and #payload or 0
    if len > 0xffff then
        local byte1 = 127
        output:write(string.pack(">BBI8", byte0, byte1, len))
    elseif len > 125 then
        local byte1 = 126
        output:write(string.pack(">BBI2", byte0, byte1, len))
    else
        local byte1 = len
        output:write(string.pack("BB", byte0, byte1))
    end
    if payload and len > 0 then
        output:write(payload)
    end
    output:flush()
end

return _M
