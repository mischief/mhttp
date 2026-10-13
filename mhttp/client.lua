-- SPDX-License-Identifier: ISC

--[[- HTTP/1.1 client with a pool of idle connections.

A connector makes streams: `connect(host, port, opts)`, where opts has
`deadline`, `resolve` and, for https, `tls` (see DESIGN.md). The default is
`mhttp.io.posix.connect`, which has no TLS.

Errors are `{kind, message}`. kind is "url", "connect", "timeout",
"io", "protocol", "body" or "redirect".

@module mhttp.client
]]

local parse = require("mhttp.parse")
local wire = require("mhttp.wire")
local headers = require("mhttp.headers")
local url = require("mhttp.url")
local clock = require("mhttp.clock")

local M = {}

local IDEMPOTENT = {
	GET = true, HEAD = true, OPTIONS = true, TRACE = true, PUT = true, DELETE = true,
}

local function fail(kind, message)
	return nil, { kind = kind, message = tostring(message) }
end

local Client = {}
Client.__index = Client

--[[- Makes a client.

@tparam[opt] table opts
 - `connect(host, port, opts)`: the connector
 - `tls`: options for https connections, passed to the connector
 - `resolve(host, port, deadline)`: name lookup, passed to the connector
 - `proxy`: an http:// proxy URL for http:// requests
 - `headers`: fields for every request
 - `timeout`: seconds for a whole request (60)
 - `max_idle`: idle connections kept per origin (4)
 - `limits`: limits for `mhttp.parse`
 - `read_size`: bytes per read (64 KiB)
@treturn Client
]]
function M.new(opts)
	opts = opts or {}
	local connect = opts.connect
	if not connect then
		connect = function(host, port, o)
			return require("mhttp.io.posix").connect(host, port, o)
		end
	end
	local proxy
	if opts.proxy then
		proxy = assert(url.parse(opts.proxy))
		assert(proxy.scheme == "http" and proxy.host, "proxy must be an http:// URL")
	end
	return setmetatable({
		connect = connect,
		tls = opts.tls,
		resolve = opts.resolve,
		proxy = proxy,
		headers = headers.new(opts.headers),
		timeout = opts.timeout or 60,
		max_idle = opts.max_idle or 4,
		limits = opts.limits,
		read_size = opts.read_size or 64 * 1024,
		idle = {},
	}, Client)
end

--- Closes every idle connection.
function Client:close()
	for _, list in pairs(self.idle) do
		for _, c in ipairs(list) do
			c.s:close()
		end
	end
	self.idle = {}
end

-- Takes an idle connection to key, or makes one.
function Client:conn(key, host, port, tls, deadline)
	local list = self.idle[key]
	if list and #list > 0 then
		local c = table.remove(list)
		c.reused = true
		return c
	end
	local s, err = self.connect(host, port,
		{ deadline = deadline, tls = tls, resolve = self.resolve })
	if not s then
		return nil, err
	end
	return { s = s, key = key, p = parse.new("response", self.limits) }
end

