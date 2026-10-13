-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local coro = require("mhttp.coro")

-- A toy scheduler: a task yields ("io", n) and gets n * 2 back.
local function run_task(f)
	local co = coroutine.create(f)
	local r = table.pack(coroutine.resume(co))
	local ios = 0
	while coroutine.status(co) ~= "dead" do
		assert(r[1], r[2])
		assert(r[2] == "io", "scheduler got a yield that is not io: " .. tostring(r[2]))
		ios = ios + 1
		r = table.pack(coroutine.resume(co, r[3] * 2))
	end
	assert(r[1], r[2])
	return ios, table.unpack(r, 2, r.n)
end

local function io(n)
	return coroutine.yield("io", n)
end

tap.try("passthrough", function()
	local ios, out = run_task(function()
		local gen = coro.wrap(function()
			for i = 1, 3 do
				coro.yield(io(i))
			end
		end)
		return { gen(), gen(), gen() }
	end)
	tap.is(ios, 3, "io yields reach the scheduler")
	tap.is(table.concat(out, ","), "2,4,6", "generator values and io answers")
end)

tap.try("nested", function()
	local ios, out = run_task(function()
		local outer = coro.wrap(function()
			local inner = coro.wrap(function()
				coro.yield(io(10))
				coro.yield(io(20))
			end)
			coro.yield(inner() + io(1))
			coro.yield(inner() + io(2))
		end)
		return outer() .. "," .. outer()
	end)
	tap.is(ios, 4, "nested: io yields from two levels")
	tap.is(out, "22,44", "nested: values")
end)

tap.try("plain coroutine.wrap breaks", function()
	local ok = pcall(run_task, function()
		local gen = coroutine.wrap(function()
			coroutine.yield(io(1))
		end)
		return gen()
	end)
	tap.ok(ok, "plain wrap: no crash, but the io yield never reached the scheduler")
end)

tap.try("errors", function()
	local gen = coro.wrap(function()
		error("boom")
	end)
	local ok, err = pcall(gen)
	tap.ok(not ok and err:find("boom") and err:find("traceback"), "error carries a traceback")
	tap.ok(not pcall(coro.yield, 1), "yield outside an mhttp.coro coroutine raises")
	local co = coro.create(function(a)
		local b = coro.yield(a + 1)
		return b * 10
	end)
	local _, v = coro.resume(co, 1)
	tap.is(v, 2, "resume: first value")
	local _, w = coro.resume(co, 5)
	tap.is(w, 50, "resume: return value")
	tap.is(coro.status(co), "dead", "resume: dead")
end)

tap.done()
