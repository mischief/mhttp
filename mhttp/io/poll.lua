-- SPDX-License-Identifier: ISC

--[[- A small scheduler over poll(2), for many connections in one process.

Each task is a coroutine. A stream wait parks the task, and the loop
polls the fds of all parked tasks at once. It needs only luaposix.

	local loop = require("mhttp.io.poll").new()
	local l = assert(loop:listen("127.0.0.1", 8080))
	loop:serve(l, server)
	loop:run()

Each pass of the loop builds the poll set again, so a pass costs time in
proportion to the number of parked tasks. That is fine for some
thousands of connections. Use `mhttp.io.event` for more.

A wait outside a task of the loop blocks the process, as in
`mhttp.io.posix`.

@module mhttp.io.poll
]]

local posix = require("mhttp.io.posix")
local clock = require("mhttp.clock")
local ppoll = require("posix.poll")
local errno = require("posix.errno")

local M = {}

-- Marks the yields of this module, so that other yields are an error.
local TAG = {}

local Loop = {}
Loop.__index = Loop

--- Makes a loop.
-- @tparam[opt] table opts `on_error(err, task)` for a task that fails
-- (default: write the traceback to stderr); `max_run`, seconds a task
-- may run without a yield before it fails, so that one stuck task does
-- not stop the others (none)
-- @treturn Loop
function M.new(opts)
	opts = opts or {}
	local loop = setmetatable({
		ready = {},
		parked = {},
		count = 0,
		max_run = opts.max_run,
		on_error = opts.on_error or function(err)
			io.stderr:write("mhttp.io.poll: ", tostring(err), "\n")
		end,
	}, Loop)
	loop.opts = {
		wait = function(s, mask, deadline)
			return loop:wait(s, mask, deadline)
		end,
		on_close = function(s)
			loop:closing(s.fd)
		end,
	}
	return loop
end

