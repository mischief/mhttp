-- SPDX-License-Identifier: ISC
-- mhttpx end to end: sites, paths, http and https listeners, the master
-- and its worker, SIGHUP reload and SIGTERM. The daemon runs in a child
-- process.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path
if os.getenv("MHTTP_CPATH") then
	package.cpath = os.getenv("MHTTP_CPATH") .. "/?.so;" .. package.cpath
end

local tap = require("tap")
local posix = require("mhttp.io.posix")
local server = require("mhttp.server")
local client = require("mhttp.client")
local daemon = require("mhttpx.daemon")
local unistd = require("posix.unistd")
local signal = require("posix.signal")
local wait = require("posix.sys.wait")
local ptime = require("posix.time")

local function free_port()
	local l = assert(posix.listen("127.0.0.1", 0))
	local p = l:port()
	l:close()
	return p
end

local function sleep(s)
	ptime.nanosleep({ tv_sec = math.floor(s), tv_nsec = math.floor((s % 1) * 1e9) })
end

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p " .. dir .. "/www/nlos " .. dir .. "/acme"))
local function put(name, data)
	local f = assert(io.open(dir .. "/" .. name, "wb"))
	f:write(data)
	f:close()
end
put("www/index.html", "home\n")
put("www/nlos/app.wasm", "\0asm")
put("acme/token", "proof")

local has_tls = pcall(require, "mhttp.tls.libtls")
	and os.execute("command -v openssl >/dev/null")
if has_tls then
	assert(os.execute(("cd %s && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 "
		.. "-nodes -keyout t.key -out t.crt -days 2 -subj /CN=localhost >/dev/null 2>&1"):format(dir)))
end

-- Checks the config loader on one bad config.
local function bad(text, want, name)
	put("bad.lua", text)
	local cfg, err = daemon.load(dir .. "/bad.lua")
	tap.ok(not cfg and tostring(err):find(want, 1, true), name .. ": " .. tostring(err))
end
bad([[return { listen = { http = "127.0.0.1:1" }, sites = { { host = "a", prxy = "http://x" } } }]],
	"unknown field prxy", "unknown field")
bad([[return { listen = { http = "127.0.0.1:1" }, sites = { { host = "a", proxy = "x", static = "/" } } }]],
	"one action", "two actions")
bad([[return { listen = { http = "127.0.0.1:1" }, sites = { { host = "a", status = 200 },
	{ host = "A", status = 201 } } }]], "in two sites", "duplicate host")
bad([[return { listen = { https = "127.0.0.1:1" }, sites = {} }]], "https needs certs", "no certs")
bad([[return { listen = { http = "127.0.0.1:1" }, sites = { { status = 200 } } }]], "no host", "no host")

-- An upstream that echoes what it got.
local up_port = free_port()
local up_pid = assert(unistd.fork())
if up_pid == 0 then
	local l = assert(posix.listen("127.0.0.1", up_port))
	local srv = server.new({ handler = function(req, res)
		res:send(200, ("%s %s xff=%s proto=%s host=%s"):format(req.method, req.target,
			req.headers:get("x-forwarded-for") or "", req.headers:get("x-forwarded-proto") or "",
			req.headers:get("host") or ""))
	end })
	while true do
		local s = l:accept()
		if s then
			srv:serve(s)
		end
	end
end

-- The same upstream on a unix socket.
local sock = dir .. "/up.sock"
local unix_pid = assert(unistd.fork())
if unix_pid == 0 then
	local socket = require("posix.sys.socket")
	local fd = assert(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0))
	assert(socket.bind(fd, { family = socket.AF_UNIX, path = sock }))
	assert(socket.listen(fd, 16))
	local srv = server.new({ handler = function(req, res)
		res:send(200, ("unix %s host=%s"):format(req.target, req.headers:get("host") or ""))
	end })
	while true do
		local c = socket.accept(fd)
		if c then
			srv:serve(posix.stream(c))
		end
	end
end

-- A handler module, loaded by name.
put("mhttpx_test_app.lua", [[
return { new = function(env)
	return function(req, res)
		return res:send(200, "module " .. req.path .. " " .. type(env.spawn))
	end
end }
]])
package.path = dir .. "/?.lua;" .. package.path

local port, sport = free_port(), free_port()
local conf = dir .. "/mhttpx.lua"
local function config(note)
	put("mhttpx.lua", ([[
local up = "http://127.0.0.1:%d"
local isolate = {
	["Cross-Origin-Opener-Policy"] = "same-origin",
	["Cross-Origin-Embedder-Policy"] = "require-corp",
}
return {
	access_log = %q,
	drain = 2,
	listen = { http = "127.0.0.1:%d", https = %s },
	certs = { { %q, %q } },
	acme = %q,
	default = 404,
	sites = {
		{ host = "app.test", proxy = up },
		{ host = { "files.test", "www.files.test" },
			static = %q,
			["/nlos/*"] = { headers = isolate },
			["/nlos/*.wasm"] = { headers = { ["Content-Type"] = "application/wasm" } },
			["/api/*"] = { proxy = up },
			["/api/exact"] = { status = 200, body = "exact" },
			["/api/*/deeper/*"] = { status = 200, body = "deeper" },
		},
		{ host = "*.wild.test", status = 200, body = "wild" },
		{ host = "*.test", status = 200, body = "any test" },
		{ host = "one.wild.test", status = 200, body = "exact wins" },
		{ host = "plain.test", https = false, status = 200, body = "plain" },
		{ host = "both.test", http = "serve", status = 200, body = "both" },
		{ host = "note.test", status = 200, body = %q },
		{ host = "unix.test", proxy = "unix:" .. %q },
		{ host = "fn.test", handler = function(req, res) return res:send(200, "fn " .. req.path) end },
		{ host = "mod.test", ["/app/*"] = { handler = "mhttpx_test_app" } },
	},
}
]]):format(up_port, dir .. "/access.log", port, has_tls and ("%q"):format("127.0.0.1:" .. sport) or "nil",
		dir .. "/t.crt", dir .. "/t.key", dir .. "/acme", dir .. "/www", note, sock))
