-- SPDX-License-Identifier: ISC
-- End to end in one process under the event loop (event_pure). Every
-- connection and every client is a task. Skips when the event library
-- is not found; MHTTP_EVENT_LUA names its lua directory.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local dir = os.getenv("MHTTP_EVENT_LUA") or "../event/lua"
package.path = dir .. "/?.lua;" .. package.path
local found, ev = pcall(require, "event_pure")
if not found then
	tap.skip("event loop", "event_pure not found in " .. dir)
	tap.done()
end

local server = require("mhttp.server")
local client = require("mhttp.client")
local aio = require("mhttp.io.event").new(ev)

local loop = ev.loop()
local l = assert(aio.listen("127.0.0.1", 0))
local port = l:port()
local srv = server.new({ handler = require("app"), on_error = function() end,
	max_body = 1 << 20 })
aio.serve(loop, l, srv)

local finished = 0
local function task(f)
	loop:spawn(function()
		local ok, err = pcall(f)
		if not ok then
			tap.ok(false, "task")
			tap.diag(err)
		end
		finished = finished + 1
		if finished == 2 then
			l:close()
			loop:stop()
		end
	end)
end

task(function()
	require("e2e")(tap, port, aio.connect)
	-- c-ares, when the event library has it built.
	package.cpath = dir .. "/../build/?.so;" .. package.cpath
	local resolver = aio.ares(loop)
	if not resolver or not pcall(require, "dns") then
		tap.skip("ares resolver", "dns module not built")
		return
	end
	local c = client.new({ connect = aio.connect, resolve = resolver })
	local res, err = c:get(("http://localhost:%d/hello"):format(port))
	tap.ok(res and res.body == "hello", "ares resolver")
	if not res then
		tap.diag(err.message)
	end
	c:close()
end)

-- Many clients at once, each on its own connection.
task(function()
	local N, M = 20, 10
	local done, bad = 0, 0
	for _ = 1, N do
		loop:spawn(function()
			local c = client.new({ connect = aio.connect, timeout = 10 })
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
	local sleep = ev.timer(loop, 1000)
	while done < N do
		ev.await(loop, sleep, "r")
		sleep = ev.timer(loop, 1000)
	end
	tap.is(bad, 0, ("%d concurrent clients, %d requests each"):format(N, M))
end)

loop:run()
tap.done()