-- Makes a parked task ready. Its wait returns the values.
function Loop:ready_task(co, ...)
	self.parked[co] = nil
	self.ready[#self.ready + 1] = table.pack(co, ...)
end

--- Makes a task in `suspend` ready. `suspend` returns the values.
-- @treturn boolean false when the task is not in `suspend`
function Loop:wake(co, ...)
	local p = self.parked[co]
	if not (p and p.suspended) then
		return false
	end
	self:ready_task(co, ...)
	return true
end

--- Starts fn(...) in a new task. It runs on a later pass of the loop.
-- @treturn thread the task
function Loop:spawn(fn, ...)
	local co = coroutine.create(fn)
	self.count = self.count + 1
	self.ready[#self.ready + 1] = table.pack(co, ...)
	return co
end

--- Parks the running task until another task calls `wake` on it.
-- @return the values given to `wake`
function Loop:suspend()
	assert(self.current, "suspend outside a task")
	return coroutine.yield(TAG, nil, nil, nil, true)
end

--- Tells whether the caller runs in a task of this loop.
function Loop:intask()
	return self.current ~= nil
end

--[[- Parks the running task until fd is ready or the deadline passes.
This is the wait hook of the streams that `stream`, `connect` and
`listen` make.
@param s a stream or a listener, with field fd
@tparam string mask "r" or "w"
@tparam[opt] number deadline from `mhttp.clock`
@return true, or nil and "timeout" or "closed"
]]
function Loop:wait(s, mask, deadline)
	if not self.current then
		return posix.poll_wait(s, mask, deadline)
	end
	return coroutine.yield(TAG, s.fd, mask, deadline)
end

--- Parks the running task for sec seconds.
function Loop:sleep(sec)
	local deadline = clock.after(sec)
	if not self.current then
		ppoll.poll({}, math.max(0, math.ceil(sec * 1000)))
		return
	end
	coroutine.yield(TAG, nil, nil, deadline)
end

-- Wakes the tasks that wait on fd before the fd closes. A new fd can
-- get the same number at once, and a poll on it would be wrong.
function Loop:closing(fd)
	for co, p in pairs(self.parked) do
		if p.fd == fd then
			self:ready_task(co, nil, "closed")
		end
	end
end

-- The count hook of max_run. It raises an error in a task that has run
-- too long since its resume.
local function watchdog(loop)
	return function()
		if loop.since and clock.now() - loop.since > loop.max_run then
			loop.since = nil
			error(("task ran %g seconds without a yield"):format(loop.max_run), 2)
		end
	end
end

-- Resumes one task and parks it again when it yields.
function Loop:step(r)
	local co = r[1]
	self.current = co
	if self.max_run then
		self.watchdog = self.watchdog or watchdog(self)
		self.since = clock.now()
		debug.sethook(co, self.watchdog, "", 1000000)
	end
	local out = table.pack(coroutine.resume(co, table.unpack(r, 2, r.n)))
	self.since = nil
	self.current = nil
	if not out[1] then
		self.count = self.count - 1
		self.on_error(debug.traceback(co, tostring(out[2])), co)
	elseif coroutine.status(co) == "dead" then
		self.count = self.count - 1
	elseif out[2] ~= TAG then
		self.count = self.count - 1
		self.on_error("a task yielded outside mhttp.io.poll; use mhttp.coro", co)
	else
		self.parked[co] = { fd = out[3], mask = out[4], deadline = out[5], suspended = out[6] }
	end
end

-- Polls the parked tasks once, at most until the first deadline.
function Loop:poll()
	local fds, deadline = {}, nil
	for _, p in pairs(self.parked) do
		if p.fd then
			local f = fds[p.fd]
			if not f then
				f = { events = {} }
				fds[p.fd] = f
			end
			f.events[p.mask == "r" and "IN" or "OUT"] = true
		end
		deadline = clock.min(deadline, p.deadline)
	end
	local ms = -1
	if #self.ready > 0 then
		ms = 0
	elseif deadline then
		ms = math.max(0, math.ceil((deadline - clock.now()) * 1000))
	end
	local n, err, en = ppoll.poll(fds, ms)
	if n == nil and en ~= errno.EINTR then
		error("poll: " .. tostring(err))
	end
	local now, expired = clock.now(), {}
	for co, p in pairs(self.parked) do
		local re = p.fd and fds[p.fd].revents
		if re and (re.ERR or re.HUP or re.NVAL or re[p.mask == "r" and "IN" or "OUT"]) then
			self:ready_task(co, true)
		elseif p.deadline and now >= p.deadline then
			expired[#expired + 1] = { co = co, p = p }
		end
	end
	-- A late poll can pass several deadlines. Keep their order.
	table.sort(expired, function(a, b)
		return a.p.deadline < b.p.deadline
	end)
	for _, e in ipairs(expired) do
		if e.p.fd then
			self:ready_task(e.co, nil, "timeout")
		else
			self:ready_task(e.co)
		end
	end
end

--- Runs the tasks until none is left or `stop` is called.
function Loop:run()
	self.stopping = false
	while self.count > 0 and not self.stopping do
		local ready = self.ready
		self.ready = {}
		for _, r in ipairs(ready) do
			self:step(r)
		end
		if self.count > 0 and not self.stopping then
			self:poll()
		end
	end
end

--- Makes `run` return after the current pass. Parked tasks stay parked.
function Loop:stop()
	self.stopping = true
end

local function merge(loop, opts)
	local o = { wait = loop.opts.wait, on_close = loop.opts.on_close }
	for k, v in pairs(opts or {}) do
		o[k] = v
	end
	return o
end

--- Same as `mhttp.io.posix.connect`, under the loop.
function Loop:connect(host, port, opts)
	return posix.connect(host, port, merge(self, opts))
end

--- Same as `mhttp.io.posix.listen`, under the loop.
function Loop:listen(host, port, opts)
	return posix.listen(host, port, merge(self, opts))
end

--- Wraps an fd the caller already has.
function Loop:stream(fd)
	return posix.stream(fd, self.opts)
end

--[[- Accepts connections in a task and serves each in its own task.

The accept task ends when the listener closes. Other accept errors go
to on_error, and the task tries again after 0.1 seconds.

@param listener from `listen`
@param server a `mhttp.server`
@tparam[opt] table opts `max`: connections at once; at the limit the
accept task waits for one to end. `gate`: a table `{max = n}` shared by
several serve calls, to limit their connections together.
@treturn thread the accept task
]]
function Loop:serve(listener, server, opts)
	local max = opts and opts.max or math.huge
	local gate = opts and opts.gate
	if gate then
		gate.n, gate.waiting = gate.n or 0, gate.waiting or {}
	end
	local active, acceptor, logged = 0, nil, -math.huge
	local function conn(s)
		local ok, err = xpcall(server.serve, debug.traceback, server, s)
		active = active - 1
		self:wake(acceptor)
		if gate then
			gate.n = gate.n - 1
			for t in pairs(gate.waiting) do
				gate.waiting[t] = nil
				self:wake(t)
			end
		end
		if not ok then
			error(err, 0)
		end
	end
	local function full()
		return active >= max or gate and gate.n >= gate.max
	end
	acceptor = self:spawn(function()
		while true do
			while full() do
				if gate then
					gate.waiting[acceptor] = true
				end
				self:suspend()
			end
			local s, err = listener:accept()
			-- Another listener can fill the gate while this one waits
			-- in accept. The new connection then waits for a place.
			while s and full() do
				if gate then
					gate.waiting[acceptor] = true
				end
				self:suspend()
			end
			if s then
				active = active + 1
				if gate then
					gate.n = gate.n + 1
				end
				self:spawn(conn, s)
			elseif not listener.fd then
				break
			else
				-- Such as EMFILE. Wait for other tasks to close fds, and
				-- log once in 10 seconds at most.
				if clock.now() - logged >= 10 then
					logged = clock.now()
					self.on_error("accept: " .. tostring(err))
				end
				self:sleep(0.1)
			end
		end
	end)
	return acceptor
end

return M
