-- SPDX-License-Identifier: ISC

--[[- Incremental HTTP/1.1 message parser (RFC 9112). It does no I/O.

Give it bytes with `feed` and the end of the stream with `eof`, then
call `next` until it returns nil. Events: "head" (see `Msg`), "data"
(`data`), "trailers" (`headers`, never merged into the head) and
"done" (`tunnel = true` when `rest` must take the connection).

An error is final: `{code, message, status}`, where status is what a
server sends back. It is nil in the response parser.

Framing is strict, against request smuggling and response splitting.
Lines end in CRLF; bare CR, bare LF and NUL are errors. So are space
before a field colon, obs-fold, Transfer-Encoding with Content-Length,
Transfer-Encoding in HTTP/1.0, Content-Length values that differ, a
request without exactly one Host, and chunk data without its CRLF.

@module mhttp.parse
]]

local syntax = require("mhttp.syntax")
local headers = require("mhttp.headers")

local M = {}

--- Default limits. Pass a table to `new` to change some of them.
-- @table defaults
-- @field max_line start line, which holds the request target (8 KiB)
-- @field max_head start line and fields together (64 KiB)
-- @field max_fields number of header fields (100)
-- @field max_body body bytes, after chunked decoding (no limit; the
-- server and the client set their own)
-- @field max_chunk_line chunk size line with its extensions (1 KiB)
-- @field max_trailer trailer section (16 KiB)
M.defaults = {
	max_line = 8 * 1024,
	max_head = 64 * 1024,
	max_fields = 100,
	max_body = math.huge,
	max_chunk_line = 1024,
	max_trailer = 16 * 1024,
}

local Parser = {}
Parser.__index = Parser

-- next() loops while a state returns this.
local AGAIN = {}

--- The end of the stream between two messages. It is not an error.
M.EOF = { code = "eof", message = "end of stream" }

--[[- Makes a parser.

@tparam string kind "request" or "response"
@tparam[opt] table limits overrides for `defaults`
@treturn Parser
]]
function M.new(kind, limits)
	assert(kind == "request" or kind == "response", "kind")
	local lim = {}
	for k, v in pairs(M.defaults) do
		lim[k] = v
	end
	for k, v in pairs(limits or {}) do
		assert(M.defaults[k], "unknown limit " .. tostring(k))
		lim[k] = v
	end
	return setmetatable({
		kind = kind,
		lim = lim,
		buf = "",
		pos = 1,
		scan = 1, -- where the search for the end of the head starts
		pending = {},
		pending_len = 0, -- their bytes
		pending_nl = false,
		ended = false,
		state = "head",
		methods = {}, -- request methods for the response parser
	}, Parser)
end

--- Adds bytes from the stream.
-- @tparam string s
function Parser:feed(s)
	assert(not self.ended, "feed after eof")
	if #s == 0 then
		return
	end
	local p = self.pending
	p[#p + 1] = s
	self.pending_len = (self.pending_len or 0) + #s
	if not self.pending_nl and s:find("\n", 1, true) then
		self.pending_nl = true
	end
end

--- Marks the end of the stream.
function Parser:eof()
	self.ended = true
end

--- Tells the response parser the method of the next request.
-- Call it once per request, in order. HEAD and CONNECT change how the
-- response is framed. Without it the parser takes GET.
-- @tparam string method
function Parser:expect(method)
	self.methods[#self.methods + 1] = method
end

-- Moves pending pieces into buf. While the head is incomplete it waits
-- for a LF, so a peer that sends one byte at a time costs a copy per
-- line and not a copy per byte.
function Parser:flush(force)
	local p = self.pending
	if #p == 0 then
		return
	end
	if not force and not self.pending_nl and not self.ended
	    and (self.state == "head" or self.state == "trailer") then
		-- A running total: adding up the pieces here on each call would
		-- cost time in the square of their number.
		local n = #self.buf - self.pos + 1 + self.pending_len
		if n <= self.lim.max_head then
			return
		end
	end
	local drop = self.pos - 1
	self.buf = self.buf:sub(self.pos) .. table.concat(p)
	self.pos = 1
	self.scan = math.max(1, self.scan - drop)
	self.pending = {}
	self.pending_len = 0
	self.pending_nl = false
end

function Parser:fail(code, message, status)
	self.state = "error"
	self.err = {
		code = code,
		message = message,
		status = self.kind == "request" and (status or 400) or nil,
	}
	return nil, self.err
end

-- Bytes in buf from pos.
function Parser:avail()
	return #self.buf - self.pos + 1
end

--[[- Returns the next event.

@return an event table, or nil when it needs more bytes, or nil and an
error. At the end of the stream between messages, the error is `EOF`.
]]
function Parser:next()
	self:flush()
	while true do
		local ev, err = self["st_" .. self.state](self)
		if ev ~= AGAIN then
			return ev, err
		end
	end
end

--- Takes the bytes after the message, for a tunnel or an upgrade.
-- The parser stops.
-- @treturn string
function Parser:rest()
	self:flush(true)
	local s = self.buf:sub(self.pos)
	self.buf, self.pos, self.state = "", 1, "detached"
	return s
end

function Parser:st_error()
	return nil, self.err
end

function Parser:st_closed()
	return nil, { code = "closed", message = "connection is not persistent" }
end

function Parser:st_tunnel()
	return nil, { code = "tunnel", message = "connection is a tunnel; call rest" }
end

function Parser:st_detached()
	return nil, { code = "detached", message = "rest was called" }
end

-- Parses one field line into h. Returns true, or nil and the reason.
local function field(h, line)
	if line:find("^[ \t]") then
		return nil, "obs-fold or leading whitespace in field line"
	end
	local name, value = line:match("^([^:]*):(.*)$")
	if not name or not syntax.is_token(name) then
		return nil, "bad field name"
	end
	value = syntax.trim(value)
	if not syntax.is_value(value) then
		return nil, "bad character in field " .. name
	end
	h:_add(name, value)
	return true
end

-- Reads field lines from s, which ends in CRLF. Returns the headers, or
-- nil and the reason.
local function fields(s, i, max)
	local h = headers.new()
	while i <= #s do
		local e = s:find("\r\n", i, true)
		local line = s:sub(i, e - 1)
		if line:find("[\r\n%z]") then
			return nil, "bare CR, LF or NUL"
		end
		local ok, why = field(h, line)
		if not ok then
			return nil, why
		end
		if h.n > max then
			return nil, "too many fields", 431
		end
		i = e + 2
	end
	return h
end

-- Content-Length: every value, in every field, the same digit string.
local function content_length(vals, max)
	local first
	for _, v in ipairs(vals) do
		for e in (v .. ","):gmatch("([^,]*),") do
			e = syntax.trim(e)
			if not e:find("^%d+$") then
				return nil, "bad content-length"
			end
			if first and e ~= first then
				return nil, "content-length values differ"
			end
			first = e
		end
	end
	if not first then
		return nil, "bad content-length"
	end
	local digits = first:gsub("^0+(%d)", "%1")
	if #digits > 15 or tonumber(digits) > max then
		return nil, "body too large", 413
	end
	return tonumber(digits)
end

-- Transfer-Encoding: returns the codings before chunked and true when
-- chunked is last, or nil and the reason.
local function transfer_codings(h)
	local list = {}
	for _, v in ipairs(h:get_all("transfer-encoding")) do
		for _, e in ipairs(syntax.split_list(v)) do
			if not syntax.is_token(e) then
				return nil, "bad transfer-coding", 501
			end
			list[#list + 1] = e:lower()
		end
	end
	if #list == 0 then
		return nil, "empty transfer-encoding"
	end
	local chunked = list[#list] == "chunked"
	for i = 1, #list - 1 do
		if list[i] == "chunked" then
			return nil, "chunked is not the final coding"
		end
	end
	if chunked then
		list[#list] = nil
	end
	return list, chunked
end

-- Sets msg.keep_alive from the version and Connection.
local function persistence(msg)
	local h = msg.headers
	if h:has_token("connection", "close") then
		msg.keep_alive = false
	elseif msg.version == "1.1" then
		msg.keep_alive = true
	else
		msg.keep_alive = h:has_token("connection", "keep-alive")
	end
end

--[[- A parsed head, the event of type "head".
@table Msg
@field method request: the method, case kept
@field target request: the request target as sent
@field form request: "origin", "absolute", "authority" or "asterisk"
@field path request in origin form: the path
@field query request in origin form: the query without "?", or nil
@field status response: the status code
@field reason response: the reason phrase
@field informational response: true for 1xx other than 101
@field version "1.0" or "1.1"
@field headers a `mhttp.headers` list
@field framing "none", "length", "chunked", "close" or "tunnel"
@field length the body length for framing "length"
@field codings transfer codings other than chunked, for a response
@field keep_alive true when the connection can carry another message
@field expect_continue request: true when it sent Expect: 100-continue
@field upgrade the protocols in Upgrade, when Connection lists upgrade
]]

-- Classifies a request target and checks it fits the method.
local function target_form(msg)
	local t, m = msg.target, msg.method
	if m == "CONNECT" then
		local host = t:match("^(.+):%d+$")
		if not host or not syntax.is_host(t) or t:find("[/?@]") then
			return nil, "CONNECT needs an authority target"
		end
		msg.form = "authority"
	elseif t == "*" then
		if m ~= "OPTIONS" then
			return nil, "asterisk target is only for OPTIONS"
		end
		msg.form = "asterisk"
	elseif t:sub(1, 1) == "/" then
		msg.form = "origin"
		local q = t:find("?", 1, true)
		if q then
			msg.path, msg.query = t:sub(1, q - 1), t:sub(q + 1)
		else
			msg.path = t
		end
	elseif t:find("^[A-Za-z][A-Za-z0-9+.%-]*:") then
		msg.form = "absolute"
	else
		return nil, "bad request target"
	end
	return true
end

-- Decides how a request body is framed (RFC 9112 section 6.3).
function Parser:request_framing(msg)
	local h = msg.headers
	local nhost = h:count("host")
	if nhost > 1 or (msg.version == "1.1" and nhost == 0) then
		return self:fail("host", "need exactly one host field")
	end
	if nhost == 1 and not syntax.is_host(h:get("host")) then
		return self:fail("host", "bad host field")
	end
	local ok, why = target_form(msg)
	if not ok then
		return self:fail("target", why)
	end
	if h:has("transfer-encoding") then
		if msg.version ~= "1.1" then
			return self:fail("framing", "transfer-encoding in HTTP/1.0")
		end
		if h:has("content-length") then
			return self:fail("framing", "transfer-encoding with content-length")
		end
		local codings, chunked, status = transfer_codings(h)
		if not codings then
			return self:fail("framing", chunked, status)
		end
		if not chunked then
			return self:fail("framing", "chunked is not the final coding")
		end
		if #codings > 0 then
			return self:fail("framing", "unsupported transfer-coding", 501)
		end
		msg.framing = "chunked"
	elseif h:has("content-length") then
		local n, err, status = content_length(h:get_all("content-length"),
			self.lim.max_body)
		if not n then
			return self:fail("framing", err, status)
		end
		msg.framing, msg.length = n > 0 and "length" or "none", n
	else
		msg.framing, msg.length = "none", 0
	end
	persistence(msg)
	local expect = h:get("expect")
	msg.expect_continue = expect ~= nil and expect:lower() == "100-continue"
	if h:has("upgrade") and h:has_token("connection", "upgrade") then
		msg.upgrade = h:tokens("upgrade")
	end
	return true
end

-- Decides how a response body is framed (RFC 9112 section 6.3).
function Parser:response_framing(msg)
	local h, s = msg.headers, msg.status
	local method = self.methods[1] or "GET"
	persistence(msg)
	if s < 200 and s ~= 101 then
		msg.informational, msg.framing = true, "none"
		return true
	end
	table.remove(self.methods, 1)
	if s == 101 or (method == "CONNECT" and s < 300) then
		msg.framing = "tunnel"
		if s == 101 then
			msg.upgrade = h:tokens("upgrade")
		end
		return true
	end
	if method == "HEAD" or s == 204 or s == 304 then
		msg.framing = "none"
		return true
	end
	if h:has("transfer-encoding") then
		if msg.version ~= "1.1" then
			return self:fail("framing", "transfer-encoding in HTTP/1.0")
		end
		if h:has("content-length") then
			return self:fail("framing", "transfer-encoding with content-length")
		end
		local codings, chunked = transfer_codings(h)
		if not codings then
			return self:fail("framing", chunked)
		end
		msg.codings = codings
		if chunked then
			msg.framing = "chunked"
		else
			msg.framing, msg.keep_alive = "close", false
		end
	elseif h:has("content-length") then
		local n, err = content_length(h:get_all("content-length"),
			self.lim.max_body)
		if not n then
			return self:fail("framing", err)
		end
		msg.framing, msg.length = n > 0 and "length" or "none", n
	else
		msg.framing, msg.keep_alive = "close", false
	end
	return true
end

function Parser:start_line(line, msg)
	if self.kind == "request" then
		local method, target, major, minor =
			line:match("^([^ ]+) ([^ ]+) HTTP/(%d)%.(%d)$")
		if not method then
			if #line > self.lim.max_line then
				return self:fail("line", "request line too long", 414)
			end
			return self:fail("line", "bad request line")
		end
		if major ~= "1" then
			return self:fail("version", "unsupported version", 505)
		end
		if not syntax.is_token(method) then
			return self:fail("line", "bad method")
		end
		if not syntax.is_target(target) then
			return self:fail("line", "bad request target")
		end
		msg.method, msg.target = method, target
		msg.version = minor == "0" and "1.0" or "1.1"
	else
		local major, minor, status, rest =
			line:match("^HTTP/(%d)%.(%d) (%d%d%d)(.*)$")
		if not major or (rest ~= "" and rest:sub(1, 1) ~= " ") then
			return self:fail("line", "bad status line")
		end
		if major ~= "1" then
			return self:fail("version", "unsupported version")
		end
		local reason = rest:sub(2)
		if not syntax.is_value(reason) then
			return self:fail("line", "bad reason phrase")
		end
		msg.status, msg.reason = tonumber(status), reason
		if msg.status < 100 then
			return self:fail("line", "bad status code")
		end
		msg.version = minor == "0" and "1.0" or "1.1"
	end
	return true
end

function Parser:st_head()
	local buf, lim = self.buf, self.lim
	-- A server ignores empty lines before a request (RFC 9112 2.2).
	if self.kind == "request" then
		while buf:sub(self.pos, self.pos + 1) == "\r\n" do
			self.pos = self.pos + 2
		end
		self.scan = math.max(self.scan, self.pos)
	end
	local pos = self.pos
	-- Nothing new since the last look: the answer is the same.
	if self.scan > #buf and self.scan > pos and not self.ended then
		return nil
	end
	local e = buf:find("\r\n\r\n", math.max(pos, self.scan - 3), true)
	if not e then
		local n = #buf - pos + 1
		-- Fail on a bare LF or CR now, not when a limit runs out. Only
		-- the new bytes, and the one before them, need a look; a scan of
		-- the whole head on each call would cost time in its square.
		local from = math.max(pos, self.scan - 1)
		if buf:sub(pos, pos) == "\n" or buf:find("[^\r]\n", from)
		    or buf:find("\r[^\n]", from) then
			return self:fail("line", "bare CR or LF")
		end
		local le = buf:find("\r\n", pos, true)
		if (le or #buf + 1) - pos > lim.max_line then
			if self.kind == "request" then
				return self:fail("line", "request line too long", 414)
			end
			return self:fail("line", "status line too long")
		end
		if n > lim.max_head then
			return self:fail("head", "head too large", 431)
		end
		-- next() flushed everything once the stream ended.
		if self.ended then
			if n == 0 then
				return nil, M.EOF
			end
			return self:fail("truncated", "stream ended inside a head")
		end
		self.scan = #buf + 1
		return nil
	end
	if e + 4 - pos > lim.max_head then
		return self:fail("head", "head too large", 431)
	end
	local le = buf:find("\r\n", pos, true)
	local line = buf:sub(pos, le - 1)
	if #line > lim.max_line then
		if self.kind == "request" then
			return self:fail("line", "request line too long", 414)
		end
		return self:fail("line", "status line too long")
	end
	if line:find("[\r\n%z]") then
		return self:fail("line", "bare CR, LF or NUL")
	end
	local msg = { type = "head" }
	local ok, err = self:start_line(line, msg)
	if not ok then
		return nil, err
	end
	local h, why, status
	if le == e then
		h = headers.new()
	else
		h, why, status = fields(buf:sub(le + 2, e + 1), 1, lim.max_fields)
		if not h then
			return self:fail("field", why, status)
		end
	end
	msg.headers = h
	self.pos, self.scan = e + 4, e + 4
	if self.kind == "request" then
		ok, err = self:request_framing(msg)
	else
		ok, err = self:response_framing(msg)
	end
	if not ok then
		return nil, err
	end
	self.msg, self.body = msg, 0
	local f = msg.framing
	if msg.informational then
		self.state = "head"
	elseif f == "none" then
		self.state = "done"
	elseif f == "length" then
		self.state, self.left = "length", msg.length
	elseif f == "chunked" then
		self.state = "chunk_size"
	elseif f == "close" then
		self.state = "close"
	else
		self.state = "tunnel_done"
	end
	return msg
end

-- Takes up to n bytes from buf.
function Parser:take(n)
	local s = self.buf:sub(self.pos, self.pos + n - 1)
	self.pos = self.pos + #s
	return s
end

function Parser:st_length()
	local n = math.min(self:avail(), self.left)
	if n == 0 then
		if self.ended then
			return self:fail("truncated", "stream ended inside a body")
		end
		return nil
	end
	local s = self:take(n)
	self.left = self.left - n
	if self.left == 0 then
		self.state = "done"
	end
	return { type = "data", data = s }
end

function Parser:st_close()
	if self:avail() > 0 then
		local n = self:avail()
		self.body = self.body + n
		if self.body > self.lim.max_body then
			return self:fail("body", "body too large")
		end
		return { type = "data", data = self:take(n) }
	end
	if self.ended then
		self.state = "done"
		return AGAIN
	end
	return nil
end

-- chunk-ext = *( BWS ";" BWS ext-name [ BWS "=" BWS ext-val ] )
local function chunk_ext(s)
	local i = 1
	while i <= #s do
		local a, b = s:find("^[ \t]*;[ \t]*", i)
		if not a then
			return false
		end
		i = b + 1
		local _, ne = s:find("^[A-Za-z0-9!#$%%&'*+%-.^_`|~]+", i)
		if not ne then
			return false
		end
		i = ne + 1
		local _, eq = s:find("^[ \t]*=[ \t]*", i)
		if eq then
			i = eq + 1
			local _, te = s:find("^[A-Za-z0-9!#$%%&'*+%-.^_`|~]+", i)
			if te then
				i = te + 1
			elseif s:sub(i, i) == '"' then
				i = i + 1
				while true do
					local c = s:sub(i, i)
					if c == "" then
						return false
					elseif c == '"' then
						i = i + 1
						break
					elseif c == "\\" then
						i = i + 2
					else
						i = i + 1
					end
				end
			else
				return false
			end
		end
	end
	return true
end

function Parser:st_chunk_size()
	local e = self.buf:find("\r\n", self.pos, true)
	if not e then
		if self:avail() > self.lim.max_chunk_line then
			return self:fail("chunk", "chunk size line too long")
		end
		if self.ended then
			return self:fail("truncated", "stream ended inside a chunk size")
		end
		return nil
	end
	local line = self.buf:sub(self.pos, e - 1)
	if #line > self.lim.max_chunk_line then
		return self:fail("chunk", "chunk size line too long")
	end
	if line:find("[%z\1-\8\10-\31\127]") then
		return self:fail("chunk", "bad character in chunk size line")
	end
	local hex, ext = line:match("^(%x+)(.*)$")
	if not hex or not chunk_ext(ext) then
		return self:fail("chunk", "bad chunk size line")
	end
	hex = hex:gsub("^0+(%x)", "%1")
	if #hex > 13 then
		return self:fail("body", "chunk too large", 413)
	end
	local size = tonumber(hex, 16)
	if self.body + size > self.lim.max_body then
		return self:fail("body", "body too large", 413)
	end
	self.pos = e + 2
	if size == 0 then
		self.state = "trailer"
	else
		self.state, self.left = "chunk_data", size
	end
	return AGAIN
end

function Parser:st_chunk_data()
	local n = math.min(self:avail(), self.left)
	if n == 0 then
		if self.ended then
			return self:fail("truncated", "stream ended inside a chunk")
		end
		return nil
	end
	local s = self:take(n)
	self.left, self.body = self.left - n, self.body + n
	if self.left == 0 then
		self.state = "chunk_end"
	end
	return { type = "data", data = s }
end

function Parser:st_chunk_end()
	if self:avail() < 2 then
		if self.ended then
			return self:fail("truncated", "stream ended after chunk data")
		end
		return nil
	end
	if self.buf:sub(self.pos, self.pos + 1) ~= "\r\n" then
		return self:fail("chunk", "chunk data does not end in CRLF")
	end
	self.pos = self.pos + 2
	self.state = "chunk_size"
	return AGAIN
end

function Parser:st_trailer()
	local buf, pos = self.buf, self.pos
	if buf:sub(pos, pos + 1) == "\r\n" then
		self.pos = pos + 2
		self.state = "done"
		return AGAIN
	end
	local e = buf:find("\r\n\r\n", pos, true)
	if not e then
		if self:avail() > self.lim.max_trailer then
			return self:fail("head", "trailer section too large", 431)
		end
		if self.ended then
			return self:fail("truncated", "stream ended inside trailers")
		end
		return nil
	end
	if e + 4 - pos > self.lim.max_trailer then
		return self:fail("head", "trailer section too large", 431)
	end
	local h, why, status = fields(buf:sub(pos, e + 1), 1, self.lim.max_fields)
	if not h then
		return self:fail("field", why, status)
	end
	self.pos = e + 4
	self.state = "done"
	return { type = "trailers", headers = h }
end

function Parser:st_done()
	local msg = self.msg
	self.msg = nil
	self.state = msg.keep_alive and "head" or "closed"
	return { type = "done" }
end

function Parser:st_tunnel_done()
	self.msg = nil
	self.state = "tunnel"
	return { type = "done", tunnel = true }
end

M.Parser = Parser

return M