end
config("first")
local cfg, lerr = daemon.load(conf)
tap.ok(cfg, "the test config loads: " .. tostring(lerr))

local pid = assert(unistd.fork())
if pid == 0 then
	local ok = daemon.run(conf)
	unistd._exit(ok and 0 or 1)
end

local c = client.new({ timeout = 5, tls = { verify = false } })
local function get(scheme, host, path)
	local p = scheme == "https" and sport or port
	for _ = 1, 50 do
		local res, err = c:request({ url = ("%s://127.0.0.1:%d%s"):format(scheme, p, path),
			headers = { { "Host", host } } })
		if res or err.kind ~= "connect" then
			return res, err
		end
		sleep(0.1)
	end
end
-- The site tests go over https when there is TLS, and over http then.
local S = has_tls and "https" or "http"
if not has_tls then
	tap.skip("https listener", "no libtls or no openssl")
end

tap.try("mhttpx", function()
	local res = assert(get(S, "app.test", "/x?y=1"))
	tap.is(res.body, ("GET /x?y=1 xff=127.0.0.1 proto=%s host=app.test"):format(S), "proxy")
	res = assert(get(S, "APP.test:443", "/"))
	tap.is(res.status, 200, "host match ignores case and port")
	tap.is(assert(get(S, "files.test", "/")).body, "home\n", "static")
	tap.is(assert(get(S, "www.files.test", "/")).body, "home\n", "second host of a site")

	res = assert(get(S, "files.test", "/nlos/app.wasm"))
	tap.is(res.headers:get("content-type"), "application/wasm", "the most specific header wins")
	tap.is(res.headers:get("cross-origin-opener-policy"), "same-origin", "headers add up")
	res = assert(get(S, "app.test", "/nlos/x"))
	tap.is(res.headers:get("cross-origin-opener-policy"), nil, "paths stay in their site")

	tap.ok(assert(get(S, "files.test", "/api/z")).body:find("^GET /api/z "), "a path beats the site")
	tap.is(assert(get(S, "files.test", "/api/exact")).body, "exact", "an exact path wins")
	tap.is(assert(get(S, "files.test", "/api/a/deeper/b")).body, "deeper", "longer pattern wins")

	tap.is(assert(get(S, "one.wild.test", "/")).body, "exact wins", "exact host beats wildcard")
	tap.is(assert(get(S, "two.wild.test", "/")).body, "wild", "longer wildcard wins")
	tap.is(assert(get(S, "x.test", "/")).body, "any test", "wildcard")
	tap.is(assert(get(S, "nowhere.example", "/")).status, 404, "default")
	tap.is(assert(get(S, "note.test", "/")).body, "first", "before reload")
	tap.is(assert(get(S, "unix.test", "/u?v=1")).body, "unix /u?v=1 host=unix.test", "unix socket upstream")
	tap.is(assert(get(S, "fn.test", "/z")).body, "fn /z", "handler function")
	tap.is(assert(get(S, "mod.test", "/app/q")).body, "module /app/q function", "handler module")
	bad([[return { listen = { http = "127.0.0.1:1" }, sites = { { host = "a", handler = "no.such.mod" } } }]],
		"no module no.such.mod", "missing handler module")

	if has_tls then
		res = assert(get("http", "files.test", "/a?b=c"))
		tap.is(res.status, 301, "http redirects")
		tap.is(res.headers:get("location"), ("https://files.test:%d/a?b=c"):format(sport),
			"redirect keeps the https port and target")
		tap.is(assert(get("http", "nowhere.example", "/")).status, 301, "default redirects")
		tap.is(assert(get("http", "plain.test", "/")).body, "plain", "https = false serves http")
		tap.is(assert(get("https", "plain.test", "/")).status, 404, "https = false is not on https")
		tap.is(assert(get("http", "both.test", "/")).body, "both", "http = \"serve\"")
		tap.is(assert(get("https", "both.test", "/")).body, "both", "and https")
	end
	tap.is(assert(get("http", "files.test", "/.well-known/acme-challenge/token")).body, "proof",
		"acme directory")

	config("second")
	signal.kill(pid, signal.SIGHUP)
	local body
	for _ = 1, 50 do
		sleep(0.1)
		c:close()
		local r = get(S, "note.test", "/")
		body = r and r.body
		if body == "second" then
			break
		end
	end
	tap.is(body, "second", "SIGHUP loads the new config")

	local f = io.open(dir .. "/access.log")
	local logtext = f and f:read("a") or ""
	if f then
		f:close()
	end
	tap.ok(logtext:find('"GET /x?y=1 HTTP/1.1" 200', 1, true), "access log")
end)

c:close()
signal.kill(pid, signal.SIGTERM)
local done = false
for _ = 1, 50 do
	local p = wait.wait(pid, wait.WNOHANG)
	if p == pid then
		done = true
		break
	end
	sleep(0.1)
end
tap.ok(done, "SIGTERM stops the master")
if not done then
	signal.kill(pid, signal.SIGKILL)
end
for _, p in ipairs({ up_pid, unix_pid }) do
	signal.kill(p, signal.SIGKILL)
	wait.wait(p)
end
os.execute("rm -rf " .. dir)
tap.done()
