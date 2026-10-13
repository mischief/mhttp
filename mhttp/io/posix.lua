-- SPDX-License-Identifier: ISC

--[[- Streams over sockets with luaposix.

A stream keeps its fd in non-blocking mode. When a call would block it
calls `wait(stream, mask, deadline)`. The default wait blocks in poll(2)
on that one fd. A scheduler passes its own wait, which parks the task;
see `mhttp.io.event`.

Name lookup uses a `resolve` hook when one is given, else getaddrinfo,
which blocks. Plain TCP only: a `tls` option is an error here.

@module mhttp.io.posix
]]

local socket = require("posix.sys.socket")
local unistd = require("posix.unistd")
local fcntl = require("posix.fcntl")
local errno = require("posix.errno")
local ppoll = require("posix.poll")
local signal = require("posix.signal")
local clock = require("mhttp.clock")

local M = {}

local EAGAIN, EWOULDBLOCK, EINTR = errno.EAGAIN, errno.EWOULDBLOCK, errno.EINTR
local EINPROGRESS = errno.EINPROGRESS

-- luaposix has no SO_REUSEPORT constant. These are the system values.
M.SO_REUSEPORT = socket.SO_REUSEPORT or (function()
	local ok, uts = pcall(require, "posix.sys.utsname")
	local sys = ok and uts.uname().sysname or ""
	if sys == "Linux" then
		return 15
	elseif sys:find("BSD$") or sys == "Darwin" or sys == "DragonFly" then
		return 0x200
	end
end)()

local function wouldblock(en)
	return en == EAGAIN or en == EWOULDBLOCK
end

--- Ignores SIGPIPE for the process, so a write to a closed peer gives
-- an error instead of killing the process. `stream` calls it.
function M.ignore_sigpipe()
	if not M.sigpipe_ignored then
		signal.signal(signal.SIGPIPE, signal.SIG_IGN)
		M.sigpipe_ignored = true
	end
end

--- Sets O_NONBLOCK on fd.
function M.nonblock(fd)
	local flags = fcntl.fcntl(fd, fcntl.F_GETFL)
	return fcntl.fcntl(fd, fcntl.F_SETFL, flags | fcntl.O_NONBLOCK)
end

--- The default wait: poll(2) on one fd until it is ready or the
-- deadline passes.
-- @return true, or nil and "timeout" or an error message
function M.poll_wait(s, mask, deadline)
	local events = mask == "r" and { IN = true } or { OUT = true }
	while true do
		local ms = -1
		if deadline then
			ms = math.max(0, math.ceil((deadline - clock.now()) * 1000))
		end
		local n, err, en = ppoll.poll({ [s.fd] = { events = events } }, ms)
		if n == nil then
			if en ~= EINTR then
				return nil, err
			end
		elseif n > 0 then
			return true
		elseif deadline and clock.now() >= deadline then
			return nil, "timeout"
		end
	end
end

local Stream = {}
Stream.__index = Stream

--[[- Makes a stream that owns fd.
@tparam int fd a connected socket
@tparam[opt] table opts `wait(stream, mask, deadline)`, and `on_close(stream)`
called before the fd closes
@treturn Stream
]]
function M.stream(fd, opts)
	opts = opts or {}
	M.ignore_sigpipe()
	M.nonblock(fd)
	return setmetatable({
		fd = fd,
		wait = opts.wait or M.poll_wait,
		on_close = opts.on_close,
	}, Stream)
end

--- Reads up to max bytes.
-- @return a non-empty string, or nil and "eof", "timeout", "closed" or
-- an error message
function Stream:read(max, deadline)
	while true do
		if not self.fd then
			return nil, "closed"
		end
		local s, err, en = unistd.read(self.fd, max or 65536)
		if s then
			if s == "" then
				return nil, "eof"
			end
			return s
		elseif wouldblock(en) then
			local ok, werr = self:wait("r", deadline)
			if not ok then
				return nil, werr
			end
		elseif en ~= EINTR then
			return nil, err
		end
	end
end

--- Writes all of buf.
-- @return true, or nil and "timeout", "closed" or an error message
function Stream:write(buf, deadline)
	local off = 1
	while off <= #buf do
		if not self.fd then
			return nil, "closed"
		end
		local n, err, en = unistd.write(self.fd, off == 1 and buf or buf:sub(off))
		if n then
			off = off + n
		elseif wouldblock(en) then
			local ok, werr = self:wait("w", deadline)
			if not ok then
				return nil, werr
			end
		elseif en ~= EINTR then
			return nil, err
		end
	end
	return true
end

--- Ends the write side; the peer reads end of stream.
function Stream:shutdown()
	if self.fd then
		socket.shutdown(self.fd, socket.SHUT_WR)
	end
end

--- Closes the fd. A second close does nothing.
function Stream:close()
	if not self.fd then
		return
	end
	if self.on_close then
		self:on_close()
	end
	unistd.close(self.fd)
	self.fd = nil
end

--- Returns `{peer = {addr, port}, local = {addr, port}}`.
function Stream:info()
	if not self.fd then
		return {}
	end
	return {
		peer = socket.getpeername(self.fd),
		["local"] = socket.getsockname(self.fd),
	}
end

Stream.__close = Stream.close

