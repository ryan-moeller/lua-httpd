local _M = {}

_M.cols = {
    {"name", "NAME"},
    --{"origin", "ORIGIN"},
    {"version", "VERSION"},
    {"comment", "COMMENT"},
    --{"www", "WWW"}
}

function _M.rows()
    local query = [['{"name": "%n", "origin": "%o", "version": "%v", "comment": "%c", "www": "%w"},']]
    local f = assert(io.popen("pkg query -a "..query))
    local t = "["..f:read("*a").."]"
    f:close()
    local p = ucl.parser()
    local res, err = p:parse_string(t)
    if not res then
        error(err)
    end
    return p:get_object()
end

return _M
