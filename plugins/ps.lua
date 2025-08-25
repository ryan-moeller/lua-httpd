local ucl <const> = require("ucl")

local _M = {}

_M.title = "Processes"

_M.cols = {
    {"user", "USER"}, 
    {"pid", "PID"}, 
    {"percent-cpu", "%CPU"}, 
    {"percent-memory", "%MEM"}, 
    {"virtual-size", "VSZ"}, 
    {"rss", "RSS"}, 
    {"terminal-name", "TT"}, 
    {"state", "STAT"}, 
    {"start-time", "STARTED"}, 
    {"cpu-time", "TIME"}, 
    {"command", "COMMAND"}, 
}

function _M.rows()
    local f = assert(io.popen("ps aux --libxo:J", "r"))
    local t = f:read("*a")
    f:close()
    local parser = ucl.parser()
    local res, err = parser:parse_string(t)
    if not res then
        return nil, err
    end
    local processes = parser:get_object()["process-information"].process
    table.sort(processes, function(a, b) return tonumber(a.pid) < tonumber(b.pid) end)
    return processes
end

return _M
