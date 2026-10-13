-- SPDX-License-Identifier: ISC

--- An ordered list of header fields.
-- Names compare without case. Each field keeps the name as it was given
-- and its place in the list, so a proxy can pass fields on unchanged.
-- Set-Cookie is never joined into one value (RFC 9110 section 5.3).
-- @module mhttp.headers

local syntax = require("mhttp.syntax")

local M = {}

local Headers = {}
Headers.__index = Headers

-- Fields that apply to one connection only (RFC 9110 section 7.6.1).
M.HOP_BY_HOP = {
	["connection"] = true,
	["keep-alive"] = true,
	["proxy-connection"] = true,
	["te"] = true,
	["transfer-encoding"] = true,
	["upgrade"] = true,
}

local function check(name, value)
	if not syntax.is_token(name) then
		error(("bad field name %q"):format(tostring(name)), 3)
	end
	if not syntax.is_value(value) then
		error(("bad value for field %q"):format(name), 3)
	end
end

--- Makes a header list.
-- @param[opt] init a Headers, a list of `{name, value}` pairs, or a
-- map of name to value or to a list of values. A map adds its names in
-- sorted order.
-- @treturn Headers
-- @raise on a bad name or value
function M.new(init)
	local h = setmetatable({ n = 0 }, Headers)
	if init == nil then
		return h
	end
	if getmetatable(init) == Headers then
		for _, name, value in init:each() do
			h:add(name, value)
		end
	elseif init[1] ~= nil then
		for _, p in ipairs(init) do
			h:add(p[1], p[2])
		end
	else
		local names = {}
		for name in pairs(init) do
			names[#names + 1] = name
		end
		table.sort(names)
		for _, name in ipairs(names) do
			local v = init[name]
			if type(v) == "table" then
				for _, x in ipairs(v) do
					h:add(name, x)
				end
			else
				h:add(name, v)
			end
		end
	end
	return h
end

--- Returns init when it is a Headers, else `new(init)`.
function M.from(init)
	if getmetatable(init) == Headers then
		return init
	end
	return M.new(init)
end

--- Tells if v is a Headers.
function M.is(v)
	return getmetatable(v) == Headers
end

-- Adds a field without checks. The parser has checked it already.
function Headers:_add(name, value)
	local n = self.n + 1
	self[n] = { name:lower(), value, name }
	self.n = n
end

--- Adds a field at the end.
-- @tparam string name
-- @tparam string|number value
-- @treturn Headers self
function Headers:add(name, value)
	if type(value) == "number" then
		value = ("%d"):format(value)
	end
	check(name, value)
	self:_add(name, value)
	return self
end

--- Removes every field with this name.
-- @tparam string name
-- @treturn int how many it removed
function Headers:del(name)
	local key, j, removed = name:lower(), 0, 0
	for i = 1, self.n do
		local f = self[i]
		self[i] = nil
		if f[1] == key then
			removed = removed + 1
		else
			j = j + 1
			self[j] = f
		end
	end
	self.n = j
	return removed
end

--- Replaces every field with this name by one field.
-- @treturn Headers self
function Headers:set(name, value)
	if type(value) == "number" then
		value = ("%d"):format(value)
	end
	check(name, value)
	self:del(name)
	self:_add(name, value)
	return self
end

--- Returns the values of every field with this name, in order.
-- @tparam string name
-- @treturn {string,...}
function Headers:get_all(name)
	local key, out = name:lower(), {}
	for i = 1, self.n do
		if self[i][1] == key then
			out[#out + 1] = self[i][2]
		end
	end
	return out
end

--- Returns the value of a field.
-- Several fields with one name join with ", ". For Set-Cookie it
-- returns the first; use `get_all` instead.
-- @tparam string name
-- @treturn ?string nil when there is no such field
function Headers:get(name)
	local all = self:get_all(name)
	if #all == 0 then
		return nil
	elseif #all == 1 or name:lower() == "set-cookie" then
		return all[1]
	end
	return table.concat(all, ", ")
end

--- Tells how many fields have this name.
function Headers:count(name)
	local key, n = name:lower(), 0
	for i = 1, self.n do
		if self[i][1] == key then
			n = n + 1
		end
	end
	return n
end

--- Tells if a field with this name is present.
function Headers:has(name)
	return self:count(name) > 0
end

--- Returns the elements of a token list field, in lower case.
-- It reads every field with this name, such as Connection or Upgrade.
-- @tparam string name
-- @treturn {string,...}
function Headers:tokens(name)
	local out = {}
	for _, v in ipairs(self:get_all(name)) do
		for _, e in ipairs(syntax.split_list(v)) do
			out[#out + 1] = e:lower()
		end
	end
	return out
end

--- Tells if a token list field holds token tok. tok is lower case.
function Headers:has_token(name, tok)
	for _, t in ipairs(self:tokens(name)) do
		if t == tok then
			return true
		end
	end
	return false
end

--- Iterates over the fields in order.
-- @return an iterator that gives index, name as given, and value
function Headers:each()
	local i = 0
	return function()
		i = i + 1
		local f = self[i]
		if f then
			return i, f[3], f[2]
		end
	end
end

--- Returns a copy.
function Headers:clone()
	local h = setmetatable({ n = 0 }, Headers)
	for i = 1, self.n do
		local f = self[i]
		h[i] = { f[1], f[2], f[3] }
	end
	h.n = self.n
	return h
end

--- Removes the hop-by-hop fields, for a proxy.
-- These are the fixed set in `HOP_BY_HOP` and every field that
-- Connection names.
-- @treturn Headers self
function Headers:strip_hop_by_hop()
	local drop = {}
	for k in pairs(M.HOP_BY_HOP) do
		drop[k] = true
	end
	for _, t in ipairs(self:tokens("connection")) do
		drop[t] = true
	end
	for k in pairs(drop) do
		self:del(k)
	end
	return self
end

function Headers:__len()
	return self.n
end

M.Headers = Headers

return M
