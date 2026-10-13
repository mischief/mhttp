-- SPDX-License-Identifier: ISC

-- Client checks against a running server. Both test/http.lua and
-- test/event.lua call them; port is where the server listens.

local client = require("mhttp.client")
local posix = require("mhttp.io.posix")

return function(tap, port, connect)
	local base = ("http://127.0.0.1:%d"):format(port)
	local c = client.new({ connect = connect, timeout = 10 })

	local res, err = c:get(base .. "/hello")
	tap.ok(res and res.status == 200 and res.body == "hello", "get /hello")
	if not res then
		tap.diag(err.kind .. ": " .. err.message)
	end
	tap.ok(res and res.headers:get("date") ~= nil, "date field")

	local a = c:get(base .. "/peer")
	local b = c:get(base .. "/peer")
	tap.ok(a and b and a.body == b.body, "keep-alive: same connection reused")

	res = c:request({ method = "POST", url = base .. "/echo", body = "payload" })
	tap.ok(res and res.body == "payload" and res.headers:get("x-method") == "POST", "post body")

	local parts = { "a", "bb", "ccc" }
	local i = 0
	res = c:request({ method = "POST", url = base .. "/echo", body = function()
		i = i + 1
		return parts[i]
	end })
	tap.ok(res and res.body == "abbccc", "chunked request body")

	res = c:get(base .. "/chunked")
	tap.ok(res and res.body == "one two three", "chunked response")
	tap.ok(res and res.trailers and res.trailers:get("x-count") == "3", "chunked trailers")

	res = c:get(base .. "/big")
	tap.ok(res and #res.body == 16 * 65536, "large chunked response")

	res = c:get(base .. "/big", { max_body = 1000 })
	tap.ok(res == nil, "max_body stops a large body")

	res = c:get(base .. "/big", { stream = true })
	local n, pieces = 0, 0
	while res do
		local s = res:read()
		if not s then
			break
		end
		n, pieces = n + #s, pieces + 1
	end
	tap.ok(n == 16 * 65536 and pieces > 1, "streamed response")

	res = c:get(base .. "/query?name=a%20b")
	tap.ok(res and res.body == "a b", "query string")

	res = c:request({ method = "HEAD", url = base .. "/head" })
	tap.ok(res and res.body == "" and res.headers:get("content-length") == "12", "head")

	res = c:get(base .. "/redirect")
	tap.ok(res and res.status == 302, "redirect not followed by default")
	res = c:get(base .. "/redirect", { follow = 2 })
	tap.ok(res and res.status == 200 and res.body == "hello", "redirect followed")

	i = 0
	res = c:request({ method = "POST", url = base .. "/gen", body = function()
		i = i + 1
		return i <= 3 and "abc" or nil
	end })
	tap.ok(res and res.body == "ABCABCABC", "generator in a handler")

	res = c:get(base .. "/error")
	tap.ok(res and res.status == 500, "handler error gives 500")
	res = c:get(base .. "/noresp")
	tap.ok(res and res.status == 500, "no response gives 500")
	res = c:get(base .. "/hello")
	tap.ok(res and res.status == 200, "client recovers after a closed connection")
	res = c:get(base .. "/close")
	tap.ok(res and res.body == "bye" and res.keep_alive == false, "connection: close")
	res = c:get(base .. "/missing")
	tap.ok(res and res.status == 404, "404")
	res = c:get(base .. "/paste/c0ffee")
	tap.ok(res and res.body == "paste c0ffee", "router parameter")
	res = c:request({ method = "DELETE", url = base .. "/paste/c0ffee" })
	tap.ok(res and res.status == 405 and res.headers:get("allow") == "GET, HEAD", "router 405")

	res = c:request({ method = "POST", url = base .. "/echo", body = "x",
		headers = { Expect = "100-continue" } })
	tap.ok(res and res.status == 200 and res.body == "x", "expect: 100-continue")

	res = c:request({ url = base .. "/upgrade",
		headers = { Connection = "Upgrade", Upgrade = "reverse" } })
	local up = false
	if res and res.status == 101 then
		local s, rest = res:hijack()
		s:write("hello")
		local got = rest
		while #got < 5 do
			local more = s:read(64, nil)
			if not more then
				break
			end
			got = got .. more
		end
		up = got == "olleh"
		s:close()
	end
	tap.ok(up, "upgrade and hijack")

	-- The server runs with max_body = 1 MiB; /upload allows 4 MiB.
	local two = ("y"):rep(2 << 20)
	res = c:request({ method = "POST", url = base .. "/echo", body = two })
	tap.ok(res and res.status == 413, "body over the server limit: 413")
	res = c:request({ method = "POST", url = base .. "/upload", body = two })
	tap.ok(res and res.body == ("%d yyyy"):format(#two), "spool: a route raises the limit")
	local left = 2 << 20
	res = c:request({ method = "POST", url = base .. "/upload", body = function()
		if left == 0 then
			return nil
		end
		left = left - 65536
		return ("z"):rep(65536)
	end })
	tap.ok(res and res.body == ("%d zzzz"):format(2 << 20), "spool: chunked body")
	res = c:request({ method = "POST", url = base .. "/upload", body = ("q"):rep(5 << 20) })
	tap.ok(res and res.status == 413, "spool: over the route limit")
	local total = 0
	res = c:get(base .. "/huge", { sink = function(s)
		total = total + #s
	end })
	tap.ok(res and total == 20 << 20, "client: 20 MiB through a sink")

	-- A resolver hook: a name only it knows.
	local rc = client.new({ connect = connect, resolve = function(host)
		if host == "mhttp.test" then
			return { "127.0.0.1" }
		end
		return nil, "unknown"
	end })
	res = rc:get(("http://mhttp.test:%d/hello"):format(port))
	tap.ok(res and res.body == "hello", "resolve hook")
	res, err = rc:get(("http://other.test:%d/hello"):format(port))
	tap.ok(res == nil and err.kind == "connect", "resolve hook: failure")
	rc:close()

	-- Raw bytes the client would refuse to write.
	local function raw(bytes)
		local s = assert((connect or posix.connect)("127.0.0.1", port))
		s:write(bytes)
		local t = {}
		while true do
			local d = s:read(4096)
			if not d then
				break
			end
			t[#t + 1] = d
		end
		s:close()
		return table.concat(t)
	end
	local out = raw("POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n" ..
		"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /hello HTTP/1.1\r\nHost: h\r\n\r\n")
	tap.ok(out:find("^HTTP/1.1 400") and not out:find("hello"), "smuggling attempt: 400 and close")
	out = raw("GET /hello HTTP/1.1\r\nHost: h\r\n\r\nGET /hello HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
	local _, count = out:gsub("HTTP/1.1 200", "")
	tap.is(count, 2, "pipelined requests")
	out = raw("GET /hello HTTP/1.0\r\n\r\n")
	tap.ok(out:find("^HTTP/1.0 200") and out:find("\r\n\r\nhello$"), "HTTP/1.0 request")

	c:close()
end
