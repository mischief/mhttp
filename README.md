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
