-- SPDX-License-Identifier: ISC

--- URI parsing, resolution and percent-coding (RFC 3986).
-- @module mhttp.url

local M = {}

M.default_ports = { http = 80, https = 443, ws = 80, wss = 443 }

--[[- Splits a URI reference into its parts.

The result has scheme (lower case), authority, userinfo, host (IPv6
without brackets), port (a number), path, query and fragment. Absent
parts are nil; path is always a string. Bytes outside %x21-%x7E are an
error: encode them first.

@tparam string s
@treturn[1] table
@return[2] nil and the reason
]]
function M.parse(s)
	if type(s) ~= "string" or s:find("[^\33-\126]") then
		return nil, "bad character in URI"
	end
	local u = {}
	local rest = s
	local frag = rest:find("#", 1, true)
	if frag then
		u.fragment, rest = rest:sub(frag + 1), rest:sub(1, frag - 1)
	end
	local q = rest:find("?", 1, true)
	if q then
		u.query, rest = rest:sub(q + 1), rest:sub(1, q - 1)
	end
	local scheme, after = rest:match("^([A-Za-z][A-Za-z0-9+.%-]*):(.*)$")
	if scheme then
		u.scheme, rest = scheme:lower(), after
	end
	if rest:sub(1, 2) == "//" then
		local auth, path = rest:match("^//([^/]*)(.*)$")
		u.authority, rest = auth, path
		local ui, hostport = auth:match("^(.*)@(.*)$")
		if ui then
			u.userinfo = ui
		else
			hostport = auth
		end
		local host, port = hostport:match("^%[([%x:.A-Za-z%-_~!$&'()*+,;=]+)%](.*)$")
		if not host then
			host, port = hostport:match("^([^:%[%]]*)(.*)$")
		end
		if not host then
			return nil, "bad host"
		end
		if port ~= "" then
			local p = port:match("^:(%d*)$")
			if not p then
				return nil, "bad port"
			end
			if p ~= "" then
				u.port = tonumber(p)
				if #p > 5 or u.port > 65535 then
					return nil, "bad port"
				end
			end
		end
		u.host = host:lower()
	end
	u.path = rest
	return u
end

--- Returns the port of u, or the default port of its scheme.
function M.port(u)
	return u.port or M.default_ports[u.scheme]
end

--- Returns host[:port] for a Host field or a CONNECT target.
-- The port is left out when it is the default for the scheme, unless
-- always_port is true.
function M.authority(u, always_port)
	local host = u.host:find(":", 1, true) and "[" .. u.host .. "]" or u.host
	local port = M.port(u)
	if port and (always_port or port ~= M.default_ports[u.scheme]) then
		return ("%s:%d"):format(host, port)
	end
	return host
end

--- Returns the origin-form request target: path and query.
function M.target(u)
	local path = u.path ~= "" and u.path or "/"
	if u.query then
		return path .. "?" .. u.query
	end
	return path
end

--- Joins parts back into a URI string (RFC 3986 section 5.3).
function M.format(u)
	local out = {}
	if u.scheme then
		out[#out + 1] = u.scheme .. ":"
	end
	if u.host then
		out[#out + 1] = "//"
		if u.userinfo then
			out[#out + 1] = u.userinfo .. "@"
		end
		out[#out + 1] = u.host:find(":", 1, true) and "[" .. u.host .. "]" or u.host
		if u.port then
			out[#out + 1] = ":" .. u.port
		end
	end
	out[#out + 1] = u.path or ""
	if u.query then
		out[#out + 1] = "?" .. u.query
	end
	if u.fragment then
		out[#out + 1] = "#" .. u.fragment
	end
	return table.concat(out)
end

--- Removes "." and ".." segments (RFC 3986 section 5.2.4).
function M.remove_dots(input)
	local out = {}
	while #input > 0 do
		if input:sub(1, 3) == "../" then
			input = input:sub(4)
		elseif input:sub(1, 2) == "./" then
			input = input:sub(3)
		elseif input:sub(1, 3) == "/./" then
			input = input:sub(3)
		elseif input == "/." then
			input = "/"
		elseif input:sub(1, 4) == "/../" then
			input = input:sub(4)
			out[#out] = nil
		elseif input == "/.." then
			input = "/"
			out[#out] = nil
		elseif input == "." or input == ".." then
			input = ""
		else
			local seg = input:match("^/?[^/]*")
			out[#out + 1] = seg
			input = input:sub(#seg + 1)
		end
	end
	return table.concat(out)
end

--[[- Resolves a reference against a base URI (RFC 3986 section 5.2.2).
@param base a URI string or a table from `parse`
@param ref a URI string or a table from `parse`
@treturn[1] table
@return[2] nil and the reason
]]
function M.resolve(base, ref)
	local b, r, err = base, ref, nil
	if type(b) == "string" then
		b, err = M.parse(b)
		if not b then
			return nil, err
		end
	end
	if type(r) == "string" then
		r, err = M.parse(r)
		if not r then
			return nil, err
		end
	end
	local t = {}
	if r.scheme then
		t.scheme, t.userinfo, t.host, t.port = r.scheme, r.userinfo, r.host, r.port
		t.path, t.query = M.remove_dots(r.path), r.query
	else
		if r.host then
			t.userinfo, t.host, t.port = r.userinfo, r.host, r.port
			t.path, t.query = M.remove_dots(r.path), r.query
		else
			if r.path == "" then
				t.path = b.path
				t.query = r.query or b.query
			else
				if r.path:sub(1, 1) == "/" then
					t.path = M.remove_dots(r.path)
				elseif b.host and b.path == "" then
					t.path = M.remove_dots("/" .. r.path)
				else
					t.path = M.remove_dots((b.path:match("^(.*/)") or "") .. r.path)
				end
				t.query = r.query
			end
			t.userinfo, t.host, t.port = b.userinfo, b.host, b.port
		end
		t.scheme = b.scheme
	end
	t.fragment = r.fragment
	return t
end

--- Decodes %XX sequences. With plus true, "+" becomes a space.
-- @treturn[1] string
-- @return[2] nil when a "%" is not followed by two hex digits
function M.decode(s, plus)
	if plus then
		s = s:gsub("+", " ")
	end
	if s:find("%%%X") or s:find("%%%x%X") or s:find("%%%x?$") then
		return nil
	end
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

--- Encodes every byte that is not unreserved, nor in safe.
-- @tparam string s
-- @tparam[opt] string safe more bytes to keep, such as "/" for a path
function M.encode(s, safe)
	local keep = "A-Za-z0-9%-._~" .. (safe or ""):gsub("[%]%^%-%%]", "%%%0")
	return (s:gsub("[^" .. keep .. "]", function(c)
		return ("%%%02X"):format(c:byte())
	end))
end

--- Splits an application/x-www-form-urlencoded query.
-- @tparam string q the query, without "?"
-- @treturn table a list of `{name, value}`, and by name the first value
function M.query(q)
	local t = {}
	for part in (q or ""):gmatch("[^&;]+") do
		local k, v = part:match("^([^=]*)=?(.*)$")
		k, v = M.decode(k, true), M.decode(v, true)
		if k then
			t[#t + 1] = { k, v or "" }
			if t[k] == nil then
				t[k] = v or ""
			end
		end
	end
	return t
end

return M
