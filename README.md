# mhttp

HTTP/1.1 server and client for Lua 5.4. The parser and the serializer
do no I/O. The server and the client use a small stream interface, so
any event loop or coroutine scheduler can drive them. Framing is strict
against request smuggling and response splitting.

```lua
local server = require("mhttp.server")
local client = require("mhttp.client")
local posix = require("mhttp.io.posix")

local srv = server.new({ handler = function(req, res)
	res:send(200, "hello " .. req.path)
end })

-- Many connections in one process, with only luaposix:
local loop = require("mhttp.io.poll").new()
loop:serve(assert(loop:listen("127.0.0.1", 8080)), srv)
loop:run()

-- Or one connection at a time, blocking:
local l = assert(posix.listen("127.0.0.1", 8080))
while true do
	srv:serve(l:accept())
end

local c = client.new()
local res, err = c:get("http://127.0.0.1:8080/x")
```

https and TLS servers use libtls: OpenBSD base, or libretls on Linux
(Debian `libtls-dev`, Gentoo `dev-libs/libretls`). The rock and the
meson build make the TLS module only where libtls links. See DESIGN.md.

```sh
luarocks --lua-version 5.4 install --dev mhttp
```

```lua
local l = assert(loop:listen("::", 443, { tls = { cert = "cert.pem", key = "key.pem" } }))
local res = client.new():get("https://example.com/")
```

## Programs

- `mhttpd [-l] [-c cgi-dir] [dir]` serves a directory, and CGI programs,
  at once. `mhttpd -h` lists the options.
- `mhttpx -f config` is a reverse proxy and file server configured by a
  Lua file, in the place of relayd or nginx. The config lists sites by
  host. In a site, the most specific path pattern answers, so the order
  of the rules does not matter. Actions are proxy (with WebSockets,
  over TCP or a unix socket), static files, CGI, Lua handlers in the
  worker, redirects and fixed replies; header changes add up
  by path. http redirects to https by itself, and serves ACME
  challenges. The access log goes to stdout, syslog, files that can be
  rotated, or a Lua function, set per site and path. TLS picks a cert
  per SNI name. A root master binds the
  ports and unix sockets, and a worker drops to a user and, on OpenBSD,
  pledges. SIGHUP
  reloads the config and the certs without dropping connections. See
  `mhttpx.conf.example`. `contrib/openbsd/mhttpx` is an rc.d script.

The handlers they use are modules: `mhttp.static`, `mhttp.proxy` and
`mhttp.cgi`. `mhttp.metrics` keeps Prometheus metrics: counters, gauges
and histograms for any program, and `instrument` adds request metrics to
any handler. The proxy and CGI handlers add their own when given a
registry. `mhttpx` serves them on a `metrics` listener, and `mhttpd -M`
on an address of its own.

The parser on its own:

```lua
local parse = require("mhttp.parse")
local wire = require("mhttp.wire")

local p = parse.new("request")
p:feed(bytes)
while true do
	local ev, err = p:next()
	if not ev then break end   -- nil: needs bytes; nil, err: error
	-- ev.type: "head", "data", "trailers", "done"
end

local head = wire.response_head(200, nil, { ["Content-Length"] = 2 })
```

See `DESIGN.md` for the layers and the plans for the server, the
client, TLS, proxies and cookies.

## Build and test

```
meson setup build
meson test -C build
meson test -C build --benchmark -v
```

or `luarocks make` and `luarocks test`. `bench/rps.lua` takes a mode:
`fork` (a process per connection), `event` (one event loop), `poll`
(one `mhttp.io.poll` loop) or
`reuseport` (several event loops on one port). `fuzz/parse.lua` is an lfuzz
target. `test/event.lua` and the event benchmarks need the `event`
library; set `MHTTP_EVENT_LUA` to its lua directory when it is not at
`../event/lua`.
