-- SPDX-License-Identifier: ISC
-- mhttpx end to end: rules, the master and its worker, SIGHUP reload
-- and SIGTERM. The daemon runs in a child process.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path
if os.getenv("MHTTP_CPATH") then
	package.cpath = os.getenv("MHTTP_CPATH") .. "/?.so;" .. package.cpath
end

local tap = require("tap")
local posix = require("mhttp.io.posix")
local server = require("mhttp.server")
local client = require("mhttp.client")
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
assert(os.execute("mkdir -p " .. dir .. "/www/nlos"))
local function put(name, data)
	local f = assert(io.open(dir .. "/" .. name, "wb"))
	f:write(data)
	f:close()
end
put("www/index.html", "home\n")
put("www/nlos/app.wasm", "\0asm")

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

local port = free_port()
local conf = dir .. "/mhttpx.lua"
local function config(note)
	put("mhttpx.lua", ([[
local isolate = {
	["Cross-Origin-Opener-Policy"] = "same-origin",
	["Cross-Origin-Embedder-Policy"] = "require-corp",
}
return {
	access_log = %q,
	drain = 2,
	servers = {
		{
			listen = { "127.0.0.1:%d" },
			proto = "https",
			rules = {
				{ path = "/nlos/*", response_headers = isolate },
				{ path = "/nlos/*.wasm", response_headers = { ["Content-Type"] = "application/wasm" } },
				{ host = "app.test", proxy = "http://127.0.0.1:%d" },
				{ host = "plain.test", path = "/.well-known/acme-challenge/**", status = 200, body = "acme" },
				{ host = "plain.test", redirect = "https://{host}{target}" },
				{ host = "files.test", static = %q },
				{ host = "note.test", status = 200, body = %q },
				{ status = 421, body = "unknown host" },
			},
		},
	},
}
]]):format(dir .. "/access.log", port, up_port, dir .. "/www", note))
end
config("first")

local pid = assert(unistd.fork())
if pid == 0 then
	local ok, err = require("mhttpx.daemon").run(conf)
	unistd._exit(ok and 0 or 1)
end

local c = client.new({ timeout = 5 })
local function get(host, path, h)
	local headers = { { "Host", host } }
	for _, f in ipairs(h or {}) do
		headers[#headers + 1] = f
	end
	for _ = 1, 50 do
		local res, err = c:request({ url = ("http://127.0.0.1:%d%s"):format(port, path),
			headers = headers })
		if res or err.kind ~= "connect" then
			return res, err
		end
		sleep(0.1)
	end
end

tap.try("mhttpx", function()
	local res = assert(get("app.test", "/x?y=1", { { "X-Forwarded-For", "10.1.1.1" } }))
	tap.is(res.body, "GET /x?y=1 xff=10.1.1.1, 127.0.0.1 proto=https host=app.test", "proxy")
	res = assert(get("APP.test:443", "/"))
	tap.is(res.status, 200, "host match ignores case and port")
	res = assert(get("files.test", "/"))
	tap.is(res.body, "home\n", "static")
	res = assert(get("files.test", "/nlos/app.wasm"))
	tap.is(res.headers:get("content-type"), "application/wasm", "a later header rule wins")
	tap.is(res.headers:get("cross-origin-opener-policy"), "same-origin", "header rules add up")
	res = assert(get("app.test", "/nlos/x"))
	tap.is(res.headers:get("cross-origin-embedder-policy"), "require-corp",
		"header rules apply to a proxy")
	res = assert(get("plain.test", "/.well-known/acme-challenge/abc"))
	tap.is(res.body, "acme", "acme rule")
	res = assert(get("plain.test", "/a?b=c"))
	tap.is(res.status, 301, "redirect")
	tap.is(res.headers:get("location"), "https://plain.test/a?b=c", "redirect target")
	res = assert(get("nowhere.test", "/"))
	tap.is(res.status, 421, "last rule catches the rest")
	tap.is(assert(get("note.test", "/")).body, "first", "before reload")

	config("second")
	signal.kill(pid, signal.SIGHUP)
	local body
	for _ = 1, 50 do
		sleep(0.1)
		c:close()
		local r = get("note.test", "/")
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
signal.kill(up_pid, signal.SIGKILL)
wait.wait(up_pid)
os.execute("rm -rf " .. dir)
tap.done()
