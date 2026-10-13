-- SPDX-License-Identifier: ISC
-- End to end over loopback with blocking sockets. The server runs in a
-- child process and forks once per connection.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local unistd = require("posix.unistd")
local signal = require("posix.signal")
local wait = require("posix.sys.wait")
local posix = require("mhttp.io.posix")
local server = require("mhttp.server")

local l = assert(posix.listen("127.0.0.1", 0))
local port = l:port()
local srv = server.new({ handler = require("app"), on_error = function() end,
	max_body = 1 << 20 })

local pid = assert(unistd.fork())
if pid == 0 then
	signal.signal(signal.SIGCHLD, signal.SIG_IGN)
	while true do
		local s = l:accept()
		if s then
			local child = unistd.fork()
			if child == 0 then
				l:close()
				srv:serve(s)
				unistd._exit(0)
			end
			s:close()
		end
	end
end
l:close()

local ok, err = pcall(require("e2e"), tap, port)
if not ok then
	tap.ok(false, "e2e")
	tap.diag(err)
end
-- Two listeners on one port need SO_REUSEPORT.
local r1 = posix.SO_REUSEPORT and posix.listen("127.0.0.1", 0, { reuseport = true })
if r1 then
	local r2 = posix.listen("127.0.0.1", r1:port(), { reuseport = true })
	tap.ok(r2 ~= nil, "reuseport: a second listener on the same port")
	if r2 then
		r2:close()
	end
	r1:close()
else
	tap.skip("reuseport", "SO_REUSEPORT not known here")
end

signal.kill(pid, signal.SIGTERM)
wait.wait(pid)
tap.done()
