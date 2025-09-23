// Copyright (c) 2025 Ryan Moeller
//
// SPDX-License-Identifier: ISC

import "https://unpkg.com/wasmoon"

const factory = new wasmoon.LuaFactory()
const scripts = [ "client.lua", "widgets.lua", "wsproto.lua" ]
for (const script of scripts) {
  const response = await fetch(`/scripts/${script}`)
  await factory.mountFile(script, await response.text())
}
const lua = await factory.createEngine()
lua.global.set("document", document)
lua.global.set("JSON", JSON)
lua.global.set("ws", new WebSocket(`ws://${location.host}/ws`))
await lua.doFile("client.lua")

// vim: set et sw=2:
