-- SPDX-License-Identifier: ISC
-- The parser must give the same events however the input is split,
-- and must never raise on bad input.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local u = require("util")

local requests = {
	"GET / HTTP/1.1\r\nHost: h\r\n\r\n",
	"\r\nPOST /a?b HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhelloGET /2 HTTP/1.1\r\nHost: h\r\n\r\n",
	"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n3;a=b\r\nabc\r\n1\r\nd\r\n0\r\nT: 1\r\n\r\n",
	"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\nGET / HTTP/1.0\r\n\r\n",
}
local responses = {
	"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc",
	"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\nHTTP/1.1 200 OK\r\n\r\nrest",
}

local function outcome(kind, input, step)
	local evs, err = u.run(kind, input, { step = step })
	return u.summary(evs) .. (err and (" ! " .. tostring(err.status)) or "")
end

for _, set in ipairs({ { "request", requests }, { "response", responses } }) do
	for i, input in ipairs(set[2]) do
		local want = outcome(set[1], input)
		local same = true
		for step = 1, #input do
			local got = outcome(set[1], input, step)
			if got ~= want then
				tap.diag(("step %d: %s\nwant %s"):format(step, got, want))
				same = false
				break
			end
		end
		tap.ok(same and not want:find("!"), ("%s %d: every split"):format(set[1], i))
	end
end

-- Mutations: no raise, and an error is a table with a code.
local seed = tonumber(os.getenv("MHTTP_SEED")) or 1
math.randomseed(seed)
local alphabet = { "\r", "\n", "\0", " ", "\t", ":", ";", ",", "0", "f", "\r\n", "chunked",
	"Content-Length: 1\r\n", "Transfer-Encoding: chunked\r\n", "\255" }

local function mutate(s)
	for _ = 1, math.random(1, 4) do
		local i = math.random(1, #s + 1)
		local r = math.random(1, 4)
		if r == 1 then
			s = s:sub(1, i - 1) .. s:sub(i + 1)
		elseif r == 2 then
			s = s:sub(1, i - 1) .. alphabet[math.random(#alphabet)] .. s:sub(i)
		elseif r == 3 then
			s = s:sub(1, i - 1) .. string.char(math.random(0, 255)) .. s:sub(i + 1)
		else
			local j = math.random(i, #s + 1)
			s = s:sub(1, j) .. s:sub(i, j) .. s:sub(j + 1)
		end
	end
	return s
end

local raised, badref, differ = 0, 0, 0
for n = 1, 4000 do
	local kind = n % 2 == 0 and "request" or "response"
	local corpus = kind == "request" and requests or responses
	local input = mutate(corpus[math.random(#corpus)])
	local ok, evs, err = pcall(u.run, kind, input, { step = math.random(1, 7) })
	if not ok then
		raised = raised + 1
		if raised < 4 then
			tap.diag(("raised on %q: %s"):format(input, evs))
		end
	elseif err and (type(err) ~= "table" or type(err.code) ~= "string") then
		badref = badref + 1
	else
		-- Whole and split runs agree on whether there is an error.
		local _, err2 = u.run(kind, input)
		if (err == nil) ~= (err2 == nil) then
			differ = differ + 1
			if differ < 4 then
				tap.diag(("split changes the result on %q"):format(input))
			end
		end
	end
end
tap.is(raised, 0, "mutations: never raise (seed " .. seed .. ")")
tap.is(badref, 0, "mutations: errors are tables with a code")
tap.is(differ, 0, "mutations: split does not change the result")

-- A slow sender must not cost CPU in the square of its bytes. These
-- took seconds before; the bounds leave room for slow machines.
do
	local parse = require("mhttp.parse")
	local p = parse.new("request")
	p:feed("GET / HTTP/1.1\r\nX: ")
	local t0, failed = os.clock(), false
	for _ = 1, 70000 do
		p:feed("A")
		local _, err = p:next()
		if err then
			failed = true
			break
		end
	end
	tap.ok(failed and os.clock() - t0 < 2, "one byte at a time up to the head limit is cheap")

	p = parse.new("request")
	p:feed("GET / HTTP/1.1\r\n")
	local line = ("x: " .. ("a"):rep(1700) .. "\r\n")
	t0 = os.clock()
	for _ = 1, 36 do
		for k = 1, #line, 8 do
			p:feed(line:sub(k, k + 7))
			p:next()
		end
	end
	tap.ok(os.clock() - t0 < 2, "an unfinished head in small pieces is cheap")
end

tap.done()
