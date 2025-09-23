-- Copyright (c) 2025 Ryan Moeller
--
-- SPDX-License-Identifier: ISC

require("widgets")
require("wsproto")

local c <const> = document:querySelector("div.container")

function ws_command(command, data)
    ws:send(JSON.stringify({command=command,data=data}))
end

function ws.onopen(event)
    ws_command(CMD_WORKTREE_LIST)
end

function error_notification(message)
    local n <const> = notification()
    n.classList:add("is-danger")
    n:appendChild(text(message))
    c:appendChild(n)
end

-- Worktrees table widget.
local worktrees

-- Repo table widget.
local repo

-- Output log terminal widget.
local log, log_update
local function forget_log()
    log = nil
    log_update = nil
end

local handlers <const> = {
    [CMD_WORKTREE_LIST] = function(msg)
        if worktrees then
            worktrees:remove()
        end
        if repo then
            repo:remove()
            repo = nil
        end
        worktrees = worktrees_table(msg.worktrees, msg.upstreams)
        c:appendChild(worktrees)
    end,
    [CMD_WORKTREE_PULL] = function(msg)
        if not log then
            log, log_update = terminal(24, 80 * 1000)
            c:appendChild(log)
        end
        if msg.output then
            log_update(msg.output)
        end
        if msg.exit_code then
            if msg.exit_code == 0 then
                c:appendChild(message(text"Up to date!", log, forget_log, "is-success"))
            else
                c:appendChild(message(
                    text(("Update failed with code %d!"):format(msg.exit_code)),
                    log, forget_log, "is-danger"
                ))
            end
            log_update() -- XXX: reparenting resets scroll
        end
    end,
    [CMD_REPO_LIST] = function(msg)
        if repo then
            repo:remove()
        end
        repo = repo_table(msg.worktree, msg.repo or {})
        c:appendChild(repo)
    end,
    [CMD_REPO_BUILD] = function(msg)
        if not log then
            log, log_update = terminal(24, 80 * 1000)
            c:appendChild(log)
        end
        if msg.output then
            log_update(msg.output)
        end
        if msg.done then
            -- TODO: exit_code instead of done so we can report failures
            c:appendChild(message(text"Build done!", log, forget_log, "is-success"))
            log_update() -- XXX: reparenting resets scroll
        end
    end,
    [CMD_REPO_DELETE] = function(msg)
        if not log then
            log, log_update = terminal(24, 80 * 1000)
            c:appendChild(log)
        end
        if msg.output then
            log_update(msg.output)
        end
        if msg.exit_code then
            if msg.exit_code == 0 then
                c:appendChild(message(text"Deleted!", log, forget_log, "is-success"))
            else
                c:appendChild(message(
                    text(("Delete failed with code %d!"):format(msg.exit_code)),
                    log, forget_log, "is-danger"
                ))
            end
            log_update() -- XXX: reparenting resets scroll
        end
    end,
}

function ws.onmessage(event)
    local msg <const> = JSON.parse(event.data)
    if not msg or not msg.command then
        error_notification("invalid websocket message received")
        return
    end
    local handler <const> = handlers[msg.command]
    if not handler then
        error_notification("invalid websocket message received")
        return
    end
    handler(msg)
end

-- vim: set et sw=4:
