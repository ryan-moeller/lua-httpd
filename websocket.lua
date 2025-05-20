-- vim: set et sw=4:
--
-- Copyright (c) 2024 Ryan Moeller <ryan-moeller@att.net>
--
-- SPDX-License-Identifier: ISC
--

local _M <const> = {}

local b64 <const> = require("roken")
local md <const> = require("md")
local xor <const> = require("xor")

_M.WS_FL_FIN = 0x8

_M.WS_OP_TEXT = 0x1
_M.WS_OP_BINARY = 0x2
_M.WS_OP_CLOSE = 0x8
_M.WS_OP_PING = 0x9
_M.WS_OP_PONG = 0xA

function _M.accept(key)
    local magic <const> = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    local sha1 <const> = md.sha1_init()
    sha1:update(key .. magic)
    local s <const> = sha1:final()
    return b64.encode(s)
end

function _M.receive(input)
    local hdr0 <const> = input:read(2)
    local byte0 <const>, byte1 <const> = string.unpack("BB", hdr0)
    local flags <const> = (byte0 >> 4) & 0xf
    local opcode <const> = byte0 & 0xf
    local masked <const> = (byte1 >> 7) & 0x1
    if not masked then
        return nil, "invalid ws header"
    end
    local len = byte1 & 0x7f
    if len == 126 then
        local hdr1 <const> = input:read(2)
        len = string.unpack(">I2", hdr1)
    elseif len == 127 then
        local hdr1 <const> = input:read(8)
        len = string.unpack(">I8", hdr1)
    end
    local hdr2 <const> = input:read(4)
    local key0 <const>, key1 <const>, key2 <const>, key3 <const>, _ = string.unpack("BBBB", hdr2)
    local key <const> = { key0, key1, key2, key3 }
    if len == 0 then
        return nil, len, opcode, flags
    end
    local payload <const> = input:read(len)
    return xor.apply(payload, key), len, opcode, flags
end

function _M.send(output, payload, opcode, flags)
    local byte0 <const> = (flags << 4) | opcode
    local len <const> = payload and #payload or 0
    if len > 0xffff then
        local byte1 <const> = 127
        output:write(string.pack(">BBI8", byte0, byte1, len))
    elseif len > 125 then
        local byte1 <const> = 126
        output:write(string.pack(">BBI2", byte0, byte1, len))
    else
        local byte1 <const> = len
        output:write(string.pack("BB", byte0, byte1))
    end
    if payload and len > 0 then
        output:write(payload)
    end
    output:flush()
end

return _M
