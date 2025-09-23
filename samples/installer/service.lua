--
-- Copyright (c) 2020 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local service = service or {}

service.menu = {
    {
        name = "local_unbound",
        description = "Local caching validating resolver",
        default = false,
    },
    {
        name = "sshd",
        description = "Secure shell daemon",
        default = true,
    },
    {
        name = "moused",
        description = "PS/2 mouse pointer on console",
        default = false,
    },
    {
        name = "ntpdate",
        description = "Synchronize system and network time at bootime",
        default = false,
    },
    {
        name = "ntpd",
        description = "Synchronize system and network time",
        default = false,
    },
    {
        name = "powerd",
        description = "Adjust CPU frequency dynamically if supported",
        default = false,
    },
    {
        name = "dumpdev",
        description = "Enable kernel crash dumps to /var/crash",
        default = true,
    },
}

return service

-- vim: set et sw=4:
