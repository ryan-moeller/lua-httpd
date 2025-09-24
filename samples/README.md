# Sample Servers

In this directory are several sample web application servers for FreeBSD's Lua
interpreter (flua) in combination with inetd.  The samples utilize a simplified
version of [bungle/lua-resty-template][1] for templating, as found in the
FreeBSD source tree at `/usr/src/tools/lua/template.lua`, vendored at
`samples/contrib/template.lua` in this repo.  They also use `fileno` from
[ryan-moeller/flualibs][2] to help set up error logging.

[1]: https://github.com/bungle/lua-resty-template
[2]: https://github.com/ryan-moeller/flualibs
