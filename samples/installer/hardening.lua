--
-- Copyright (c) 2020 Ryan Moeller
--
-- SPDX-License-Identifier: ISC
--

local hardening = hardening or {}

hardening.menu = {
    {
        name = "hide_uids",
        description = "Hide processes running as other users",
    },
    {
        name = "hide_gids",
        description = "Hide processes running as other groups",
    },
    {
        name = "hide_jail",
        description = "Hide processes running in jails",
    },
    {
        name = "read_msgbuf",
        description =
            "Disable reading kernel message buffer for unprivileged users",
    },
    {
        name = "proc_debug",
        description =
            "Disable process debugging facilities for unprivileged users",
    },
    {
        name = "random_pid",
        description = "Randomize the PID of newly created processes",
    },
    {
        name = "clear_tmp",
        description = "Clean the /tmp filesystem on system startup",
    },
    {
        name = "disable_syslogd",
        description =
            "Disable opening Syslogd network socket (disables remote logging)",
    },
    {
        name = "disable_sendmail",
        description = "Disable Sendmail service",
    },
    {
        name = "secure_console",
        description = "Enable console password prompt",
    },
    {
        name = "disable_ddtrace",
        description = "Disallow DTrace destructive-mode",
    },
}

return hardening

-- vim: set et sw=4:
