-- SPDX-License-Identifier: ISC
-- mhttp.proxy between a client and an upstream, all under mhttp.io.poll.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local mpoll = require("mhttp.io.poll")
local server = require("mhttp.server")
local client = require("mhttp.client")
local proxy = require("mhttp.proxy")
local clock = require("mhttp.clock")

local loop = mpoll.new()
local quiet = function() end
local BIG = ("0123456789abcdef"):rep(1 << 16)

local function upstream(req, res)
	if req.path == "/headers" then
		local t = {}
		for _, name, value in req.headers:each() do
			t[#t + 1] = name:lower() .. ": " .. value
		end
		return res:send(200, table.concat(t, "\n"), {
			{ "X-Up", "1" }, { "Connection", "x-hop" }, { "X-Hop", "drop me" },
			{ "Keep-Alive", "timeout=5" },
		})
	elseif req.path == "/big" then
		res:start(200)
		for i = 1, #BIG, 50000 do
			res:write(BIG:sub(i, i + 49999))
		end
		return res:finish()
	elseif req.path == "/echo" then
		return res:send(200, req:body(8 << 20))
	elseif req.path == "/slow" then
		loop:sleep(2)
		return res:send(200, "late")
	elseif req.path == "/ws" then
		res:start(101, { { "Upgrade", "echo" }, { "Connection", "upgrade" } })
		local s, rest = res:hijack()
		local buf = rest or ""
		while true do
			if buf ~= "" then
				s:write(buf:upper())
				buf = ""
			end
			local d = s:read(4096, clock.after(5))
			if not d then
				break
			end
			buf = d
		end
		s:close()
		return
	end
	return res:send(404, "no")
end

local ul = assert(loop:listen("127.0.0.1", 0))
loop:serve(ul, server.new({ handler = upstream, on_error = quiet }))
local up_base = ("http://127.0.0.1:%d"):format(ul:port())

-- An upstream that promises more than it sends.
local tl = assert(loop:listen("127.0.0.1", 0))
loop:spawn(function()
	while true do
		local s = tl:accept()
		if not s then
			break
		end
		loop:spawn(function()
			s:read(4096, clock.after(5))
			s:write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nonly ten b")
			s:close()
		end)
	end
end)

local errors = 0
local h = proxy.handler({
	upstream = function(req)
		if req.path == "/cut" then
			return ("http://127.0.0.1:%d"):format(tl:port())
		elseif req.path == "/none" then
			return nil, 503
		elseif req.path == "/down" then
			return "http://127.0.0.1:1"
		end
		return up_base
	end,
	connect = function(host, port, o)
		return loop:connect(host, port, o)
	end,
	read_idle = 1,
	proto = "https",
	spawn = function(fn)
		loop:spawn(fn)
	end,
	response_headers = function(req, _, _, rh)
		if req.path:find("^/headers") then
			rh:set("X-Rule", "set")
		end
	end,
	on_error = function()
		errors = errors + 1
	end,
})
local pl = assert(loop:listen("127.0.0.1", 0))
loop:serve(pl, server.new({ handler = h, on_error = quiet }))
local base = ("http://127.0.0.1:%d"):format(pl:port())

loop:spawn(function()
	local c = client.new({ timeout = 10, connect = function(host, port, o)
		return loop:connect(host, port, o)
	end })
	local res = assert(c:request({ url = base .. "/headers?q=1", headers = {
		{ "Host", "site.example" }, { "X-Forwarded-For", "10.9.9.9" },
		{ "Connection", "x-private" }, { "X-Private", "secret" }, { "TE", "trailers" },
	} }))
	tap.is(res.status, 200, "get through the proxy")
	local b = res.body
	tap.ok(b:find("host: site.example", 1, true), "Host is kept")
	tap.ok(b:find("x-forwarded-for: 10.9.9.9, 127.0.0.1", 1, true), "X-Forwarded-For appended")
	tap.ok(b:find("x-forwarded-proto: https", 1, true), "X-Forwarded-Proto")
	tap.ok(not b:find("x-private", 1, true) and not b:find("^te:") and not b:find("\nte:"),
		"request hop-by-hop fields dropped")
	tap.is(res.headers:get("x-up"), "1", "response field kept")
	tap.is(res.headers:get("x-hop"), nil, "response field named in Connection dropped")
	tap.is(res.headers:get("keep-alive"), nil, "Keep-Alive dropped")
	tap.is(res.headers:get("x-rule"), "set", "response_headers rule")

	res = assert(c:get(base .. "/big"))
	tap.ok(res.body == BIG, "1 MiB chunked download")
	res = assert(c:request({ method = "POST", url = base .. "/echo", body = BIG }))
	tap.ok(res.body == BIG, "1 MiB upload")
	local parts, i = {}, 0
	res = assert(c:request({ method = "POST", url = base .. "/echo", body = function()
		i = i + 1
		if i <= 4 then
			return ("part%d;"):format(i)
		end
	end }))
	tap.is(res.body, "part1;part2;part3;part4;", "chunked upload")
	_ = parts
	res = assert(c:request({ method = "HEAD", url = base .. "/big" }))
	tap.is(res.status, 200, "head")

	res = assert(c:get(base .. "/none"))
	tap.is(res.status, 503, "upstream function picks a status")
	res = assert(c:get(base .. "/down"))
	tap.is(res.status, 502, "connection refused gives 502")
	res = assert(c:get(base .. "/slow"))
	tap.is(res.status, 504, "slow upstream gives 504")
	local r2, err = c:get(base .. "/cut")
	tap.ok(not r2 and err, "a cut upstream body cuts the client body")

	-- WebSocket style upgrade, with data sent right after the head.
	local s = assert(loop:connect("127.0.0.1", pl:port()))
	s:write("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\nhello")
	local got = ""
	local deadline = clock.after(5)
	while not got:find("HELLO", 1, true) do
		local d = s:read(4096, deadline)
		if not d then
			break
		end
		got = got .. d
	end
	tap.ok(got:find("^HTTP/1.1 101"), "upgrade: 101")
	tap.ok(got:find("\r\n\r\nHELLO"), "upgrade: data right after the head")
	s:write("again")
	local more = s:read(4096, clock.after(5))
	tap.is(more, "AGAIN", "upgrade: tunnel both ways")
	s:close()

	tap.ok(errors >= 3, "on_error for upstream failures")
	c:close()
	ul:close()
	tl:close()
	pl:close()
end)

local t = clock.now()
loop:run()
tap.ok(clock.now() - t < 15, "done in time")
tap.done()
