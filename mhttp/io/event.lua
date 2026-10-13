-- SPDX-License-Identifier: ISC

--[[- Streams under the `event` loop (libevent shim or event_pure).

A wait parks the running task with `event.wait`, which yields without a
tag. So it passes through `mhttp.coro` to the loop.

@module mhttp.io.event
]]

local posix = require("mhttp.io.posix")
local clock = require("mhttp.clock")

local M = {}

--[[- Makes an adapter for one event module.
@param ev the module from require("event") or require("event_pure")
@treturn table `connect`, `listen`, `serve` and `opts`
]]
function M.new(ev)
	local A = {}

	local function wait(s, mask, deadline)
		if not s.handle then
			s.handle = ev.fd.borrow(s.fd)
		end
		local us
		if deadline then
			us = math.max(0, math.floor((deadline - clock.now()) * 1e6))
		end
		local r, err = ev.wait(s.handle, mask, us)
		if r then
			return true
		end
		return nil, err
	end

	local function on_close(s)
		if s.handle then
			s.handle:cancel()
			s.handle = nil
		end
	end

	A.opts = { wait = wait, on_close = on_close }

	local function merge(opts)
		local o = { wait = wait, on_close = on_close }
		for k, v in pairs(opts or {}) do
			o[k] = v
		end
		return o
	end

	--- Same as `mhttp.io.posix.connect`, under the loop.
	function A.connect(host, port, opts)
		return posix.connect(host, port, merge(opts))
	end

	--- Same as `mhttp.io.posix.listen`, under the loop.
	function A.listen(host, port, opts)
		return posix.listen(host, port, merge(opts))
	end

	--- Wraps an fd the caller already has.
	function A.stream(fd)
		return posix.stream(fd, A.opts)
	end

	--[[- Makes a resolver for `connect`, with c-ares through the
	`resolve` and `dns` modules of the event library.
	@param loop from ev.loop(); the resolver must run in its tasks.
	It ignores the deadline: the c-ares timeouts and retries apply.
	@tparam[opt="any"] string family "inet", "inet6" or "any"
	@return the resolver, or nil and the reason when c-ares is missing
	]]
	function A.ares(loop, family)
		local ok, resolve = pcall(require, "resolve")
		if not ok then
			return nil, resolve
		end
		local handles = {}
		-- The wait function resolve.resolve_call expects.
		local function waitfunc(socks, _, timeout)
			if socks == nil then
				ev.await(loop, ev.timer(loop, timeout or 0))
				return nil
			end
			local fd, mask = socks[1], socks[2]
			handles[fd] = handles[fd] or ev.fd.borrow(fd)
			local m = (mask & resolve.WRITE) ~= 0 and "w" or "r"
			if ev.await(loop, handles[fd], m, timeout) == nil then
				return nil
			end
			return fd, mask
		end
		return function(host)
			local addrs, err = resolve.resolve_call(waitfunc, host, family)
			for fd, h in pairs(handles) do
				h:cancel()
				handles[fd] = nil
			end
			if not addrs or #addrs == 0 then
				return nil, err or "no address"
			end
			return addrs
		end
	end

	--- Accepts connections in a task and serves each in its own task.
	-- @param loop from ev.loop()
	-- @param listener from `listen`
	-- @param server a `mhttp.server`
	function A.serve(loop, listener, server)
		return loop:spawn(function()
			while true do
				local s = listener:accept()
				if not s then
					break
				end
				loop:spawn(function()
					server:serve(s)
				end)
			end
		end)
	end

	return A
end

return M
