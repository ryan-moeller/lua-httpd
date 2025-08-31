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

## Kqueue

This sample utilizes [kqueue][1] to implement a basic asynchronous event loop
for processing concurrent tasks.  A task consists of a coroutine for the thread
of execution and a kevent referencing that coroutine. When the the event is
triggered, the event loop resumes the coroutine referenced by the kevent.  The
coroutine can then yield back to the event loop when it is ready to wait for the
next event.

As concrete examples, this server registers events filtering for readable data
on the WebSocket fd and on pipe fds connected to child processes handling
long-running tasks.  This enables concurrent handling of WebSocket client
requests and ensures the user interface remains responsive during the execution
of extended operations on the server.

## Sendfile

This sample demonstrates the use of [sendfile][1] to serve static content from
the filesystem.  The advantage of sendfile would be greater for larger files.
