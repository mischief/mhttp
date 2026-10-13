-- SPDX-License-Identifier: ISC
-- Inputs that one parser could frame two ways. Every one is an error.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local u = require("util")

local H = "POST / HTTP/1.1\r\nHost: h\r\n"
local CHUNKED = "5\r\nhello\r\n0\r\n\r\n"

local cases = {
	{ "cl then te", H .. "Content-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n" .. CHUNKED, 400 },
	{ "te then cl", H .. "Transfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n" .. CHUNKED, 400 },
	{ "space before colon", H .. "Transfer-Encoding : chunked\r\n\r\n" .. CHUNKED, 400 },
	{ "tab before colon", H .. "Transfer-Encoding\t: chunked\r\n\r\n" .. CHUNKED, 400 },
	{ "obs-fold", H .. "X: a\r\n chunked\r\n\r\n", 400 },
	{ "obs-fold te", H .. "Transfer-Encoding:\r\n chunked\r\n\r\n" .. CHUNKED, 400 },
	{ "leading space field", "POST / HTTP/1.1\r\n Host: h\r\n\r\n", 400 },
	{ "xchunked", H .. "Transfer-Encoding: xchunked\r\n\r\n", 400 },
	{ "chunked twice", H .. "Transfer-Encoding: chunked, chunked\r\n\r\n" .. CHUNKED, 400 },
	{ "chunked then identity", H .. "Transfer-Encoding: chunked\r\nTransfer-Encoding: identity\r\n\r\n", 400 },
	{ "gzip, chunked", H .. "Transfer-Encoding: gzip, chunked\r\n\r\n" .. CHUNKED, 501 },
	{ "te quoted", H .. "Transfer-Encoding: \"chunked\"\r\n\r\n", 501 },
	{ "te in 1.0", "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n" .. CHUNKED, 400 },
	{ "empty te", H .. "Transfer-Encoding: \r\n\r\n", 400 },
	{ "cl list differs", H .. "Content-Length: 1, 2\r\n\r\nxx", 400 },
	{ "cl fields differ", H .. "Content-Length: 1\r\nContent-Length: 2\r\n\r\nxx", 400 },
	{ "cl plus", H .. "Content-Length: +5\r\n\r\nhello", 400 },
	{ "cl minus", H .. "Content-Length: -1\r\n\r\n", 400 },
	{ "cl hex", H .. "Content-Length: 0x5\r\n\r\nhello", 400 },
	{ "cl inner space", H .. "Content-Length: 5 5\r\n\r\nhello", 400 },
	{ "cl decimal", H .. "Content-Length: 5.0\r\n\r\nhello", 400 },
	{ "cl empty", H .. "Content-Length: \r\n\r\n", 400 },
	{ "cl huge", H .. "Content-Length: 99999999999999999999999\r\n\r\n", 413 },
	{ "bare lf", "GET / HTTP/1.1\nHost: h\n\n", 400 },
	{ "bare lf in fields", "GET / HTTP/1.1\r\nHost: h\nX: y\r\n\r\n", 400 },
	{ "bare cr", "GET / HTTP/1.1\rHost: h\r\n\r\n", 400 },
	{ "cr in value", H .. "X: a\rb\r\n\r\n", 400 },
	{ "nul in value", H .. "X: a\0b\r\n\r\n", 400 },
	{ "nul in target", "GET /\0 HTTP/1.1\r\nHost: h\r\n\r\n", 400 },
	{ "space in name", H .. "X Y: z\r\n\r\n", 400 },
	{ "empty name", H .. ": z\r\n\r\n", 400 },
	{ "no colon", H .. "Xyz\r\n\r\n", 400 },
	{ "no host", "GET / HTTP/1.1\r\n\r\n", 400 },
	{ "two hosts", "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", 400 },
	{ "host list", "GET / HTTP/1.1\r\nHost: a, b\r\n\r\n", 400 },
	{ "host userinfo", "GET / HTTP/1.1\r\nHost: u@a\r\n\r\n", 400 },
	{ "host path", "GET / HTTP/1.1\r\nHost: a/b\r\n\r\n", 400 },
	{ "double space", "GET  / HTTP/1.1\r\nHost: h\r\n\r\n", 400 },
	{ "trailing space", "GET / HTTP/1.1 \r\nHost: h\r\n\r\n", 400 },
	{ "tab separator", "GET\t/ HTTP/1.1\r\nHost: h\r\n\r\n", 400 },
	{ "lower case version", "GET / http/1.1\r\nHost: h\r\n\r\n", 400 },
	{ "http/2", "GET / HTTP/2.0\r\nHost: h\r\n\r\n", 505 },
	{ "two digit version", "GET / HTTP/1.10\r\nHost: h\r\n\r\n", 400 },
	{ "bad method", "G(T / HTTP/1.1\r\nHost: h\r\n\r\n", 400 },
	{ "fragment in target", "GET /#x HTTP/1.1\r\nHost: h\r\n\r\n", 400 },
	{ "obs-text in target", "GET /\200 HTTP/1.1\r\nHost: h\r\n\r\n", 400 },
	{ "chunk size 0x", H .. "Transfer-Encoding: chunked\r\n\r\n0x5\r\nhello\r\n0\r\n\r\n", 400 },
	{ "chunk size minus", H .. "Transfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n", 400 },
	{ "chunk size space", H .. "Transfer-Encoding: chunked\r\n\r\n 5\r\nhello\r\n0\r\n\r\n", 400 },
	{ "chunk size trailing space", H .. "Transfer-Encoding: chunked\r\n\r\n5 \r\nhello\r\n0\r\n\r\n", 400 },
	{ "chunk size overflow", H .. "Transfer-Encoding: chunked\r\n\r\nffffffffffffffffff\r\n", 413 },
	{ "chunk size bare lf", H .. "Transfer-Encoding: chunked\r\n\r\n5\nhello\r\n0\r\n\r\n", 400 },
	{ "chunk no crlf", H .. "Transfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n", 400 },
	{ "chunk too long", H .. "Transfer-Encoding: chunked\r\n\r\n3\r\nhello\r\n0\r\n\r\n", 400 },
	{ "chunk ext bad", H .. "Transfer-Encoding: chunked\r\n\r\n5;=x\r\nhello\r\n0\r\n\r\n", 400 },
	{ "chunk ext open quote", H .. "Transfer-Encoding: chunked\r\n\r\n5;a=\"x\r\nhello\r\n0\r\n\r\n", 400 },
	{ "trailer obs-fold", H .. "Transfer-Encoding: chunked\r\n\r\n0\r\nX: a\r\n b\r\n\r\n", 400 },
	{ "trailer bad name", H .. "Transfer-Encoding: chunked\r\n\r\n0\r\nX Y: a\r\n\r\n", 400 },
}

for _, c in ipairs(cases) do
	local name, input, status = c[1], c[2], c[3]
	for _, step in ipairs({ #input, 1 }) do
		local _, err = u.run("request", input, { step = step })
		local label = ("%s (step %d)"):format(name, step)
		if not tap.is(err and err.status, status, label) and err then
			tap.diag(err.code .. ": " .. err.message)
		end
	end
end

-- A request that is fine must stay fine.
local evs, err = u.run("request", H .. "Content-Length: 5, 5\r\nContent-Length: 5\r\n\r\nhello")
tap.ok(err == nil and u.body(evs) == "hello", "same content-length values are accepted")
evs, err = u.run("request", H .. "X: a\tb \t\r\n\r\n")
tap.ok(err == nil and evs[1].headers:get("x") == "a\tb", "tab inside a value, trimmed at the ends")
evs, err = u.run("request", H .. "X: caf\195\169\r\n\r\n")
tap.ok(err == nil, "obs-text in a value")

-- Smuggled bytes after a rejected head must never become a request.
evs = u.run("request", H .. "Content-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n" ..
	"0\r\n\r\nGET /admin HTTP/1.1\r\nHost: h\r\n\r\n")
tap.is(#evs, 0, "nothing after a framing error")

tap.done()
