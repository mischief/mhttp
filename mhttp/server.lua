-- SPDX-License-Identifier: ISC

--[[- HTTP/1.1 server connection loop.

`serve(stream)` reads requests from one connection, calls the handler
for each, and writes the responses. It owns no listener and no event
loop: the caller accepts connections and runs `serve` in a task, or in
a process, of its own.

The handler is `handler(req, res)`. It runs in the task that called
`serve`, so it can do I/O on the same scheduler. The server owns the
framing fields: a handler sets Content-Length or nothing, never
Transfer-Encoding.

@module mhttp.server
]]

local parse = require("mhttp.parse")
local wire = require("mhttp.wire")
local headers = require("mhttp.headers")
local clock = require("mhttp.clock")

local M = {}

--- Default options.
-- @table defaults
-- @field idle seconds to wait for the first byte of a request (60)
-- @field head seconds to read a head once it starts (30)
-- @field body seconds for each read of a body (60)
-- @field write seconds for each write (60)
-- @field drain unread body bytes to discard to keep a connection (64 KiB)
-- @field read_size bytes per read (64 KiB)
-- @field max_body request body bytes; a handler can change it for one
-- request with `Request:set_max_body` (16 MiB)
M.defaults = {
	max_body = 16 * 1024 * 1024,
	idle = 60,
	head = 30,
	body = 60,
	write = 60,
	drain = 64 * 1024,
	read_size = 64 * 1024,
}

local Server = {}
Server.__index = Server

--[[- Makes a server.
@tparam table opts `handler` (required); `limits` for `mhttp.parse`,
where `max_body` is a hard cap above every per-request limit; the
fields of `defaults`; `name` for a Server field; `date` false to
leave out Date; `on_error(err, req)` for handler errors (default: write
to stderr)
@treturn Server
]]
function M.new(opts)
	assert(type(opts) == "table" and opts.handler, "server needs a handler")
	local s = setmetatable({ opts = opts, limits = opts.limits }, Server)
	for k, v in pairs(M.defaults) do
		s[k] = opts[k] == nil and v or opts[k]
	end
	s.handler = opts.handler
	s.name = opts.name
	s.date = opts.date ~= false
	s.on_error = opts.on_error or function(err)
		io.stderr:write("mhttp.server: ", tostring(err), "\n")
	end
	return s
end

--- Asks every connection to close after its current request.
function Server:shutdown()
	self.stopping = true
end

local function http_date()
	return os.date("!%a, %d %b %Y %H:%M:%S GMT")
end

-- One connection.
local Conn = {}
Conn.__index = Conn

-- Reads more bytes into the parser. Returns true, or nil and the reason.
function Conn:fill(deadline)
	local data, err = self.s:read(self.srv.read_size, deadline)
	if data then
		self.p:feed(data)
		self.got = true
		return true
	end
	if err == "eof" then
		self.p:eof()
		return true
	end
	return nil, err
end

-- The next parser event. Returns the event, or nil and an error.
function Conn:event(deadline)
	while true do
		local ev, err = self.p:next()
		if ev or err then
			return ev, err
		end
		local ok, ferr = self:fill(deadline)
		if not ok then
			return nil, { code = ferr == "timeout" and "timeout" or "io", message = ferr }
		end
	end
end

function Conn:write(s)
	local ok, err = self.s:write(s, clock.after(self.srv.write))
	if not ok then
		self.broken = true
	end
	return ok, err
end

--- A request, given to the handler.
-- It has the fields of a parsed head (see `mhttp.parse.Msg`), and
-- `peer`, `trailers` once the body is read, and `stream_info` from the
-- stream when it has `info`.
-- @type Request
local Request = {}
Request.__index = Request

local TOO_LARGE = { code = "body", message = "body too large", status = 413 }

--- Sets the body limit for this request. Call it before the first read.
-- @tparam number n bytes; math.huge for no limit below the hard cap
function Request:set_max_body(n)
	self.max_body = n
end

--- Returns the next piece of the body, or nil at its end.
-- It sends 100 Continue first when the client asked, no response has
-- started, and the declared length is within the limit.
-- @return string, or nil at the end, or nil and an error; a body over
-- the limit gives an error with status 413
function Request:read()
	if self.done then
		return nil
	end
	local c = self.conn
	if (self.length or 0) > self.max_body then
		c.broken = true
		return nil, TOO_LARGE
	end
	if self.expect_continue and not self.continued and not c.res.started then
		self.continued = true
		local ok, err = c:write("HTTP/1.1 100 Continue\r\n\r\n")
		if not ok then
			return nil, err
		end
	end
	while true do
		local ev, err = c:event(clock.after(c.srv.body))
		if not ev then
			c.broken = true
			return nil, err
		end
		if ev.type == "data" then
			self.received = self.received + #ev.data
			if self.received > self.max_body then
				c.broken = true
				return nil, TOO_LARGE
			end
			return ev.data
		elseif ev.type == "trailers" then
			self.trailers = ev.headers
		elseif ev.type == "done" then
			self.done = true
			return nil
		end
	end
end

