-- SPDX-License-Identifier: ISC

--[[- Coroutines that nest under any scheduler.

A scheduler resumes a task, and the task yields when its I/O must wait.
A plain coroutine.wrap inside that task takes those yields itself, and
the scheduler never sees them. These coroutines tag their own yields
instead. A yield without the tag goes on to the outer resumer, and its
answer comes back down. So a scheduler needs no change, and nesting
works at any depth.

Use `yield` from this module inside `wrap` and `create`, never
coroutine.yield.

@module mhttp.coro
]]

local M = {}

-- The tag of each coroutine made here, by coroutine.
local tags = setmetatable({}, { __mode = "k" })

local pack, unpack = table.pack, table.unpack

--- Yields values to whoever resumed this coroutine with `resume`.
-- @raise when the running coroutine was not made by this module
function M.yield(...)
	local tag = tags[coroutine.running()]
	if not tag then
		error("mhttp.coro.yield outside an mhttp.coro coroutine", 2)
	end
	return coroutine.yield(tag, ...)
end

--- Makes a coroutine for `resume`.
-- @tparam function f
-- @treturn thread
function M.create(f)
	local co = coroutine.create(f)
	tags[co] = {}
	return co
end

--[[- Resumes co until it yields with `yield`, returns or fails.

Other yields pass to the outer resumer. The outer answer goes back into
co. Call it from inside a scheduler task when co does I/O.

@tparam thread co from `create`
@return true and the values, or false and the error, as coroutine.resume
]]
function M.resume(co, ...)
	local tag = tags[co]
	if not tag then
		error("mhttp.coro.resume of a coroutine not made by create", 2)
	end
	local r = pack(coroutine.resume(co, ...))
	while true do
		if not r[1] then
			return false, r[2]
		end
		if coroutine.status(co) == "dead" then
			return unpack(r, 1, r.n)
		end
		if r[2] == tag then
			return true, unpack(r, 3, r.n)
		end
		-- Not ours: pass it up, and the answer back down.
		r = pack(coroutine.resume(co, coroutine.yield(unpack(r, 2, r.n))))
	end
end

--[[- Like coroutine.wrap, with passthrough.

An error inside f is raised again with the traceback of f.

@tparam function f
@treturn function
]]
function M.wrap(f)
	local co = M.create(f)
	return function(...)
		local r = pack(M.resume(co, ...))
		if not r[1] then
			error(debug.traceback(co, tostring(r[2])), 0)
		end
		return unpack(r, 2, r.n)
	end
end

--- Tells the status of co, as coroutine.status.
M.status = coroutine.status

return M
