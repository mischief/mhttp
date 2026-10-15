-- SPDX-License-Identifier: ISC
-- Fuzzes mhttp.parse and mhttp.url with mutated messages fed in random
-- pieces. Not part of the suite; run: lua5.4 test/fuzz.lua request 60
-- It reports Lua errors, a next() that never stops, and slow inputs.
package.path = "./?.lua;./?/init.lua;" .. package.path
local parse = require("mhttp.parse")
local url = require("mhttp.url")
local kind, secs, seed = arg[1] or "request", tonumber(arg[2] or 60), tonumber(arg[3] or os.time())
math.randomseed(seed)

local corpus = {
	request = {
		"GET / HTTP/1.1\r\nHost: a\r\n\r\n",
		"POST /x?y=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello",
		"POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n0\r\nT: v\r\n\r\n",
		"GET / HTTP/1.0\r\n\r\nGET /2 HTTP/1.1\r\nHost: b\r\nConnection: close\r\n\r\n",
		"GET /ws HTTP/1.1\r\nHost: a\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nrest",
		"OPTIONS * HTTP/1.1\r\nHost: a\r\n\r\n",
		"CONNECT a:443 HTTP/1.1\r\nHost: a:443\r\n\r\n",
		"GET http://a/b HTTP/1.1\r\nHost: a\r\nExpect: 100-continue\r\n\r\n",
	},
	response = {
		"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n",
		"HTTP/1.0 200 OK\r\n\r\nbody until close",
		"HTTP/1.1 101 Switching Protocols\r\nUpgrade: x\r\nConnection: upgrade\r\n\r\nraw",
		"HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n",
		"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n",
	},
}
local SPICE = { "\r\n", "\n", "\r", "\0", " ", "\t", ":", ";", ",", "chunked", "Content-Length: ",
	"Transfer-Encoding: ", "99999999999999999999", "-1", "0x10", "%", "%00", "\255\254", ("A"):rep(9000),
	"HTTP/1.1", "HTTP/9.9", "\r\n\r\n", "0\r\n\r\n", "ffffffffffffffff\r\n" }

local function mutate(s)
	for _ = 1, math.random(1, 6) do
		local n = #s
		local i = math.random(1, math.max(1, n))
		local r = math.random(1, 6)
		if r == 1 and n > 0 then
			s = s:sub(1, i - 1) .. string.char(math.random(0, 255)) .. s:sub(i + 1)
		elseif r == 2 then
			s = s:sub(1, i - 1) .. SPICE[math.random(#SPICE)] .. s:sub(i)
		elseif r == 3 and n > 1 then
			local j = math.min(n, i + math.random(0, 20))
			s = s:sub(1, i - 1) .. s:sub(j + 1)
		elseif r == 4 and n > 1 then
			local j = math.min(n, i + math.random(0, 40))
			s = s:sub(1, j) .. s:sub(i, j) .. s:sub(j + 1)
		elseif r == 5 then
			s = s:gsub("\r\n", math.random(2) == 1 and "\n" or "\r\r\n", math.random(0, 3))
		else
			s = s .. s
		end
	end
	return s
end

local function run(s)
	local p = parse.new(kind)
	local pos, events = 1, 0
	while pos <= #s do
		local n = math.random(1, 64)
		p:feed(s:sub(pos, pos + n - 1))
		pos = pos + n
		while true do
			local ev, err = p:next()
			events = events + 1
			if events > 100000 then
				error("next() did not stop")
			end
			if not ev then
				if err and err.code ~= "more" and err.code ~= "need" then
					return
				end
				break
			end
			if ev.target then
				url.parse(ev.target)
			end
		end
	end
	p:eof()
	for _ = 1, 1000 do
		if not p:next() then
			break
		end
	end
end

local cases, bad, slow, t_end = 0, 0, 0, os.clock() + secs
while os.clock() < t_end do
	local base = corpus[kind][math.random(#corpus[kind])]
	local s = mutate(base)
	local t0 = os.clock()
	local ok, err = pcall(run, s)
	local dt = os.clock() - t0
	cases = cases + 1
	if not ok then
		bad = bad + 1
		if bad <= 5 then
			io.write(("ERROR: %s\n  input %q\n"):format(tostring(err), s:sub(1, 300)))
		end
	elseif dt > 0.05 then
		slow = slow + 1
		if slow <= 3 then
			io.write(("SLOW %.3fs: %q\n"):format(dt, s:sub(1, 200)))
		end
	end
end
print(("%s: %d cases, %d errors, %d slow, seed %d"):format(kind, cases, bad, slow, seed))
