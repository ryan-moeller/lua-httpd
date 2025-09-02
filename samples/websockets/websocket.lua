--
-- Copyright (c) 2024-2025 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local _M <const> = {}

local b64 <const> = require("b64")
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
    local consumed = 0
    local hdr0 <const> = assert(input:read(2))
    consumed = consumed + #hdr0
    local byte0 <const>, byte1 <const> = string.unpack("BB", hdr0)
    local flags <const> = (byte0 >> 4) & 0xf
    local opcode <const> = byte0 & 0xf
    local masked <const> = (byte1 >> 7) & 0x1
    assert(masked == 1)
    local len = byte1 & 0x7f
    if len == 126 then
        local hdr1 <const> = assert(input:read(2))
        consumed = consumed + #hdr1
        len = string.unpack(">I2", hdr1)
    elseif len == 127 then
        local hdr1 <const> = assert(input:read(8))
        consumed = consumed + #hdr1
        len = string.unpack(">I8", hdr1)
    end
    local hdr2 <const> = assert(input:read(4))
    consumed = consumed + #hdr2
    if len == 0 then
        return nil, opcode, flags, consumed
    end
    local key0 <const>, key1 <const>, key2 <const>, key3 <const>, _ = string.unpack("BBBB", hdr2)
    local key <const> = { key0, key1, key2, key3 }
    local payload <const> = assert(input:read(len))
    return xor.apply(payload, key), opcode, flags, consumed + len
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

-- vim: set et sw=4:
