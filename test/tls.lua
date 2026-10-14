-- SPDX-License-Identifier: ISC
-- TLS with each backend that loads: a local CA, server and client
-- certificates, mutual TLS, and both backends against each other. Needs
-- the openssl command to make the certificates. MHTTP_CPATH adds a
-- directory to package.cpath, for a libtls core built outside luarocks.
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

-- Names, without a backend.
do
	local peer = { dns = { "example.com", "*.wild.example.com", "*.com", "f*.part.example.com" },
		ip = { "127.0.0.1", "::1" } }
	local cases = {
		{ "example.com", true }, { "EXAMPLE.com.", true }, { "www.example.com", false },
		{ "a.wild.example.com", true }, { "a.b.wild.example.com", false },
		{ "wild.example.com", false }, { "x.com", false }, { "foo.part.example.com", false },
		{ "127.0.0.1", true }, { "[::1]", true }, { "10.0.0.1", false },
	}
	for _, c in ipairs(cases) do
		tap.is(tls.match_host(peer, c[1]), c[2], "match_host " .. c[1])
	end
	tap.is(tls.match_host({ dns = { "127.0.0.1" } }, "127.0.0.1"), false,
		"an address does not match a dns name")
end

local backends = {}
for _, name in ipairs(tls.backends) do
	local ok, mod = pcall(require, name)
	if ok then
		backends[#backends + 1] = name
	else
		tap.skip("backend " .. name, "does not load")
	end
end
if #backends == 0 or not os.execute("command -v openssl >/dev/null") then
	tap.skip("tls end to end", "no backend or no openssl")
	tap.done()
end

-- Makes a CA, a server certificate for localhost and 127.0.0.1, and a
-- client certificate.
local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p " .. dir))
local function sh(cmd)
	assert(os.execute("cd " .. dir .. " && " .. cmd .. " >/dev/null 2>&1"), cmd)
end
local EC = "-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes"
sh("openssl req -x509 " .. EC .. " -keyout ca.key -out ca.pem -days 2 -subj /CN=mhttp-test-ca")
for _, c in ipairs({
	{ "server", "/CN=localhost", "subjectAltName=DNS:localhost,IP:127.0.0.1" },
	{ "client", "/CN=alice", "extendedKeyUsage=clientAuth" },
	{ "other", "/CN=other.test", "subjectAltName=DNS:other.test" },
}) do
	local name, subj, ext = c[1], c[2], c[3]
	sh(("openssl req %s -keyout %s.key -out %s.csr -subj %s"):format(EC, name, name, subj))
	local fx = assert(io.open(dir .. "/" .. name .. ".ext", "w"))
	fx:write(ext, "\n")
	fx:close()
	sh(("openssl x509 -req -in %s.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 "
		.. "-out %s.pem -extfile %s.ext"):format(name, name, name))
end
local function f(name)
	return dir .. "/" .. name
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

os.execute("rm -rf " .. dir)
tap.done()
