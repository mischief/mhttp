-- SPDX-License-Identifier: ISC
-- Parser and serializer speed in memory, with no sockets.
package.path = "./?.lua;./?/init.lua;" .. package.path

local parse = require("mhttp.parse")
local wire = require("mhttp.wire")

local N = tonumber(arg[1]) or 20000

local req = "GET /api/v1/items?limit=10 HTTP/1.1\r\nHost: localhost:8080\r\n" ..
	"User-Agent: mhttp-bench/0.1\r\nAccept: application/json\r\n" ..
	"Accept-Encoding: gzip, deflate\r\nConnection: keep-alive\r\n\r\n"
local res = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ..
	"Content-Length: 13\r\nDate: Tue, 13 Oct 2026 00:00:00 GMT\r\n\r\n{\"ok\": true}\n"
local chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ..
	("400\r\n" .. ("x"):rep(1024) .. "\r\n"):rep(64) .. "0\r\n\r\n"

local function report(name, n, bytes, t)
	print(("%-22s %9.0f msg/s %8.1f MB/s"):format(name, n / t, bytes / t / 1e6))
end

local function bench(name, kind, msg, n)
	local input = msg:rep(n)
	local t0 = os.clock()
	local p = parse.new(kind)
	p:feed(input)
	p:eof()
	local done = 0
	while true do
		local ev, err = p:next()
		if not ev then
			assert(not err or err.code == "eof", err and err.message)
			break
		end
		if ev.type == "done" then
			done = done + 1
		end
	end
	assert(done == n, "parsed " .. done)
	report(name, n, #input, os.clock() - t0)
end

-- Feeds 1 KiB at a time, as a socket would.
local function bench_fed(name, kind, msg, n)
	local input = msg:rep(n)
	local t0 = os.clock()
	local p = parse.new(kind)
	local done = 0
	for i = 1, #input, 1024 do
		p:feed(input:sub(i, i + 1023))
		while true do
			local ev = p:next()
			if not ev then
				break
			end
			if ev.type == "done" then
				done = done + 1
			end
		end
	end
	assert(done == n, "parsed " .. done)
	report(name, n, #input, os.clock() - t0)
end

bench("request pipelined", "request", req, N)
bench_fed("request fed 1k", "request", req, N)
bench("response pipelined", "response", res, N)
bench("response chunked 64k", "response", chunked, N // 50)

local t0 = os.clock()
local bytes = 0
for _ = 1, N do
	local s = wire.response_head(200, nil, {
		{ "Content-Type", "application/json" }, { "Content-Length", "13" },
	})
	bytes = bytes + #s
end
report("response_head", N, bytes, os.clock() - t0)
