-- SPDX-License-Identifier: ISC

--- Character rules from RFC 9110 and RFC 9112.
-- The parser and the serializer use the same rules, so that a value
-- that one refuses the other refuses too.
-- @module mhttp.syntax

local M = {}

-- Any byte that is not a tchar (RFC 9110 section 5.6.2).
local NOT_TCHAR = "[^A-Za-z0-9!#$%%&'*+%-.^_`|~]"

-- Control bytes except HTAB, and DEL. CR, LF and NUL are in this set.
local CTL = "[%z\1-\8\10-\31\127]"

--- Tells if s is a token: one or more tchar.
-- @tparam string s
-- @treturn boolean
function M.is_token(s)
	return type(s) == "string" and #s > 0 and not s:find(NOT_TCHAR)
end

--- Tells if s can be a field value, a reason phrase or a quoted value.
-- It allows VCHAR, obs-text, SP and HTAB.
-- @tparam string s
-- @treturn boolean
function M.is_value(s)
	return type(s) == "string" and not s:find(CTL)
end

--- Tells if s can be a request target.
-- It allows VCHAR except "#". It refuses SP, controls and obs-text.
-- @tparam string s
-- @treturn boolean
function M.is_target(s)
	return type(s) == "string" and #s > 0 and not s:find("[^\33-\126]")
		and not s:find("#", 1, true)
end

--- Tells if s can be a Host value: uri-host [ ":" port ].
-- It allows the characters of reg-name, IPv4 and IP-literal. An empty
-- value is valid (RFC 9110 section 7.2).
-- @tparam string s
-- @treturn boolean
function M.is_host(s)
	if type(s) ~= "string" then
		return false
	end
	if s == "" then
		return true
	end
	local host, port = s:match("^(%[[%x:.A-Za-z%-_~!$&'()*+,;=]+%])(.*)$")
	if not host then
		host, port = s:match("^([A-Za-z0-9%-._~%%!$&'()*+,;=]*)(.*)$")
	end
	if not host then
		return false
	end
	return port == "" or port:find("^:%d*$") ~= nil
end

--- Removes leading and trailing SP and HTAB.
-- @tparam string s
-- @treturn string
function M.trim(s)
	return (s:match("^[ \t]*(.-)[ \t]*$"))
end

--- Splits a comma list into its elements (RFC 9110 section 5.6.1).
-- Empty elements are dropped. Quoted strings are not understood, so use
-- it only for lists of tokens.
-- @tparam string s
-- @treturn {string,...} the trimmed elements
function M.split_list(s)
	local out = {}
	for e in (s .. ","):gmatch("([^,]*),") do
		e = M.trim(e)
		if e ~= "" then
			out[#out + 1] = e
		end
	end
	return out
end

return M
