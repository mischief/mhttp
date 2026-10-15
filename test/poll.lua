-- SPDX-License-Identifier: ISC
-- The poll scheduler, and end to end in one process under it.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local mpoll = require("mhttp.io.poll")
local server = require("mhttp.server")
local client = require("mhttp.client")
local clock = require("mhttp.clock")
local coro = require("mhttp.coro")
local unistd = require("posix.unistd")

-- Sleeps end in deadline order.
do
	local loop = mpoll.new()
	local order = {}
	for _, d in ipairs({ 0.03, 0.01, 0.02 }) do
		loop:spawn(function()
			loop:sleep(d)
			order[#order + 1] = d
		end)
	end
	local t = clock.now()
	loop:run()
	tap.is(table.concat(order, " "), "0.01 0.02 0.03", "sleeps wake in order")
	tap.ok(clock.now() - t < 0.5, "sleeps run at the same time")
end

-- A wait times out; a write wakes a reader; a close wakes a waiter.
do
	local loop = mpoll.new()
	local r, w = unistd.pipe()
	local rs, ws = loop:stream(r), loop:stream(w)
	local r2, w2 = unistd.pipe()
	local rs2 = loop:stream(r2)
	local got = {}
	loop:spawn(function()
		got.timeout = select(2, rs:read(10, clock.after(0.02)))
		got.data = rs:read(10, clock.after(2))
	end)
	loop:spawn(function()
		loop:sleep(0.05)
		ws:write("hi")
	end)
	loop:spawn(function()
		got.closed = select(2, rs2:read(10))
	end)
	loop:spawn(function()
		loop:sleep(0.01)
		rs2:close()
	end)
	loop:run()
	tap.is(got.timeout, "timeout", "read times out")
	tap.is(got.data, "hi", "read wakes on data")
	tap.is(got.closed, "closed", "close wakes a waiter")
	rs:close()
	ws:close()
	unistd.close(w2)
end

-- A task that fails does not stop the others. A raw yield is an error.
-- Yields of mhttp.coro coroutines in a task reach the loop.
do
	local errs = 0
	local loop = mpoll.new({ on_error = function()
		errs = errs + 1
	end })
	local done, nested = false, nil
	loop:spawn(function()
		error("boom")
	end)
	loop:spawn(function()
		coroutine.yield()
	end)
	loop:spawn(function()
		local gen = coro.wrap(function()
			loop:sleep(0.01)
			coro.yield("a")
			loop:sleep(0.01)
			coro.yield("b")
		end)
		nested = gen() .. gen()
		done = true
	end)
	loop:run()
	tap.is(errs, 2, "failed tasks go to on_error")
	tap.ok(done, "other tasks go on")
	tap.is(nested, "ab", "nested coroutines sleep under the loop")
end

-- A wait outside a task blocks, as in mhttp.io.posix.
do
	local loop = mpoll.new()
	local r, w = unistd.pipe()
	local rs = loop:stream(r)
	unistd.write(w, "x")
	tap.is(rs:read(10, clock.after(1)), "x", "read outside a task")
	tap.is(select(2, rs:read(10, clock.after(0.01))), "timeout", "timeout outside a task")
	rs:close()
	unistd.close(w)
end

-- serve with max: one connection at a time; suspend and wake.
do
	local loop = mpoll.new()
	local l = assert(loop:listen("127.0.0.1", 0))
	local srv = server.new({ handler = require("app"), on_error = function() end })
	loop:serve(l, srv, { max = 1 })
	local got = {}
	loop:spawn(function()
		local req = "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n"
		local a = assert(loop:connect("127.0.0.1", l:port()))
		assert(a:write(req))
		got.a = a:read(4096, clock.after(2))
		local b = assert(loop:connect("127.0.0.1", l:port()))
		assert(b:write(req))
		got.wait = select(2, b:read(4096, clock.after(0.2)))
		a:close()
		got.b = b:read(4096, clock.after(2))
		b:close()
		l:close()
	end)
	loop:run()
	tap.ok(got.a and got.a:find("^HTTP/1.1 200"), "max: first connection served")
	tap.is(got.wait, "timeout", "max: second connection waits")
	tap.ok(got.b and got.b:find("^HTTP/1.1 200"), "max: second served after the first ends")
	tap.is(loop.count, 0, "max: every task ends")
end

-- max_run: a task that never yields fails, and the others go on.
do
	local errs = {}
	local loop = mpoll.new({ max_run = 0.3, on_error = function(e)
		errs[#errs + 1] = e
	end })
	local ticks = 0
	loop:spawn(function()
		while true do
			local x = 0
			for i = 1, 1000 do
				x = x + i
			end
		end
	end)
	loop:spawn(function()
		for _ = 1, 3 do
			loop:sleep(0.05)
			ticks = ticks + 1
		end
	end)
	loop:run()
	tap.ok(errs[1] and errs[1]:find("without a yield", 1, true), "max_run stops a stuck task")
	tap.is(ticks, 3, "max_run: the other task finishes")
end

-- A gate limits two listeners together.
do
	local loop = mpoll.new()
	local l1 = assert(loop:listen("127.0.0.1", 0))
	local l2 = assert(loop:listen("127.0.0.1", 0))
	local srv = server.new({ handler = require("app"), on_error = function() end })
	local gate = { max = 1 }
	loop:serve(l1, srv, { gate = gate })
	loop:serve(l2, srv, { gate = gate })
	local got = {}
	loop:spawn(function()
		local req = "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n"
		local a = assert(loop:connect("127.0.0.1", l1:port()))
		assert(a:write(req))
		got.a = a:read(4096, clock.after(2))
		local b = assert(loop:connect("127.0.0.1", l2:port()))
		assert(b:write(req))
		got.wait = select(2, b:read(4096, clock.after(0.2)))
		a:close()
		got.b = b:read(4096, clock.after(2))
		b:close()
		l1:close()
		l2:close()
	end)
	loop:run()
	tap.ok(got.a and got.a:find("^HTTP/1.1 200"), "gate: first connection served")
	tap.is(got.wait, "timeout", "gate: a connection on the other listener waits")
	tap.ok(got.b and got.b:find("^HTTP/1.1 200"), "gate: served after the first ends")
	tap.is(loop.count, 0, "gate: every task ends")
end

-- End to end: the server, the shared checks, and many clients at once.
local loop = mpoll.new()
local l = assert(loop:listen("127.0.0.1", 0))
local port = l:port()
local srv = server.new({ handler = require("app"), on_error = function() end,
	max_body = 1 << 20, head = 1 })
loop:serve(l, srv)

local finished = 0
local function task(f)
	loop:spawn(function()
		local ok, err = pcall(f)
		if not ok then
			tap.ok(false, "task")
			tap.diag(err)
		end
		finished = finished + 1
		if finished == 3 then
			l:close()
		end
	end)
end

task(function()
	require("e2e")(tap, port, function(host, p, opts)
		return loop:connect(host, p, opts)
	end)
end)

task(function()
	local N, M = 20, 10
	local done, bad = 0, 0
	for _ = 1, N do
		loop:spawn(function()
			local c = client.new({ connect = function(h, p, o)
				return loop:connect(h, p, o)
			end, timeout = 10 })
			for _ = 1, M do
				local res = c:get(("http://127.0.0.1:%d/hello"):format(port))
				if not (res and res.body == "hello") then
					bad = bad + 1
				end
			end
			c:close()
			done = done + 1
		end)
	end
	while done < N do
		loop:sleep(0.01)
	end
	tap.is(bad, 0, ("%d concurrent clients, %d requests each"):format(N, M))
end)

-- A slow client does not hold up the others, and gets 408.
task(function()
	local s = assert(loop:connect("127.0.0.1", port))
	assert(s:write("GET /hello HTTP/1.1\r\nHo"))
	local c = client.new({ connect = function(h, p, o)
		return loop:connect(h, p, o)
	end, timeout = 5 })
	local t = clock.now()
	local res = c:get(("http://127.0.0.1:%d/hello"):format(port))
	tap.ok(res and res.body == "hello" and clock.now() - t < 0.5,
		"other clients go on while one is slow")
	c:close()
	local got = s:read(4096, clock.after(5)) or ""
	tap.ok(got:find("^HTTP/1.1 408"), "slow client gets 408")
	s:close()
end)

loop:run()
tap.is(loop.count, 0, "every task ends after the listener closes")
tap.done()
