# Static File Browser

Serve static files and browse directories over HTTP.  This sample provides a
simple file browser interface for navigating and downloading files from the
server's filesystem.

## Sendfile

This sample demonstrates the use of [sendfile][1] to serve static content from
the filesystem.

[1]: https://github.com/ryan-moeller/flualibs

## MIME

MIME information is obtained using [libmagic][1] from the FreeBSD base system.
