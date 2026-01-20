# Lighttpd notes

`install.sh` will configure Lighttpd automatically on Debian/Ubuntu:

- Sets `server.port` only once in `/etc/lighttpd/lighttpd.conf` (to avoid duplicate `server.port` errors).
- Enables `mod_alias` and adds an alias for `/vnstat/` pointing to the installed web path.
- Enables `mod_cgi` (Debian's `10-cgi.conf`) and tightens `cgi.assign` to **only** allow `.cgi`.
- Disables `debian-doc` to avoid problematic CGI defaults.

If you want to do it manually,参考 `lighttpd/vnstat-web.conf`。
