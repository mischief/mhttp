-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local u = require("util")
local wire = require("mhttp.wire")
local headers = require("mhttp.headers")

tap.try("request head", function()
	local s = wire.request_head("GET", "/x?y", { { "Host", "h" }, { "X-A", "1" }, { "X-A", "2" } })
	tap.is(s, "GET /x?y HTTP/1.1\r\nHost: h\r\nX-A: 1\r\nX-A: 2\r\n\r\n", "request: bytes")
	local evs, err = u.run("request", s)
	tap.is(err, nil, "request: parses back")
	tap.is(evs[1].headers:get("x-a"), "1, 2", "request: fields join")
	s = wire.request_head("GET", "/", { Host = "h", Accept = { "a", "b" } })
	tap.is(s, "GET / HTTP/1.1\r\nAccept: a\r\nAccept: b\r\nHost: h\r\n\r\n", "request: map in sorted order")
end)

tap.try("response head", function()
	local s = wire.response_head(200, nil, { ["Content-Length"] = 2 })
	tap.is(s, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n", "response: default reason")
	s = wire.response_head(599, nil, {})
	tap.is(s, "HTTP/1.1 599 \r\n\r\n", "response: unknown code")
	local evs, err = u.run("response", wire.response_head(204, nil, {}))
	tap.ok(err == nil and evs[1].status == 204, "response: parses back")
end)

tap.try("injection", function()
	local cases = {
		{ "value crlf", function() return wire.request_head("GET", "/", { Host = "h", X = "a\r\nInjected: 1" }) end },
		{ "value lf", function() return wire.request_head("GET", "/", { Host = "h", X = "a\nb" }) end },
		{ "value nul", function() return wire.request_head("GET", "/", { Host = "h", X = "a\0" }) end },
		{ "name colon", function() return wire.request_head("GET", "/", { Host = "h", ["X:Y"] = "1" }) end },
		{ "name space", function() return wire.request_head("GET", "/", { Host = "h", ["X Y"] = "1" }) end },
		{ "target space", function() return wire.request_head("GET", "/ HTTP/1.1\r\nX: y", { Host = "h" }) end },
		{ "target empty", function() return wire.request_head("GET", "", { Host = "h" }) end },
		{ "method", function() return wire.request_head("GE T", "/", { Host = "h" }) end },
		{ "reason crlf", function() return wire.response_head(200, "OK\r\nX: y", {}) end },
		{ "status", function() return wire.response_head(42, nil, {}) end },
		{ "status float", function() return wire.response_head(200.5, nil, {}) end },
		{ "version", function() return wire.response_head(200, nil, {}, "2") end },
		{ "no host", function() return wire.request_head("GET", "/", {}) end },
		{ "cl and te", function() return wire.request_head("POST", "/", { Host = "h", ["Content-Length"] = 1, ["Transfer-Encoding"] = "chunked" }) end },
		{ "cl differ", function() return wire.request_head("POST", "/", { { "Host", "h" }, { "Content-Length", "1" }, { "Content-Length", "2" } }) end },
		{ "cl text", function() return wire.request_head("POST", "/", { Host = "h", ["Content-Length"] = "1x" }) end },
		{ "te not chunked", function() return wire.request_head("POST", "/", { Host = "h", ["Transfer-Encoding"] = "gzip" }) end },
		{ "204 with cl", function() return wire.response_head(204, nil, { ["Content-Length"] = 0 }) end },
		{ "1xx with te", function() return wire.response_head(100, nil, { ["Transfer-Encoding"] = "chunked" }) end },
		{ "te in 1.0", function() return wire.response_head(200, nil, { ["Transfer-Encoding"] = "chunked" }, "1.0") end },
	}
	for _, c in ipairs(cases) do
		local s, err = c[2]()
		tap.ok(s == nil and type(err) == "string", "refuses " .. c[1])
	end
end)

tap.try("headers object", function()
	local h = headers.new()
	tap.ok(not pcall(h.add, h, "X", "a\r\nb"), "headers: add refuses CRLF")
	tap.ok(not pcall(h.set, h, "X Y", "1"), "headers: set refuses bad name")
	h:add("Set-Cookie", "a=1"):add("Set-Cookie", "b=2"):add("Connection", "close, X-Hop"):add("X-Hop", "1"):add("Keep", "1")
	tap.is(h:get("set-cookie"), "a=1", "headers: set-cookie never joined")
	tap.is(#h:get_all("set-cookie"), 2, "headers: get_all")
	h:strip_hop_by_hop()
	tap.ok(not h:has("connection") and not h:has("x-hop") and h:has("keep"), "headers: strip hop-by-hop")
	tap.is(h:del("set-cookie"), 2, "headers: del count")
	tap.is(#h, 1, "headers: length")
end)

tap.try("chunks", function()
	tap.is(wire.chunk(""), "", "chunk: empty is nothing")
	tap.is(wire.chunk(("x"):rep(26)), "1a\r\n" .. ("x"):rep(26) .. "\r\n", "chunk: hex size")
	tap.is(wire.last_chunk(), "0\r\n\r\n", "last chunk")
	tap.is(wire.last_chunk({ ["X-Sum"] = "1" }), "0\r\nX-Sum: 1\r\n\r\n", "last chunk: trailers")
	tap.is(wire.last_chunk({ ["Content-Length"] = "1" }), nil, "last chunk: refuses framing trailer")
	local s = wire.request_head("POST", "/", { Host = "h", ["Transfer-Encoding"] = "chunked" }) ..
		wire.chunk("hello ") .. wire.chunk("") .. wire.chunk("world") .. wire.last_chunk({ X = "y" })
	local evs, err = u.run("request", s)
	tap.ok(err == nil and u.body(evs) == "hello world", "chunks: parse back")
end)

tap.done()