function Client:release(c)
	local list = self.idle[c.key]
	if not list then
		list = {}
		self.idle[c.key] = list
	end
	if #list < self.max_idle then
		c.p = parse.new("response", self.limits)
		list[#list + 1] = c
	else
		c.s:close()
	end
end

--- A response.
-- Fields: status, reason, version, headers, trailers, url, and body
-- unless the request asked to stream.
-- @type Response
local Response = {}
Response.__index = Response

-- Reads the next parser event.
local function next_event(c, deadline, read_size)
	while true do
		local ev, err = c.p:next()
		if ev then
			return ev
		end
		if err then
			return fail("protocol", err.message)
		end
		local data, rerr = c.s:read(read_size, deadline)
		if data then
			c.p:feed(data)
			c.got = true
		elseif rerr == "eof" then
			c.p:eof()
		elseif rerr == "timeout" then
			return fail("timeout", "request timed out")
		else
			return fail("io", rerr)
		end
	end
end

--- Returns the next piece of a streamed body, or nil at its end.
-- @return string, or nil at the end, or nil and an error
function Response:read()
	if self.done then
		return nil
	end
	local c = self.conn
	while true do
		local ev, err = next_event(c, self.deadline, self.client.read_size)
		if not ev then
			self:close()
			return nil, err
		end
		if ev.type == "data" then
			self.received = self.received + #ev.data
			if self.max_body and self.received > self.max_body then
				self:close()
				return fail("body", "body larger than max_body")
			end
			return ev.data
		elseif ev.type == "trailers" then
			self.trailers = ev.headers
		elseif ev.type == "done" then
			self.done = true
			if self.keep_alive and not ev.tunnel then
				self.client:release(c)
			else
				c.s:close()
			end
			self.conn = nil
			return nil
		end
	end
end

--- Closes the connection of a streamed body that was not read to the end.
function Response:close()
	if self.conn then
		self.conn.s:close()
		self.conn = nil
	end
	self.done = true
end

--- Takes the connection after a 101 response.
-- @return the stream, and the bytes already read past the response
function Response:hijack()
	local c = self.conn
	if not c or self.status ~= 101 then
		return nil, "not a 101 response"
	end
	self.conn, self.done = nil, true
	return c.s, c.p:rest()
end

-- Writes the request head and body.
local function send(c, head, body, deadline, chunked)
	if type(body) == "string" or body == nil then
		return c.s:write(head .. (body or ""), deadline)
	end
	local ok, err = c.s:write(head, deadline)
	if not ok then
		return nil, err
	end
	while true do
		local piece = body()
		if piece == nil then
			break
		end
		ok, err = c.s:write(chunked and wire.chunk(piece) or piece, deadline)
		if not ok then
			return nil, err
		end
	end
	if chunked then
		return c.s:write(wire.last_chunk(), deadline)
	end
	return true
end

-- One request, one try. Returns the response, or nil, err, retryable.
function Client:once(req, u, deadline)
	local scheme = u.scheme
	if scheme ~= "http" and scheme ~= "https" then
		return fail("url", "scheme must be http or https")
	end
	if not u.host or u.host == "" then
		return fail("url", "URL has no host")
	end
	local method = req.method or "GET"
	local host, port, target, tls = u.host, url.port(u), url.target(u), nil
	if scheme == "https" then
		tls = {}
		for k, v in pairs(self.tls or {}) do
			tls[k] = v
		end
		tls.sni = tls.sni or u.host
	end
	if self.proxy and scheme == "http" then
		host, port = self.proxy.host, url.port(self.proxy)
		target = url.format({ scheme = u.scheme, host = u.host, port = u.port,
			path = u.path ~= "" and u.path or "/", query = u.query })
	elseif self.proxy then
		return fail("url", "https through a proxy needs CONNECT, not supported yet")
	end
	local key = ("%s://%s:%d"):format(scheme, host, port)

	local h = self.headers:clone()
	if req.headers then
		for _, name, value in headers.from(req.headers):each() do
			h:add(name, value)
		end
	end
	if not h:has("host") then
		h:add("Host", url.authority(u))
	end
	local body, chunked = req.body, false
	if type(body) == "string" then
		h:set("Content-Length", #body)
	elseif type(body) == "function" then
		if req.length then
			h:set("Content-Length", req.length)
		else
			h:set("Transfer-Encoding", "chunked")
			chunked = true
		end
	elseif method == "POST" or method == "PUT" or method == "PATCH" then
		h:set("Content-Length", 0)
	end
	local head, herr = wire.request_head(method, target, h)
	if not head then
		return fail("url", herr)
	end

	local c, cerr = self:conn(key, host, port, tls, deadline)
	if not c then
		return fail(cerr == "timeout" and "timeout" or "connect", cerr)
	end
	-- A reused connection that fails before any response byte may have
	-- been closed by the server while idle. That request can be retried.
	local retry = c.reused and IDEMPOTENT[method] and type(body) ~= "function"
	c.got = false
	local ok, werr = send(c, head, body, deadline, chunked)
	c.p:expect(method)
	local res
	while true do
		local ev, err = next_event(c, deadline, self.read_size)
		if not ev then
			c.s:close()
			if not ok then
				-- The write error tells more than the read error.
				err = select(2, fail(werr == "timeout" and "timeout" or "io", werr))
			end
			return nil, err, retry and not c.got
		end
		if ev.type == "head" and not ev.informational then
			res = ev
			break
		end
	end
	res.type = nil
	-- A server may answer before it reads the whole request, as with
	-- 413. The connection is not reusable then.
	if not ok then
		res.keep_alive = false
	end
	setmetatable(res, Response)
	res.client, res.conn, res.deadline = self, c, deadline
	res.url, res.received, res.max_body = url.format(u), 0, req.max_body
	if res.status == 101 then
		return res
	end
	if req.stream then
		return res
	end
	local parts = {}
	while true do
		local s, err = res:read()
		if not s then
			if err then
				return nil, err
			end
			break
		end
		if req.sink then
			local sok, serr = pcall(req.sink, s, res)
			if not sok then
				res:close()
				return fail("body", serr)
			end
		else
			parts[#parts + 1] = s
		end
	end
	if not req.sink then
		res.body = table.concat(parts)
	end
	return res
end

local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

--[[- Sends a request.

@tparam table req
 - `url`: string or a table from `mhttp.url.parse`
 - `method` (GET), `headers`
 - `body`: a string, or a function that returns pieces and then nil.
   With a function, `length` sets Content-Length; else it is chunked.
 - `timeout`: seconds for the whole request, redirects included
 - `stream`: true to read the body with `Response:read`
 - `sink(piece, res)`: called for each piece instead of keeping a body
 - `max_body`: fail when the body is larger
 - `follow`: redirects to follow (0)
@return a `Response`, or nil and an error
]]
function Client:request(req)
	local u, err = req.url, nil
	if type(u) == "string" then
		u, err = url.parse(u)
		if not u then
			return fail("url", err)
		end
	end
	local deadline = clock.after(req.timeout or self.timeout)
	local follow = req.follow or 0
	while true do
		local res, rerr, retry = self:once(req, u, deadline)
		if not res and retry then
			res, rerr = self:once(req, u, deadline)
		end
		if not res then
			return nil, rerr
		end
		local loc = res.headers:get("location")
		if not (REDIRECT[res.status] and loc and follow > 0) then
			return res
		end
		if req.stream then
			res:close()
		end
		follow = follow - 1
		local nu, uerr = url.resolve(u, loc)
		if not nu then
			return fail("redirect", uerr)
		end
		nu.fragment = nil
		local r2 = {}
		for k, v in pairs(req) do
			r2[k] = v
		end
		if res.status == 303 or ((res.status == 301 or res.status == 302)
		    and (req.method or "GET") == "POST") then
			r2.method, r2.body, r2.length = "GET", nil, nil
		end
		if r2.body ~= nil and type(r2.body) ~= "string" then
			return fail("redirect", "cannot resend a function body")
		end
		-- Credentials stay with their origin.
		if nu.scheme ~= u.scheme or nu.host ~= u.host or url.port(nu) ~= url.port(u) then
			local h = headers.new(req.headers)
			h:del("authorization")
			h:del("cookie")
			h:del("proxy-authorization")
			r2.headers = h
		end
		req, u = r2, nu
	end
end

--- Shorthand for a GET.
function Client:get(u, opts)
	opts = opts or {}
	opts.url = u
	return self:request(opts)
end

M.Response = Response

return M
