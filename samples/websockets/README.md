## WebSockets

This sample incorporates [ryan-moeller/flualibs][1] to implement a separate
WebSockets module.  The server.flua script manages FreeBSD snapshot boot
environments in a simplistic way.  A button is shown when a new snapshot build
is avalable to download.  The button creates a new ZFS boot environment
with libbe and extracts the snapshot distsets over it, preserving a few
key files in /etc.  Tables list the boot environments and downloaded
snapshot files on the system, with buttons to delete ones no longer
desired.

[1]: https://github.com/ryan-moeller/flualibs

Some peculiarities of my environment are hardcoded, such the name of my root
pool ("system").  Adjust as needed.

A few compiled modules are needed to implement the WebSocket protocol (namely
libmd for SHA1, b64 for base64, and libxor for XOR unmasking).  These modules
only depend on base system libraries.
