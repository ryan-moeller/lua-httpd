# Sample Servers

In this directory are several sample web application servers for FreeBSD's Lua
interpreter (flua) in combination with inetd.  The samples utilize a simplified
version of [bungle/lua-resty-template][1] for templating, as found in the
FreeBSD source tree at `/usr/src/tools/lua/template.lua`, vendored at
`samples/contrib/template.lua` in this repo.  They also use various system
library bindings from [ryan-moeller/flualibs][2], e.g. to help set up error
logging or leverage operating system features such as kqueue and sendfile.

[1]: https://github.com/bungle/lua-resty-template
[2]: https://github.com/ryan-moeller/flualibs
