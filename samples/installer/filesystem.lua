--
-- Copyright (c) 2020 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local filesystem = filesystem or {}

-- TODO: minimum requirements (in js)
filesystem.formats = {
    {
        title = "UFS (concat)",
        value = "UFS:CONCAT",
        default = false,
    },
    {
        title = "UFS (mirror)",
        value = "UFS:MIRROR",
        default = false,
    },
    {
        title = "UFS (raid5)",
        value = "UFS:RAID5",
        default = false,
    },
    {
        title = "UFS (stripe)",
        value = "UFS:STRIPE",
        default = false,
    },
    {
        title = "ZFS (mirror)",
        value = "ZFS:MIRROR",
        default = true,
    },
    {
        title = "ZFS (raidz1)",
        value = "ZFS:RAIDZ1",
        default = false,
    },
    {
        title = "ZFS (raidz2)",
        value = "ZFS:RAIDZ2",
        default = false,
    },
    {
        title = "ZFS (stripe)",
        value = "ZFS:STRIPE",
        default = false,
    },
}

return filesystem

-- vim: set et sw=4:
