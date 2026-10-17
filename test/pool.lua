-- SPDX-License-Identifier: ISC
-- The client pool: idle connections that the server closed, that are too
-- old, or that fail on reuse do not fail a request.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local mpoll = require("mhttp.io.poll")
local server = require("mhttp.server")
local client = require("mhttp.client")
local proxy = require("mhttp.proxy")
local clock = require("mhttp.clock")

local loop = mpoll.new()

-- Serves one connection. mode.close closes it after each response;
-- mode.hangup closes it, with no response, at that request number.
local function serve(s, mode, st)
	local buf, n = "", 0
	while true do
		local e = buf:find("\r\n\r\n", 1, true)
		local len = e and tonumber(buf:sub(1, e):lower():match("content%-length: *(%d+)")) or 0
		if e and #buf >= e + 3 + len then
			buf = buf:sub(e + 4 + len)
			n = n + 1
			st.requests = st.requests + 1
			if mode.hangup and n >= mode.hangup then
				return
			end
			if mode.delay then
				loop:sleep(mode.delay)
			end
			s:write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
			if mode.close then
				return
			end
		else
			local d = s:read(4096, clock.after(5))
			if not d then
				return
			end
			buf = buf .. d
		end
	end
end

-- A raw upstream. It counts connections, requests, and closed connections.
local function upstream(mode)
	local l = assert(loop:listen("127.0.0.1", 0))
	local st = { conns = 0, requests = 0, closed = 0, l = l }
	loop:spawn(function()
		while true do
			local s = l:accept()
			if not s then
				return
			end
			st.conns = st.conns + 1
			loop:spawn(function()
				serve(s, mode, st)
				s:close()
				st.closed = st.closed + 1
			end)
		end
	end)
	st.url = ("http://127.0.0.1:%d/"):format(l:port())
	return st
end

local function new(opts)
	opts = opts or {}
	opts.connect = function(h, p, o)
		return loop:connect(h, p, o)
	end
	opts.timeout = 5
	return client.new(opts)
end

local function post(c, u)
	return c:request({ url = u, method = "POST", body = "x" })
end

loop:spawn(function()
	-- The server closes the connection after the response. A POST is not
	-- sent again on a failure, so it shows that the client did not reuse it.
	local up = upstream({ close = true })
	local c = new()
	tap.is(post(c, up.url).status, 200, "closed: first request")
	loop:sleep(0.05)
	local res, err = post(c, up.url)
	tap.is(res and res.status, 200, "closed: a connection the server closed is not reused")
	if err then
		tap.diag(err.message)
	end
	tap.is(up.conns, 2, "closed: the second request has a new connection")
	c:close()
	up.l:close()

	-- An idle connection older than pool_timeout is closed.
	up = upstream({})
	c = new({ pool_timeout = 0.1 })
	tap.is(post(c, up.url).status, 200, "old: first request")
	loop:sleep(0.2)
	tap.is(post(c, up.url).status, 200, "old: second request")
	tap.is(up.conns, 2, "old: the old connection is not reused")
	loop:sleep(0.05)
	tap.is(up.closed, 1, "old: the client closed the old connection")
	c:close()
	up.l:close()

	-- prune closes old idle connections to an origin with no more requests.
	up = upstream({})
	c = new({ pool_timeout = 0.1 })
	tap.is(post(c, up.url).status, 200, "prune: first request")
	c:prune()
	loop:sleep(0.05)
	tap.is(up.closed, 0, "prune: a new idle connection stays open")
	loop:sleep(0.1)
	c:prune()
	loop:sleep(0.05)
	tap.is(up.closed, 1, "prune: an old idle connection is closed")
	tap.is(next(c.idle), nil, "prune: the pool is empty")
	c:close()
	up.l:close()

	-- Two idle connections that look alive but fail on the next request.
	-- The retry uses a new connection, not the other idle one.
	up = upstream({ hangup = 2 })
	c = new()
	local r1 = assert(c:request({ url = up.url, stream = true }))
	local r2 = assert(c:request({ url = up.url, stream = true }))
	while r1:read() do end
	while r2:read() do end
	tap.is(up.conns, 2, "retry: two connections in the pool")
	res, err = c:get(up.url)
	tap.is(res and res.status, 200, "retry: the request works")
	if err then
		tap.diag(err.message)
	end
	tap.is(up.conns, 3, "retry: the retry has a new connection")
	c:close()
	up.l:close()

	-- The proxy, when the upstream closed every idle connection.
	up = upstream({ close = true, delay = 0.05 })
	local pl = assert(loop:listen("127.0.0.1", 0))
	loop:serve(pl, server.new({ on_error = function() end, handler = proxy.handler({
		upstream = up.url:sub(1, -2),
		connect = function(h, p, o)
			return loop:connect(h, p, o)
		end,
	}) }))
	local purl = ("http://127.0.0.1:%d/"):format(pl:port())
	local got = 0
	for _ = 1, 2 do
		loop:spawn(function()
			local pc = new()
			if pc:get(purl).status == 200 then
				got = got + 1
			end
			pc:close()
		end)
	end
	while got < 2 do
		loop:sleep(0.01)
	end
	loop:sleep(0.05)
	c = new()
	res = c:get(purl)
	tap.is(res and res.status, 200, "proxy: GET after the upstream closed its connections")
	res = post(c, purl)
	tap.is(res and res.status, 200, "proxy: POST after the upstream closed its connections")
	c:close()
	pl:close()
	up.l:close()
end)

loop:run()
tap.done()