-- Waits for a non-blocking connect to finish.
local function finish_connect(fd, s, deadline)
	local ok, err = s:wait("w", deadline)
	if not ok then
		return nil, err
	end
	local soerr = socket.getsockopt(fd, socket.SOL_SOCKET, socket.SO_ERROR)
	if soerr ~= 0 then
		return nil, errno.errno(soerr)
	end
	return true
end

--- Tells the address family of a literal IP address, or nil for a name.
function M.literal(host)
	if host:find("^%d+%.%d+%.%d+%.%d+$") then
		return socket.AF_INET
	elseif host:find(":", 1, true) then
		return socket.AF_INET6
	end
end

-- Turns resolver results into getaddrinfo-shaped addresses.
local function addresses(list, port)
	local out = {}
	for _, a in ipairs(list) do
		if type(a) == "string" then
			local family = M.literal(a)
			if family then
				out[#out + 1] = { family = family, addr = a, port = port }
			end
		else
			out[#out + 1] = {
				family = a.family or M.literal(a.addr),
				addr = a.addr,
				port = a.port or port,
			}
		end
	end
	return out
end

--[[- Connects to host and port.

It tries each address in order until one connects.

@tparam string host a name or an address
@tparam int port
@tparam[opt] table opts `deadline`, `wait`, `on_close`, and
`resolve(host, port, deadline)`, which returns a list of address strings
or of `{family, addr, port}`, or nil and the reason. A literal address
skips the resolver. `tls` is an error.
@treturn[1] Stream
@return[2] nil and the reason
]]
function M.connect(host, port, opts)
	opts = opts or {}
	if opts.tls then
		return nil, "mhttp.io.posix has no TLS"
	end
	local addrs
	local family = M.literal(host)
	if family then
		addrs = { { family = family, addr = host, port = port } }
	elseif opts.resolve then
		local list, rerr = opts.resolve(host, port, opts.deadline)
		if not list then
			return nil, "lookup " .. host .. ": " .. tostring(rerr)
		end
		addrs = addresses(list, port)
	else
		local gerr
		addrs, gerr = socket.getaddrinfo(host, tostring(port),
			{ family = socket.AF_UNSPEC, socktype = socket.SOCK_STREAM })
		if not addrs then
			return nil, "lookup " .. host .. ": " .. tostring(gerr)
		end
	end
	local last = "no address"
	for _, a in ipairs(addrs) do
		local fd, serr = socket.socket(a.family, socket.SOCK_STREAM, 0)
		if not fd then
			last = serr
		else
			local s = M.stream(fd, opts)
			socket.setsockopt(fd, socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
			local ok, cerr, en = socket.connect(fd, a)
			if not ok and en == EINPROGRESS then
				ok, cerr = finish_connect(fd, s, opts.deadline)
			end
			if ok then
				return s
			end
			last = cerr
			s:close()
		end
	end
	return nil, ("connect %s:%s: %s"):format(host, port, tostring(last))
end

local Listener = {}
Listener.__index = Listener

--[[- Listens on host and port. Port 0 picks a free port.
@tparam string host such as "127.0.0.1" or "::"
@tparam int port
@tparam[opt] table opts `backlog`; `reuseport` to set SO_REUSEPORT, so
that several processes can each listen on the port and the kernel
spreads connections between them; and `wait` and `on_close` for the
listener and for the streams it accepts
@treturn[1] Listener
@return[2] nil and the reason
]]
function M.listen(host, port, opts)
	opts = opts or {}
	local addrs, gerr = socket.getaddrinfo(host, tostring(port), {
		family = socket.AF_UNSPEC, socktype = socket.SOCK_STREAM,
		flags = socket.AI_PASSIVE,
	})
	if not addrs then
		return nil, tostring(gerr)
	end
	local a = addrs[1]
	local fd, err = socket.socket(a.family, socket.SOCK_STREAM, 0)
	if not fd then
		return nil, err
	end
	socket.setsockopt(fd, socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	if opts.reuseport then
		if not M.SO_REUSEPORT then
			unistd.close(fd)
			return nil, "SO_REUSEPORT is unknown on this system"
		end
		socket.setsockopt(fd, socket.SOL_SOCKET, M.SO_REUSEPORT, 1)
	end
	local ok
	ok, err = socket.bind(fd, a)
	if ok then
		ok, err = socket.listen(fd, opts.backlog or socket.SOMAXCONN)
	end
	if not ok then
		unistd.close(fd)
		return nil, err
	end
	M.nonblock(fd)
	return setmetatable({
		fd = fd,
		opts = opts,
		wait = opts.wait or M.poll_wait,
		on_close = opts.on_close,
	}, Listener)
end

--- Accepts one connection.
-- @return a Stream and the peer address, or nil and the reason
function Listener:accept(deadline)
	while true do
		if not self.fd then
			return nil, "closed"
		end
		local fd, addr, en = socket.accept(self.fd)
		if fd then
			socket.setsockopt(fd, socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
			return M.stream(fd, self.opts), addr
		elseif wouldblock(en) then
			local ok, err = self:wait("r", deadline)
			if not ok then
				return nil, err
			end
		elseif en ~= EINTR and en ~= errno.ECONNABORTED then
			return nil, addr
		end
	end
end

--- Returns the port the listener is bound to.
function Listener:port()
	return socket.getsockname(self.fd).port
end

function Listener:close()
	if self.fd then
		if self.on_close then
			self:on_close()
		end
		unistd.close(self.fd)
		self.fd = nil
	end
end

return M
