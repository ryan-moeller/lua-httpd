-- Copyright (c) 2025 Ryan Moeller
--
-- SPDX-License-Identifier: ISC

function element(e, ...)
    local elem <const> = document:createElement(e)
    for _, class in ipairs({...}) do
        elem.classList:add(class)
    end
    return elem
end

function text(...)
    return document:createTextNode(...)
end

function section(...)
    return element("section", "section", ...)
end

function div(...)
    return element("div", ...)
end

function container(...)
    return div("container", ...)
end

function title(...)
    return element("h1", "title", ...)
end

function subtitle(...)
    return element("p", "subtitle", ...)
end

function button(...)
    return element("button", "button", ...)
end

function delete(...)
    return element("button", "delete", ...)
end

function notification(...)
    local d <const> = div("notification", ...)
    local del <const> = delete()
    function del.onclick(event)
        d:remove()
    end
    d:appendChild(del)
    return d
end

function message(header, body, onclose, ...)
    local d <const> = div("message", ...)
    local hdr <const> = div("message-header")
    hdr:appendChild(header)
    local del <const> = delete()
    function del.onclick(event)
        d:remove()
        if onclose then
            onclose()
        end
    end
    hdr:appendChild(del)
    d:appendChild(hdr)
    body.classList:add("message-body")
    d:appendChild(body)
    return d
end

function tbl(...)
    return element("table", "table", ...)
end

function block(...)
    return div("block", ...)
end

function box(...)
    return div("box", ...)
end

function worktrees_table(worktrees, upstreams)
    local t <const> = tbl()
    do
        local row <const> = t:createTHead():insertRow()
        row:insertCell():appendChild(text"worktree")
        row:insertCell():appendChild(text"HEAD")
        row:insertCell():appendChild(text"branch")
        row:insertCell():appendChild(text"upstream")
        row:insertCell() -- pull
    end
    local tbody <const> = t:createTBody()
    for _, worktree in ipairs(worktrees) do
        local row <const> = tbody:insertRow()
        row:insertCell():appendChild(text(worktree.worktree))
        row:insertCell():appendChild(text(worktree.HEAD))
        if worktree.detached then
            row:insertCell():appendChild(text"detached")
            row:insertCell() -- upstream
            row:insertCell() -- pull
        else
            row:insertCell():appendChild(text(worktree.branch))
            local upstream <const> = upstreams[worktree.branch]
            if upstream then
                row:insertCell():appendChild(text(upstream))
                local pull <const> = button("is-small")
                pull:appendChild(text"Pull")
                function pull.onclick(event)
                    ws_command(CMD_WORKTREE_PULL, worktree.worktree)
                end
                row:insertCell():appendChild(pull)
            else
                row:insertCell() -- upstream
                row:insertCell() -- pull
            end
        end
        function row.onclick(event)
            for _, trow in ipairs(tbody.rows) do
                trow.classList:remove("is-selected")
            end
            row.classList:add("is-selected")
            ws_command(CMD_REPO_LIST, worktree.worktree)
        end
    end
    return t
end

function repo_table(worktree, repo)
    local t <const> = tbl()
    do
        local row <const> = t:createTHead():insertRow()
        row:insertCell():appendChild(text"PKG_ABI")
        row:insertCell():appendChild(text"PKG_VERSION")
        row:insertCell():appendChild(text"latest?")
        row:insertCell()
    end
    local tbody <const> = t:createTBody()
    -- Sort ABIs in ascending order.
    table.sort(repo, function(a, b) return a.pkg_abi < b.pkg_abi end)
    for _, abi in ipairs(repo) do
        -- Sort versions in descending order.
        table.sort(abi.versions, function(a, b) return b < a end)
        for _, version in ipairs(abi.versions) do
            local row <const> = tbody:insertRow()
            row:insertCell():appendChild(text(abi.pkg_abi))
            row:insertCell():appendChild(text(version))
            local latest <const> = version == abi.latest
            row:insertCell():appendChild(text(latest and "yes" or "no"))
            if latest then
                row:insertCell() -- No deleting the latest build.
            else
                local d <const> = delete() -- XXX: is-danger doesn't work
                function d.onclick(event)
                    -- TODO: confirmation
                    row:remove()
                    ws_command(CMD_REPO_DELETE, {
                        worktree = worktree,
                        pkg_abi = abi.pkg_abi,
                        version = version,
                    })
                end
                row:insertCell():appendChild(d)
            end
        end
    end
    do
        local row <const> = t:createTFoot():insertRow()
        local cell <const> = row:insertCell()
        cell.colSpan = 4
        local build <const> = button("is-primary", "is-pulled-right")
        build:appendChild(text"New Build")
        function build.onclick(event)
            t:remove()
            ws_command(CMD_REPO_BUILD, worktree)
        end
        cell:appendChild(build)
    end
    return t
end

function terminal(nlines, nchars)
    local log <const> = element("pre", "box")
    log.style:setProperty("overflow", "auto")
    log.style:setProperty("scrollbar-width", "none")
    log.style:setProperty("white-space", "pre-wrap")
    log.style:setProperty("height", tostring(nlines).."lh")
    return log, function(str, clear)
        if clear then
            log.textContent = ""
        elseif str then
            -- Split off new strings every nchars or so to keep the full thing
            -- from being rendered every update.
            local content <const> = log.textContent .. str
            local split
            if content:len() > nchars then
                split = content:find("\n", -nchars) or -nchars
            else
                split = -nchars
            end
            log.textContent = content:sub(split)
        end
        log.scrollTop = log.scrollHeight
    end
end

-- vim: set et sw=4:
