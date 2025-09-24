# FreeBSD Jails Administration

Manage FreeBSD jails, including downloading the latest snapshot build and
creating and starting new jails.

Some specifics of my environment such as the jails dataset are hard coded.
Adjust as needed.

## Template Including

Rather than serving multiple files, this server uses the [template including][1]
feature of the template library to embed the JavaScript for the frontend into
the HTML body.  This looks like `{(%s/scripts/jails.js)}` in the template.

[1]: https://github.com/bungle/lua-resty-template?tab=readme-ov-file#template-including 

## Form Submission

This sample demonstrates a more complex form submission, with multiple fields.
