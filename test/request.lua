-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local u = require("util")

local function run(input, opts)
	return u.run("request", input, opts)
end

tap.try("simple get", function()
	local evs, err = run("GET /a/b?x=1&y HTTP/1.1\r\nHost: example.com\r\n\r\n")
	tap.is(err, nil, "get: no error")
	local h = evs[1]
	tap.is(h.method, "GET", "get: method")
	tap.is(h.path, "/a/b", "get: path")
	tap.is(h.query, "x=1&y", "get: query")
	tap.is(h.form, "origin", "get: origin form")
	tap.is(h.version, "1.1", "get: version")
	tap.is(h.keep_alive, true, "get: keep-alive by default in 1.1")
	tap.is(h.framing, "none", "get: no body")
	tap.is(h.headers:get("HOST"), "example.com", "get: host, any case")
	tap.is(u.summary(evs), "head GET none true|done", "get: events")
end)

tap.try("content-length body, one byte at a time", function()
	local evs, err = run("POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 11\r\n\r\nhello world",
		{ step = 1 })
	tap.is(err, nil, "cl: no error")
	tap.is(u.body(evs), "hello world", "cl: body")
	tap.is(evs[1].length, 11, "cl: length")
end)

tap.try("chunked with extensions and trailers", function()
	local input = "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n" ..
		"5;name=val;q=\"a b\"\r\nhello\r\n6 ; x\r\n world\r\n0\r\nX-Sum: 1\r\n\r\n"
	for _, step in ipairs({ 1, 3, #input }) do
		local evs, err = run(input, { step = step })
		tap.is(err, nil, "chunked step " .. step .. ": no error")
		tap.is(u.body(evs), "hello world", "chunked step " .. step .. ": body")
		local tr = u.first(evs, "trailers")
		tap.ok(tr and tr.headers:get("x-sum") == "1", "chunked step " .. step .. ": trailer")
	end
end)

tap.try("pipelined requests", function()
	local input = "GET /1 HTTP/1.1\r\nHost: h\r\n\r\n" ..
		"POST /2 HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nok" ..
		"GET /3 HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n"
	local evs, err, p = run(input)
	tap.is(err, nil, "pipeline: no error at the end")
	tap.is(u.summary(evs),
		"head GET none true|done|head POST length true|data ok|done|head GET none false|done",
		"pipeline: events")
	local _, e2 = p:next()
	tap.is(e2 and e2.code, "closed", "pipeline: closed after Connection: close")
end)

tap.try("HTTP/1.0 persistence", function()
	local evs = run("GET / HTTP/1.0\r\n\r\n")
	tap.is(evs[1].keep_alive, false, "1.0: closes by default")
	tap.is(evs[1].version, "1.0", "1.0: version")
	evs = run("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n")
	tap.is(evs[1].keep_alive, true, "1.0: keep-alive token")
	evs = run("GET / HTTP/1.1\r\nHost: h\r\nConnection: foo, close\r\n\r\n")
	tap.is(evs[1].keep_alive, false, "1.1: close in a list")
end)

tap.try("leading empty lines", function()
	local evs, err = run("\r\n\r\nGET / HTTP/1.1\r\nHost: h\r\n\r\n")
	tap.is(err, nil, "crlf: ignored before a request")
	tap.is(evs[1].method, "GET", "crlf: request parsed")
end)

tap.try("expect, upgrade and target forms", function()
	local evs = run("PUT / HTTP/1.1\r\nHost: h\r\nExpect: 100-Continue\r\nContent-Length: 1\r\n\r\nx")
	tap.is(evs[1].expect_continue, true, "expect: 100-continue")
	evs = run("GET /ws HTTP/1.1\r\nHost: h\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
	tap.is(evs[1].upgrade and evs[1].upgrade[1], "websocket", "upgrade: tokens")
	evs = run("GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\n\r\n")
	tap.is(evs[1].upgrade, nil, "upgrade: ignored unless Connection lists it")
	evs = run("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
	tap.is(evs[1].form, "authority", "connect: authority form")
	evs = run("OPTIONS * HTTP/1.1\r\nHost: h\r\n\r\n")
	tap.is(evs[1].form, "asterisk", "options: asterisk form")
	evs = run("GET http://example.com/x HTTP/1.1\r\nHost: example.com\r\n\r\n")
	tap.is(evs[1].form, "absolute", "proxy: absolute form")
	evs = run("GET [::1]:80 HTTP/1.1\r\nHost: h\r\n\r\n")
	tap.ok(evs[1] == nil, "target: authority form needs CONNECT")
	local _, err = run("GET * HTTP/1.1\r\nHost: h\r\n\r\n")
	tap.is(err and err.status, 400, "target: asterisk needs OPTIONS")
	evs, err = run("GET / HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n")
	tap.is(err, nil, "host: IPv6 literal with port")
end)

tap.try("rest after upgrade", function()
	local p = require("mhttp.parse").new("request")
	p:feed("GET / HTTP/1.1\r\nHost: h\r\nConnection: upgrade\r\nUpgrade: x\r\n\r\n\129\5hello")
	tap.is(p:next().type, "head", "rest: head")
	tap.is(p:next().type, "done", "rest: done")
	tap.is(p:rest(), "\129\5hello", "rest: bytes after the request")
	local _, err = p:next()
	tap.is(err.code, "detached", "rest: parser stops")
end)

tap.try("end of stream", function()
	local _
	local evs, err = run("")
	tap.ok(#evs == 0 and err == nil, "eof: clean when idle")
	_, err = run("GET / HTTP/1.1\r\nHo")
	tap.is(err and err.code, "truncated", "eof: inside a head")
	_, err = run("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nabc")
	tap.is(err and err.code, "truncated", "eof: inside a body")
	_, err = run("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello")
	tap.is(err and err.code, "truncated", "eof: inside a chunked body")
	evs, err = run("GET / HTTP/1.1\r\nHost: h\r\n\r\n", { eof = false })
	tap.is(err, nil, "no eof: waits")
end)

tap.try("limits", function()
	local _
	local long = "GET /" .. ("a"):rep(9000) .. " HTTP/1.1\r\nHost: h\r\n\r\n"
	local _, err = run(long)
	tap.is(err and err.status, 414, "limit: long request line")
	_, err = run(long, { step = 100 })
	tap.is(err and err.status, 414, "limit: long request line, streamed")
	local many = { "GET / HTTP/1.1\r\nHost: h\r\n" }
	for i = 1, 101 do
		many[#many + 1] = ("X-%d: v\r\n"):format(i)
	end
	many[#many + 1] = "\r\n"
	_, err = run(table.concat(many))
	tap.is(err and err.status, 431, "limit: too many fields")
	_, err = run("GET / HTTP/1.1\r\nHost: h\r\nX: " .. ("v"):rep(100) .. "\r\n\r\n",
		{ limits = { max_head = 64 } })
	tap.is(err and err.status, 431, "limit: head too large")
	_, err = run("GET / HTTP/1.1\r\nHost: h\r\nX: " .. ("v"):rep(100), { limits = { max_head = 64 }, eof = false })
	tap.is(err and err.status, 431, "limit: incomplete head too large")
	_, err = run("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 17\r\n\r\n",
		{ limits = { max_body = 16 } })
	tap.is(err and err.status, 413, "limit: content-length over max_body")
	_, err = run("POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n" ..
		"a\r\n0123456789\r\na\r\n0123456789\r\n0\r\n\r\n", { limits = { max_body = 16 } })
	tap.is(err and err.status, 413, "limit: chunked body over max_body")
	_, err = run("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 0000000000000000000005\r\n\r\nhello")
	tap.is(err, nil, "limit: leading zeros in content-length")
end)

tap.done()
