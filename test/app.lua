-- SPDX-License-Identifier: ISC

-- The handler the end-to-end tests and the benchmark serve.

local coro = require("mhttp.coro")
local url = require("mhttp.url")
local router = require("mhttp.router")

local routes = {}

routes["/hello"] = function(_, res)
	res.headers:set("Content-Type", "text/plain")
	res:send(200, "hello")
end

routes["/echo"] = function(req, res)
	local body, err = req:body(1 << 20)
	if not body then
		return res:send(err.status or 400, err.message)
	end
	res:send(200, body, { { "X-Method", req.method } })
end

routes["/peer"] = function(req, res)
	res:send(200, tostring(req.peer and req.peer.port))
end

routes["/query"] = function(req, res)
	local q = url.query(req.query)
	res:send(200, q.name or "")
end

routes["/chunked"] = function(_, res)
	for _, s in ipairs({ "one ", "two ", "three" }) do
		assert(res:write(s))
	end
	assert(res:finish(nil, { { "X-Count", "3" } }))
end

routes["/big"] = function(_, res)
	local piece = ("0123456789abcdef"):rep(4096)
	for _ = 1, 16 do
		assert(res:write(piece))
	end
	res:finish()
end

-- Reads the body through a generator, so its I/O waits pass through
-- mhttp.coro to the scheduler.
routes["/gen"] = function(req, res)
	local pieces = coro.wrap(function()
		while true do
			local s = req:read()
			if not s then
				return nil
			end
			coro.yield(s:upper())
		end
	end)
	local t = {}
	for s in pieces do
		t[#t + 1] = s
	end
	res:send(200, table.concat(t))
end

-- Spools a body of up to 4 MiB to a temporary file.
routes["/upload"] = function(req, res)
	local f, n = req:spool({ max = 4 << 20 })
	if not f then
		return res:send(n.status or 400, n.message)
	end
	local head = f:read(4)
	f:close()
	res:send(200, ("%d %s"):format(n, head))
end

-- 20 MiB, more than the old parser default.
routes["/huge"] = function(_, res)
	local piece = ("x"):rep(1 << 20)
	for _ = 1, 20 do
		assert(res:write(piece))
	end
	res:finish()
end

routes["/redirect"] = function(_, res)
	res:send(302, "", { { "Location", "/hello" } })
end

routes["/error"] = function()
	error("boom")
end

routes["/noresp"] = function() end

routes["/close"] = function(_, res)
	res:send(200, "bye", { { "Connection", "close" } })
end

routes["/head"] = function(_, res)
	res:send(200, "twelve bytes")
end

routes["/upgrade"] = function(req, res)
	if not req.upgrade then
		return res:send(426, "")
	end
	res:start(101, { { "Connection", "Upgrade" }, { "Upgrade", "reverse" } })
	local s, rest = res:hijack()
	local data = rest
	while #data < 5 do
		local more = s:read(64)
		if not more then
			break
		end
		data = data .. more
	end
	s:write(data:reverse())
	s:close()
end

local r = router.new()
for path, f in pairs(routes) do
	r:any(path, f)
end
r:get("/paste/{id:%x+}", function(req, res)
	res:send(200, "paste " .. req.params.id)
end)
return r:handler()
