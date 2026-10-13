-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local u = require("util")

local function run(input, opts)
	return u.run("response", input, opts)
end

tap.try("content-length", function()
	local evs, err = run("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi", { step = 1 })
	tap.is(err, nil, "cl: no error")
	tap.is(evs[1].status, 200, "cl: status")
	tap.is(evs[1].reason, "OK", "cl: reason")
	tap.is(u.body(evs), "hi", "cl: body")
end)

tap.try("chunked and codings", function()
	local evs, err = run("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n")
	tap.is(err, nil, "gzip,chunked: no error")
	tap.is(evs[1].codings[1], "gzip", "gzip,chunked: coding left for the caller")
	tap.is(u.body(evs), "hi", "gzip,chunked: chunked decoded")
	evs, err = run("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nraw bytes")
	tap.is(err, nil, "gzip only: no error")
	tap.is(evs[1].framing, "close", "gzip only: read until close")
	tap.is(u.body(evs), "raw bytes", "gzip only: body")
end)

tap.try("close delimited", function()
	local evs, err = run("HTTP/1.1 200 OK\r\n\r\nall of it", { step = 2 })
	tap.is(err, nil, "close: no error")
	tap.is(evs[1].keep_alive, false, "close: not persistent")
	tap.is(u.summary(evs), "head 200 close false|data all of it|done", "close: events")
	evs, err = run("HTTP/1.1 200 OK\r\n\r\npartial", { eof = false })
	tap.is(u.summary(evs), "head 200 close false|data partial", "close: no done before eof")
end)

tap.try("bodiless responses", function()
	local evs, err = run("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n" ..
		"HTTP/1.1 204 No Content\r\n\r\nHTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\n",
		{ methods = { "HEAD", "GET", "GET" } })
	tap.is(err, nil, "bodiless: no error")
	tap.is(u.summary(evs), "head 200 none true|done|head 204 none true|done|head 304 none true|done",
		"bodiless: HEAD, 204 and 304 have no body")
end)

tap.try("informational", function()
	local evs, err = run("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </s>\r\n\r\n" ..
		"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx", { methods = { "POST" } })
	tap.is(err, nil, "1xx: no error")
	tap.is(u.summary(evs), "head 100 none true|head 103 none true|head 200 length true|data x|done",
		"1xx: heads, then the final response")
	tap.ok(evs[1].informational, "1xx: marked informational")
end)

tap.try("tunnels", function()
	local evs, err, p = run("HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\nframes",
		{ eof = false })
	tap.is(err, nil, "101: no error")
	tap.is(u.summary(evs), "head 101 tunnel true|done tunnel", "101: tunnel")
	tap.is(evs[1].upgrade[1], "websocket", "101: upgrade")
	tap.is(p:rest(), "frames", "101: rest")
	evs, err, p = run("HTTP/1.1 200 Connection established\r\n\r\ntls", { methods = { "CONNECT" }, eof = false })
	tap.is(u.summary(evs), "head 200 tunnel true|done tunnel", "connect: tunnel")
	tap.is(p:rest(), "tls", "connect: rest")
end)

tap.try("status lines", function()
	local evs, err = run("HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n")
	tap.ok(err == nil and evs[1].reason == "", "status: no reason phrase")
	evs, err = run("HTTP/1.1 200 \r\nContent-Length: 0\r\n\r\n")
	tap.ok(err == nil and evs[1].reason == "", "status: empty reason phrase")
	for _, bad in ipairs({ "HTTP/1.1 20 OK", "HTTP/1.1 200OK", "HTTP/1.1 099 x", "HTTP/2 200 OK",
		"http/1.1 200 OK", "HTTP/1.1 200 O\0K", "HTTP/1.1  200 OK" }) do
		_, err = run(bad .. "\r\n\r\n")
		tap.ok(err ~= nil and err.status == nil, "status: refuses " .. ("%q"):format(bad))
	end
end)

tap.try("framing errors", function()
	local _, err = run("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n")
	tap.is(err and err.code, "framing", "te with cl")
	_, err = run("HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
	tap.is(err and err.code, "framing", "te in 1.0")
	_, err = run("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc")
	tap.is(err and err.code, "truncated", "short body")
	_, err = run("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n")
	tap.is(err and err.code, "framing", "differing content-length")
	_, err = run("HTTP/1.1 200 OK\r\n\r\n" .. ("x"):rep(20), { limits = { max_body = 10 } })
	tap.is(err and err.code, "body", "close-delimited over max_body")
end)

tap.done()
