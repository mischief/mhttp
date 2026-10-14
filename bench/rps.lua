-- SPDX-License-Identifier: ISC
-- Requests per second over loopback TCP, mhttp.client against
-- mhttp.server. Each client is a process with one keep-alive
-- connection. The server is one of:
--   fork       a process per connection
--   event      one process, a task per connection under event_pure
--   poll       one process, a task per connection under mhttp.io.poll
--   reuseport  several event processes, each with its own SO_REUSEPORT
--              listener on the same port
--
-- usage: lua bench/rps.lua [mode] [conns] [seconds] [body bytes] [workers]
package.path = "./?.lua;./?/init.lua;" .. package.path

local unistd = require("posix.unistd")
local wait = require("posix.sys.wait")
local signal = require("posix.signal")
local posix = require("mhttp.io.posix")
local server = require("mhttp.server")
local client = require("mhttp.client")
local clock = require("mhttp.clock")

local MODE = arg[1] or "fork"
local CONNS = tonumber(arg[2]) or 4
local SECS = tonumber(arg[3]) or 3
local BODY = ("x"):rep(tonumber(arg[4]) or 13)
local WORKERS = tonumber(arg[5]) or 4

local srv = server.new({
	date = false,
	handler = function(_, res)
		res:send(200, BODY, { { "Content-Type", "text/plain" } })
	end,
})

local function fork_server()
	local l = assert(posix.listen("127.0.0.1", 0))
	local pid = assert(unistd.fork())
	if pid == 0 then
		signal.signal(signal.SIGCHLD, signal.SIG_IGN)
		while true do
			local s = l:accept()
			if s then
				if unistd.fork() == 0 then
					l:close()
					srv:serve(s)
					unistd._exit(0)
				end
				s:close()
			end
		end
	end
	local port = l:port()
	l:close()
	return pid, port
end

local function event_module()
	local dir = os.getenv("MHTTP_EVENT_LUA") or "../event/lua"
	package.path = dir .. "/?.lua;" .. package.path
	local ev = require("event_pure")
	return ev, require("mhttp.io.event").new(ev)
end

local function event_server()
	local ev, aio = event_module()
	local l = assert(aio.listen("127.0.0.1", 0))
	local pid = assert(unistd.fork())
	if pid == 0 then
		local loop = ev.loop()
		aio.serve(loop, l, srv)
		loop:run()
		unistd._exit(0)
	end
	local port = l:port()
	l:close()
	return { pid }, port
end

local function poll_server()
	local loop = require("mhttp.io.poll").new()
	local l = assert(loop:listen("127.0.0.1", 0))
	local pid = assert(unistd.fork())
	if pid == 0 then
		loop:serve(l, srv)
		loop:run()
		unistd._exit(0)
	end
	local port = l:port()
	l:close()
	return { pid }, port
end

-- The parent binds first to pick the port, and closes its listener once
-- every worker has its own, so no connection waits in the parent's.
local function reuseport_server()
	local ev, aio = event_module()
	local first = assert(posix.listen("127.0.0.1", 0, { reuseport = true }))
	local port = first:port()
	local rd, wr = assert(unistd.pipe())
	local pids = {}
	for i = 1, WORKERS do
		local pid = assert(unistd.fork())
		if pid == 0 then
			first:close()
			unistd.close(rd)
			local l = assert(aio.listen("127.0.0.1", port, { reuseport = true }))
			unistd.write(wr, "r")
			unistd.close(wr)
			local loop = ev.loop()
			aio.serve(loop, l, srv)
			loop:run()
			unistd._exit(0)
		end
		pids[i] = pid
	end
	unistd.close(wr)
	local ready = 0
	while ready < WORKERS do
		local s = unistd.read(rd, WORKERS)
		if not s or s == "" then
			break
		end
		ready = ready + #s
	end
	unistd.close(rd)
	first:close()
	return pids, port
end

local spids, port
if MODE == "event" then
	spids, port = event_server()
elseif MODE == "poll" then
	spids, port = poll_server()
elseif MODE == "reuseport" then
	spids, port = reuseport_server()
else
	local pid
	pid, port = fork_server()
	spids = { pid }
end

local rd, wr = assert(unistd.pipe())
local deadline = clock.now() + SECS
local target = ("http://127.0.0.1:%d/"):format(port)
local clients = {}
for i = 1, CONNS do
	local pid = assert(unistd.fork())
	if pid == 0 then
		unistd.close(rd)
		local c = client.new()
		local n, failed = 0, false
		while clock.now() < deadline do
			local res = c:get(target)
			if not res or res.status ~= 200 then
				failed = true
				break
			end
			n = n + 1
		end
		unistd.write(wr, ("%d\n"):format(failed and -1 or n))
		unistd._exit(0)
	end
	clients[i] = pid
end
unistd.close(wr)
local t0 = clock.now()
for _, pid in ipairs(clients) do
	wait.wait(pid)
end
local elapsed = clock.now() - t0
local out = {}
while true do
	local s = unistd.read(rd, 4096)
	if not s or s == "" then
		break
	end
	out[#out + 1] = s
end
for _, pid in ipairs(spids) do
	signal.kill(pid, signal.SIGTERM)
	wait.wait(pid)
end

local total, failed = 0, 0
for n in table.concat(out):gmatch("(%-?%d+)\n") do
	n = tonumber(n)
	if n < 0 then
		failed = failed + 1
	else
		total = total + n
	end
end
print(("%-9s conns %3d  seconds %.2f  body %d  requests %d  rps %.0f%s"):format(
	MODE, CONNS, elapsed, #BODY, total, total / elapsed,
	failed > 0 and ("  failed clients %d"):format(failed) or ""))
os.exit(failed == 0 and 0 or 1)
