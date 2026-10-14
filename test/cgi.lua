-- SPDX-License-Identifier: ISC
-- mhttp.cgi with small shell programs, under mhttp.io.poll.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local mpoll = require("mhttp.io.poll")
local server = require("mhttp.server")
local client = require("mhttp.client")
local router = require("mhttp.router")
local cgi = require("mhttp.cgi")
local stat = require("posix.sys.stat")

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p " .. dir .. "/sub"))
local function prog(name, body, mode)
	local f = assert(io.open(dir .. "/" .. name, "w"))
	f:write("#!/bin/sh\n", body, "\n")
	f:close()
	stat.chmod(dir .. "/" .. name, mode or 493)
end
prog("env.cgi", [[printf 'Content-Type: text/plain\r\n\r\n'; env | sort]])
prog("echo.cgi", [[printf 'Content-Type: application/octet-stream\n\n'; cat]])
prog("status.cgi", [[printf 'Status: 404 Nope\nContent-Type: text/plain\n\ngone\n']])
prog("redirect.cgi", [[printf 'Location: /elsewhere\n\n']])
prog("bad.cgi", [[printf 'this is not a header\n\nbody\n']])
prog("big.cgi", [[printf 'Content-Type: text/plain\n\n'; head -c 1048576 /dev/zero | tr '\0' 'x']])
prog("slow.cgi", [[sleep 3; printf 'Content-Type: text/plain\n\nlate\n']])
prog("nohead.cgi", [[exit 0]])
prog("fds.cgi", [[printf 'Content-Type: text/plain\n\n'; ls /dev/fd | sort -n | tr '\n' ' ']])
prog("sub/inner.cgi", [[printf 'Content-Type: text/plain\n\n%s|%s' "$SCRIPT_NAME" "$PATH_INFO"]])
prog("plain.txt", "not a program", 420)

local loop = mpoll.new()
local r = router.new()
r:any("/cgi/*path", cgi.handler({
	root = dir,
	prefix = "/cgi",
	timeout = 1,
	stream = function(fd)
		return loop:stream(fd)
	end,
	spawn = function(fn)
		loop:spawn(fn)
	end,
	sleep = function(s)
		loop:sleep(s)
	end,
}))
local l = assert(loop:listen("127.0.0.1", 0))
loop:serve(l, server.new({ handler = r:handler(), on_error = function(e)
	io.stderr:write(e, "\n")
end }))
local base = ("http://127.0.0.1:%d/cgi"):format(l:port())

loop:spawn(function()
	local c = client.new({ timeout = 10, connect = function(h, p, o)
		return loop:connect(h, p, o)
	end })
	local function req(t)
		t.url = base .. t.path
		local res, err = c:request(t)
		assert(res, err and err.message)
		return res
	end

	local res = req({ path = "/env.cgi/extra/path?x=1&y=2", headers = {
		{ "X-Thing", "a" }, { "Proxy", "http://evil" }, { "Cookie", "c=1" } } })
	tap.is(res.status, 200, "env")
	local env = {}
	for k, v in res.body:gmatch("([%w_]+)=([^\n]*)") do
		env[k] = v
	end
	tap.is(env.GATEWAY_INTERFACE, "CGI/1.1", "GATEWAY_INTERFACE")
	tap.is(env.REQUEST_METHOD, "GET", "REQUEST_METHOD")
	tap.is(env.QUERY_STRING, "x=1&y=2", "QUERY_STRING")
	tap.is(env.SCRIPT_NAME, "/cgi/env.cgi", "SCRIPT_NAME")
	tap.is(env.PATH_INFO, "/extra/path", "PATH_INFO")
	tap.is(env.HTTP_X_THING, "a", "HTTP_ variables")
	tap.is(env.HTTP_PROXY, nil, "no HTTP_PROXY")
	tap.is(env.REMOTE_ADDR, "127.0.0.1", "REMOTE_ADDR")
	tap.is(env.HOME, nil, "no variables from the server")

	local big = ("z"):rep(300000)
	res = req({ method = "POST", path = "/echo.cgi", body = big })
	tap.is(res.body, big, "body in, body out")
	res = req({ path = "/status.cgi" })
	tap.is(res.status, 404, "Status")
	tap.is(res.reason, "Nope", "reason")
	tap.is(res.body, "gone\n", "Status body")
	res = req({ path = "/redirect.cgi" })
	tap.is(res.status, 302, "Location gives 302")
	tap.is(res.headers:get("location"), "/elsewhere", "Location")
	tap.is(req({ path = "/bad.cgi" }).status, 502, "bad header")
	res = req({ path = "/big.cgi" })
	tap.is(#res.body, 1 << 20, "1 MiB of output")
	tap.is(req({ path = "/slow.cgi" }).status, 504, "timeout")
	tap.is(req({ path = "/nohead.cgi" }).status, 502, "no output")
	tap.is(req({ path = "/plain.txt" }).status, 404, "not executable")
	tap.is(req({ path = "/nosuch.cgi" }).status, 404, "missing")
	tap.is(req({ path = "/.hidden" }).status, 404, "dot file")
	res = req({ path = "/sub/inner.cgi/x/" })
	tap.is(res.body, "/cgi/sub/inner.cgi|/x/", "nested program and PATH_INFO")
	res = req({ path = "/fds.cgi" })
	tap.ok(res.body:match("^0 1 2 3? ?$"), "the program gets only stdin, stdout, stderr")
	if not res.body:match("^0 1 2 3? ?$") then
		tap.diag(res.body)
	end
	c:close()
	l:close()
end)
loop:run()
os.execute("rm -rf " .. dir)
tap.done()
