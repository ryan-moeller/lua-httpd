--
-- Copyright (c) 2020 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local partition = partition or {}

-- TODO: various workarounds needed for specific hardware
partition.styles = {
    {
        title = "GPT (BIOS)",
        value = "GPT:BIOS",
        prefer = function(bootmethod)
            return bootmethod == "BIOS"
        end,
    },
    {
        title = "GPT (UEFI)",
        value = "GPT:UEFI",
        prefer = function(bootmethod)
            return false
        end,
    },
    {
        title = "GPT (BIOS+UEFI)",
        value = "GPT:BIOS+UEFI",
        prefer = function(bootmethod)
            return bootmethod == "UEFI"
        end,
    },
    {
        title = "GPT + Active (BIOS)",
        value = "GPT+ACTIVE:BIOS",
        prefer = function(bootmethod)
            return false
        end,
    },
    {
        title = "GPT + Lenovo Fix (BIOS)",
        value = "GPT+LENOVOFIX:BIOS",
        prefer = function(bootmethod)
            return false
        end,
    },
}

return partition

-- vim: set et sw=4:
