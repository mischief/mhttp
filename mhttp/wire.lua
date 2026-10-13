-- SPDX-License-Identifier: ISC

--[[- HTTP/1.1 message serializer (RFC 9112). It does no I/O.

It checks every byte it writes. A CR, LF or NUL in a value is an error,
never a silent edit, so a caller cannot split a message. It also refuses
framing that a peer could read two ways: Content-Length with
Transfer-Encoding, Content-Length values that differ, and framing fields
on 1xx and 204 responses.

@module mhttp.wire
]]

local syntax = require("mhttp.syntax")
local headers = require("mhttp.headers")
local status_text = require("mhttp.status")

local M = {}

-- Writes the field lines into out. Returns true, or nil and the reason.
local function fields(out, h)
	for _, name, value in h:each() do
		if not syntax.is_token(name) then
			return nil, ("bad field name %q"):format(name)
		end
		if not syntax.is_value(value) then
			return nil, ("bad value for field %q"):format(name)
		end
		out[#out + 1] = name
		out[#out + 1] = ": "
		out[#out + 1] = value
		out[#out + 1] = "\r\n"
	end
	return true
end

-- Checks the framing fields. Returns true, or nil and the reason.
local function framing(h, request)
	local cl = h:get_all("content-length")
	local te = h:has("transfer-encoding")
	if te and #cl > 0 then
		return nil, "content-length with transfer-encoding"
	end
	for i, v in ipairs(cl) do
		if not v:find("^%d+$") then
			return nil, "bad content-length"
		end
		if i > 1 and v ~= cl[1] then
			return nil, "content-length values differ"
		end
	end
	if te then
		local list = h:tokens("transfer-encoding")
		for i, c in ipairs(list) do
			if not syntax.is_token(c) then
				return nil, "bad transfer-coding"
			end
			if c == "chunked" and i ~= #list then
				return nil, "chunked is not the final coding"
			end
		end
		if request and list[#list] ~= "chunked" then
			return nil, "a request must end its codings with chunked"
		end
	end
	return true
end

local function version(v)
	v = v or "1.1"
	if v ~= "1.1" and v ~= "1.0" then
		return nil, "version must be 1.0 or 1.1"
	end
	return v
end

--[[- Writes a request line and header fields.

@tparam string method
@tparam string target origin, absolute, authority or asterisk form
@param[opt] h a `mhttp.headers` list, or anything `headers.new` takes
@tparam[opt="1.1"] string ver "1.0" or "1.1"
@treturn[1] string the head, ending in the empty line
@return[2] nil and the reason
]]
function M.request_head(method, target, h, ver)
	if not syntax.is_token(method) then
		return nil, "bad method"
	end
	if not syntax.is_target(target) then
		return nil, "bad request target"
	end
	local v, err = version(ver)
	if not v then
		return nil, err
	end
	local ok, hs = pcall(headers.from, h)
	if not ok then
		return nil, hs
	end
	ok, err = framing(hs, true)
	if not ok then
		return nil, err
	end
	if v == "1.1" and hs:count("host") ~= 1 then
		return nil, "an HTTP/1.1 request needs one host field"
	end
	local out = { method, " ", target, " HTTP/", v, "\r\n" }
	ok, err = fields(out, hs)
	if not ok then
		return nil, err
	end
	out[#out + 1] = "\r\n"
	return table.concat(out)
end

--[[- Writes a status line and header fields.

@tparam int status 100 to 999
@tparam[opt] string reason default: the phrase from `mhttp.status`
@param[opt] h a `mhttp.headers` list, or anything `headers.new` takes
@tparam[opt="1.1"] string ver "1.0" or "1.1"
@treturn[1] string the head, ending in the empty line
@return[2] nil and the reason
]]
function M.response_head(status, reason, h, ver)
	if math.type(status) ~= "integer" or status < 100 or status > 999 then
		return nil, "bad status code"
	end
	reason = reason or status_text[status] or ""
	if not syntax.is_value(reason) then
		return nil, "bad reason phrase"
	end
	local v, err = version(ver)
	if not v then
		return nil, err
	end
	local ok, hs = pcall(headers.from, h)
	if not ok then
		return nil, hs
	end
	if (status < 200 or status == 204)
	    and (hs:has("content-length") or hs:has("transfer-encoding")) then
		return nil, "1xx and 204 responses carry no framing fields"
	end
	if v == "1.0" and hs:has("transfer-encoding") then
		return nil, "transfer-encoding in HTTP/1.0"
	end
	ok, err = framing(hs, false)
	if not ok then
		return nil, err
	end
	local out = { "HTTP/", v, " ", ("%d"):format(status), " ", reason, "\r\n" }
	ok, err = fields(out, hs)
	if not ok then
		return nil, err
	end
	out[#out + 1] = "\r\n"
	return table.concat(out)
end

--- Writes one chunk of a chunked body.
-- An empty string gives an empty string, since a chunk of size 0 would
-- end the body.
-- @tparam string data
-- @treturn string
function M.chunk(data)
	if #data == 0 then
		return ""
	end
	return ("%x\r\n"):format(#data) .. data .. "\r\n"
end

--- Writes the last chunk and the trailer section.
-- @param[opt] trailers a `mhttp.headers` list, or anything
-- `headers.new` takes
-- @treturn[1] string
-- @return[2] nil and the reason
function M.last_chunk(trailers)
	local out = { "0\r\n" }
	if trailers then
		local ok, hs = pcall(headers.from, trailers)
		if not ok then
			return nil, hs
		end
		for _, f in ipairs({ "content-length", "transfer-encoding", "host" }) do
			if hs:has(f) then
				return nil, f .. " is not allowed in trailers"
			end
		end
		local err
		ok, err = fields(out, hs)
		if not ok then
			return nil, err
		end
	end
	out[#out + 1] = "\r\n"
	return table.concat(out)
end

return M
