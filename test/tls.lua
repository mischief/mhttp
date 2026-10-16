-- SPDX-License-Identifier: ISC
-- TLS with libtls: a local CA, server and client certificates, mutual
-- TLS, SNI and pinning. The certificates are in test/certs.
-- MHTTP_CPATH adds a directory to package.cpath, for C modules built
-- outside luarocks.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path
if os.getenv("MHTTP_CPATH") then
	package.cpath = os.getenv("MHTTP_CPATH") .. "/?.so;" .. package.cpath
end

local tap = require("tap")
local tls = require("mhttp.tls")
local mpoll = require("mhttp.io.poll")
local server = require("mhttp.server")
local client = require("mhttp.client")
local clock = require("mhttp.clock")

local backends = {}
for _, name in ipairs(tls.backends) do
	local ok, err = pcall(require, name)
	tap.ok(ok, "backend " .. name .. " loads: " .. tostring(err))
	if ok then
		backends[#backends + 1] = name
	end
end
if #backends == 0 then
	tap.done()
end

-- The tests run from the source root.
local function f(name)
	return "test/certs/" .. name
end

local function handler(req, res)
	if req.path == "/big" then
		local body = req:body(8 << 20)
		return res:send(200, body)
	end
	local t = req.stream_info and req.stream_info.tls or {}
	local peer = t.peer and t.peer.subject or "-"
	res:send(200, ("%s %s"):format(t.version or "-", peer))
end

-- Runs fn(loop, port) as a task against a TLS server with the given
-- backend and options, then stops.
local function with_server(backend, sopts, fn)
	local loop = mpoll.new({ on_error = function() end })
	local o = { backend = backend, cert = f("server.pem"), key = f("server.key") }
	for k, v in pairs(sopts or {}) do
		if v == false then
			v = nil
		end
		o[k] = v
	end
	local l = assert(loop:listen("127.0.0.1", 0, { tls = o }))
	loop:serve(l, server.new({ handler = handler, on_error = function() end, max_body = 8 << 20 }))
	loop:spawn(function()
		local ok, err = pcall(fn, loop, l:port())
		if not ok then
			tap.ok(false, "task")
			tap.diag(err)
		end
		l:close()
	end)
	loop:run()
end

local function cl(loop, copts)
	return client.new({ timeout = 10, tls = copts, connect = function(h, p, o)
		return loop:connect(h, p, o)
	end })
end

for _, sb in ipairs(backends) do
	for _, cb in ipairs(backends) do
		local tag = sb:match("[^.]+$") .. " server, " .. cb:match("[^.]+$") .. " client: "
		with_server(sb, nil, function(loop, port)
			local c = cl(loop, { backend = cb, ca = f("ca.pem") })
			local res, err = c:get(("https://localhost:%d/"):format(port))
			tap.ok(res and res.status == 200 and res.body:find("^TLSv1%.[23]"), tag .. "get")
			if err then
				tap.diag(err.message)
			end
			res = c:get(("https://localhost:%d/"):format(port))
			tap.ok(res and res.status == 200, tag .. "keep-alive")
			res, err = c:get(("https://127.0.0.1:%d/"):format(port))
			tap.ok(res and res.status == 200, tag .. "IP address entry")
			if err then
				tap.diag(err.message)
			end
			local big = ("0123456789abcdef"):rep(1 << 16)
			res = c:request({ method = "POST", url = ("https://localhost:%d/big"):format(port),
				body = big })
			tap.ok(res and res.body == big, tag .. "1 MiB each way")
			c:close()

			c = cl(loop, { backend = cb, ca = f("ca.pem"), host = "other.example" })
			res, err = c:get(("https://localhost:%d/"):format(port))
			tap.ok(not res and err.message:find("tls"), tag .. "wrong name fails")
			c:close()

			c = cl(loop, { backend = cb, ca = f("client.pem") })
			res, err = c:get(("https://localhost:%d/"):format(port))
			tap.ok(not res and err.message:find("tls"), tag .. "unknown CA fails")
			c:close()

			c = cl(loop, { backend = cb, verify = false })
			res = c:get(("https://localhost:%d/"):format(port))
			tap.ok(res and res.status == 200, tag .. "verify = false")
			c:close()

			-- A client that never starts its handshake does not hold up
			-- the accept task.
			local raw = assert(loop:connect("127.0.0.1", port))
			c = cl(loop, { backend = cb, ca = f("ca.pem") })
			local t = clock.now()
			res = c:get(("https://localhost:%d/"):format(port))
			tap.ok(res and clock.now() - t < 2, tag .. "a stalled handshake holds up no one")
			raw:close()
			c:close()
		end)

		with_server(sb, { client_auth = "require", ca = f("ca.pem") }, function(loop, port)
			local c = cl(loop, { backend = cb, ca = f("ca.pem") })
			local res = c:get(("https://localhost:%d/"):format(port))
			tap.ok(not res, tag .. "mutual TLS: no client certificate fails")
			c:close()
			c = cl(loop, { backend = cb, ca = f("ca.pem"), cert = f("client.pem"),
				key = f("client.key") })
			local err
			res, err = c:get(("https://localhost:%d/"):format(port))
			tap.ok(res and res.body:find("/CN=alice", 1, true), tag .. "mutual TLS: handler sees the client")
			if not res then
				tap.diag(err.message)
			elseif not res.body:find("alice") then
				tap.diag(res.body)
			end
			c:close()
		end)
	end
end

-- Several certs: the server picks one by SNI.
for _, sb in ipairs(backends) do
	with_server(sb, { certs = { { f("server.pem"), f("server.key") }, { f("other.pem"), f("other.key") } },
		cert = false, key = false }, function(loop, port)
		local c = client.new({ timeout = 10, tls = { ca = f("ca.pem") },
			resolve = function()
				return { "127.0.0.1" }
			end,
			connect = function(h, p, o)
				return loop:connect(h, p, o)
			end })
		local res, err = c:get(("https://other.test:%d/"):format(port))
		tap.ok(res and res.status == 200, sb:match("[^.]+$") .. " server: SNI picks the second cert")
		if err then
			tap.diag(err.message)
		end
		res = c:get(("https://localhost:%d/"):format(port))
		tap.ok(res and res.status == 200, sb:match("[^.]+$") .. " server: SNI picks the first cert")
		c:close()
	end)
end

-- A verify_cb can pin a certificate.
with_server(backends[1], nil, function(loop, port)
	local seen
	local c = cl(loop, { ca = f("ca.pem"), verify_cb = function(info)
		seen = info
		return nil, "pinned to another key"
	end })
	local res, err = c:get(("https://localhost:%d/"):format(port))
	tap.ok(not res and err.message:find("pinned"), "verify_cb rejects")
	tap.ok(seen and seen.peer, "verify_cb gets the peer")
	c:close()
end)

-- After the peer closes, a write fails and does not loop.
do
	local loop = mpoll.new({ on_error = function() end })
	local l = assert(loop:listen("127.0.0.1", 0, { tls = { backend = backends[1],
		cert = f("server.pem"), key = f("server.key") } }))
	local got = {}
	loop:spawn(function()
		local s = assert(l:accept())
		got.first = s:read(100, clock.after(5))
		got.eof = select(2, s:read(100, clock.after(5)))
		for _ = 1, 50 do
			local ok, err = s:write(("z"):rep(4096), clock.after(5))
			if not ok then
				got.werr = err
				break
			end
		end
		s:close()
		l:close()
	end)
	loop:spawn(function()
		local c = assert(loop:connect("127.0.0.1", l:port(), { tls = { backend = backends[1],
			ca = f("ca.pem"), host = "localhost" } }))
		assert(c:write("x", clock.after(5)))
		c:close()
	end)
	loop:run()
	tap.is(got.first, "x", "close: data before the close")
	tap.ok(got.eof, "close: then the read ends: " .. tostring(got.eof))
	tap.ok(got.werr, "close: a write after the close fails: " .. tostring(got.werr))
end

tap.done()