--- Reads the whole body into memory.
-- @tparam[opt] number max sets the limit first, as `set_max_body`
-- @return string, or nil and an error
function Request:body(max)
	if max then
		self:set_max_body(max)
	end
	local t = {}
	while true do
		local s, err = self:read()
		if not s then
			if err then
				return nil, err
			end
			return table.concat(t)
		end
		t[#t + 1] = s
	end
end

--[[- Writes the body to a file, a piece at a time.

@tparam[opt] table opts `max` sets the limit first; `file` is an open
file to write to; `path` names a file to create; with neither, it uses
io.tmpfile(), which the system removes once it is closed
@return the file, positioned at its start, and the byte count; or nil
and an error. A file this call opened is closed on an error.
]]
function Request:spool(opts)
	opts = opts or {}
	if opts.max then
		self:set_max_body(opts.max)
	end
	local f, ferr = opts.file, nil
	if not f then
		if opts.path then
			f, ferr = io.open(opts.path, "w+b")
		else
			f, ferr = io.tmpfile()
		end
		if not f then
			return nil, { code = "spool", message = ferr }
		end
	end
	local n = 0
	while true do
		local s, err = self:read()
		if not s and err then
			if not opts.file then
				f:close()
			end
			return nil, err
		end
		if not s then
			break
		end
		local ok, werr = f:write(s)
		if not ok then
			self.conn.broken = true
			if not opts.file then
				f:close()
			end
			return nil, { code = "spool", message = werr }
		end
		n = n + #s
	end
	f:flush()
	f:seek("set")
	return f, n
end

--- A response, given to the handler.
-- Set `status` and `headers`, then call `send`, or `start`, `write` and
-- `finish`. The head goes out with the first body bytes.
-- @type Response
local Response = {}
Response.__index = Response

local function no_body(status, method)
	return status < 200 or status == 204 or status == 304 or method == "HEAD"
end

--[[- Starts the response: fixes the status, the headers and the framing.

Content-Length in the headers gives a fixed length. Without it the body
is chunked for HTTP/1.1 and ends with the connection for HTTP/1.0.

@tparam[opt] int status default `res.status`
@param[opt] h more header fields
@return true, or nil and the reason
]]
function Response:start(status, h)
	if self.started then
		return nil, "response already started"
	end
	local req, c = self.req, self.conn
	status = status or self.status
	self.status = status
	if status < 200 and status ~= 101 then
		return nil, "use inform for 1xx responses"
	end
	local hs = self.headers
	if h then
		for _, name, value in headers.from(h):each() do
			hs:add(name, value)
		end
	end
	if hs:has("transfer-encoding") then
		return nil, "the server sets transfer-encoding"
	end
	local tunnel = status == 101 or (req.method == "CONNECT" and status < 300)
	-- Close when the body is bad, or too long to drain after the handler.
	local unread = req.done and 0 or (req.length or math.huge) - req.received
	local close = c.srv.stopping or not req.keep_alive or c.broken
		or unread > c.srv.drain or hs:has_token("connection", "close")
	if tunnel then
		self.mode = "none"
		hs:del("content-length")
	elseif status == 204 or status == 304 then
		self.mode = "none"
		hs:del("content-length")
	elseif hs:has("content-length") then
		local cl = hs:get("content-length")
		if not cl:find("^%d+$") then
			return nil, "bad content-length"
		end
		self.mode, self.left = "length", tonumber(cl)
	elseif req.method == "HEAD" then
		self.mode = "none"
	elseif req.version == "1.1" then
		self.mode = "chunked"
		hs:set("Transfer-Encoding", "chunked")
	else
		self.mode = "close"
		close = true
	end
	if req.method == "HEAD" then
		self.mode = "none"
	end
	if not tunnel then
		if close then
			hs:set("Connection", "close")
		elseif req.version == "1.0" then
			hs:set("Connection", "keep-alive")
		end
	end
	if c.srv.date and not hs:has("date") then
		hs:add("Date", http_date())
	end
	if c.srv.name and not hs:has("server") then
		hs:add("Server", c.srv.name)
	end
	local head, err = wire.response_head(status, self.reason, hs, req.version)
	if not head then
		return nil, err
	end
	self.started, self.close, self.tunnel = true, close, tunnel
	self.pending = head
	return true
end

-- Sends the pending head with s.
function Response:send_raw(s)
	if self.pending then
		s = self.pending .. s
		self.pending = nil
	end
	if s == "" then
		return true
	end
	return self.conn:write(s)
end

--- Writes body bytes. Starts the response when needed.
-- @return true, or nil and the reason
function Response:write(data)
	if not self.started then
		local ok, err = self:start()
		if not ok then
			return nil, err
		end
	end
	if self.finished then
		return nil, "response finished"
	end
	if #data == 0 then
		return self:send_raw("")
	end
	local m = self.mode
	if m == "none" then
		if self.req.method == "HEAD" then
			return true
		end
		return nil, "this response has no body"
	elseif m == "length" then
		if #data > self.left then
			return nil, "more bytes than content-length"
		end
		self.left = self.left - #data
		return self:send_raw(data)
	elseif m == "chunked" then
		return self:send_raw(wire.chunk(data))
	end
	return self:send_raw(data)
end

--- Sends the pending head now, without body bytes.
function Response:flush()
	return self:send_raw("")
end

--- Finishes the response.
-- @tparam[opt] string data last body bytes
-- @param[opt] trailers trailer fields, for a chunked body
-- @return true, or nil and the reason
function Response:finish(data, trailers)
	if self.finished then
		return true
	end
	if data and #data > 0 then
		local ok, err = self:write(data)
		if not ok then
			return nil, err
		end
	elseif not self.started then
		local ok, err = self:start()
		if not ok then
			return nil, err
		end
	end
	self.finished = true
	if self.mode == "chunked" then
		local last, err = wire.last_chunk(trailers)
		if not last then
			self.conn.broken = true
			return nil, err
		end
		return self:send_raw(last)
	end
	if self.mode == "length" and self.left > 0 then
		self.conn.broken = true
		local ok = self:send_raw("")
		return ok and nil, "fewer bytes than content-length"
	end
	return self:send_raw("")
end

--- Sends a whole response.
-- @tparam int status
-- @tparam[opt] string body
-- @param[opt] h header fields
function Response:send(status, body, h)
	body = body or ""
	self.status = status
	if not no_body(status, "") and not self.headers:has("content-length") then
		self.headers:set("Content-Length", #body)
	end
	local ok, err = self:start(status, h)
	if not ok then
		return nil, err
	end
	return self:finish(body)
end

--- Sends a 1xx response now, such as 103 Early Hints.
function Response:inform(status, h)
	if self.started or status < 100 or status > 199 or status == 101 then
		return nil, "inform needs a 1xx status before the response"
	end
	local head, err = wire.response_head(status, nil, h, self.req.version)
	if not head then
		return nil, err
	end
	return self.conn:write(head)
end

--[[- Takes the connection, after a 101 or a CONNECT 2xx, or before any
response. The server stops using it.

@return the stream, and the bytes already read past the request
]]
function Response:hijack()
	if self.started and not self.tunnel then
		return nil, "the response is not a tunnel"
	end
	local ok, err = self:send_raw("")
	if not ok then
		return nil, err
	end
	self.finished = true
	local c = self.conn
	c.hijacked = true
	return c.s, c.p:rest()
end

-- Writes an error response for a request that failed to parse.
local function error_response(c, err)
	local status = err.status or 400
	local body = err.message .. "\n"
	local head = wire.response_head(status, nil, {
		{ "Content-Type", "text/plain; charset=utf-8" },
		{ "Content-Length", ("%d"):format(#body) },
		{ "Connection", "close" },
	})
	c:write(head .. body)
end

-- Reads and drops the rest of the request body.
local function drain(req, max)
	local n = 0
	while true do
		local s, err = req:read()
		if not s then
			return err == nil
		end
		n = n + #s
		if n > max then
			return false
		end
	end
end

--[[- Serves one connection until it closes. Closes the stream at the
end, unless the handler took it with `hijack`.
@param stream an object with `read`, `write` and `close`
]]
function Server:serve(stream)
	local c = setmetatable({
		s = stream,
		srv = self,
		p = parse.new("request", self.limits),
	}, Conn)
	local info = stream.info and stream:info() or nil
	while true do
		c.got = false
		local deadline = clock.after(self.idle)
		local ev, err
		while true do
			ev, err = c.p:next()
			if ev or err then
				break
			end
			local was = c.got
			local ok, ferr = c:fill(deadline)
			if not ok then
				err = { code = ferr == "timeout" and "timeout" or "io", message = ferr }
				break
			end
			if c.got and not was then
				deadline = clock.min(deadline, clock.after(self.head))
			end
		end
		if not ev then
			if err.status then
				error_response(c, err)
			elseif err.code == "timeout" and c.got then
				error_response(c, { status = 408, message = "request timeout" })
			end
			break
		end
		local req = setmetatable(ev, Request)
		req.type = nil
		req.conn, req.peer, req.stream_info = c, info and info.peer, info
		req.max_body, req.received = self.max_body, 0
		if req.framing == "none" then
			req.done = true
			-- Take the "done" event of a bodiless request now.
			c.p:next()
		end
		local res = setmetatable({
			req = req, conn = c, status = 200, headers = headers.new(),
		}, Response)
		c.res = res
		local ok, herr = xpcall(self.handler, debug.traceback, req, res)
		if not ok then
			self.on_error(herr, req)
			if not res.started then
				res.headers = headers.new()
				res:send(500, "internal server error\n",
					{ { "Content-Type", "text/plain; charset=utf-8" } })
			end
			c.broken = true
		elseif not c.hijacked and not res.finished then
			if not res.started then
				self.on_error("handler sent no response", req)
				res:send(500, "no response\n")
				c.broken = true
			else
				res:finish()
			end
		end
		if c.hijacked then
			return
		end
		if c.broken or res.close or res.tunnel then
			break
		end
		if not req.done and not drain(req, self.drain) then
			break
		end
	end
	stream:close()
end

M.Request, M.Response = Request, Response

return M
