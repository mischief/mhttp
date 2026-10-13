-- SPDX-License-Identifier: ISC

--[[- Routes requests by method and path template.

Templates are matched one segment at a time against the raw path:

 - `/paste/new`: literal segments
 - `/paste/{id}`: one segment, decoded into `req.params.id`
 - `/paste/{id:%x+}`: one segment that matches a Lua pattern, anchored
 - `/static/*path`: the rest of the path, decoded, possibly empty

The most specific match wins, whatever the order of `route` calls:
literal, then constrained, then plain parameter, then rest. A path
that matches with another method gives 405 with Allow. HEAD uses a GET
route. OPTIONS without its own route gives 204 with Allow.

Paths with "." or ".." segments, raw or percent-encoded, get 400, so a
`*path` capture never climbs out of its directory.

@module mhttp.router
]]

local url = require("mhttp.url")

local M = {}

local Router = {}
Router.__index = Router

--- Makes a router.
-- @tparam[opt] table opts `not_found(req, res)`; `allow_dots` true to
-- pass dot segments to the handlers
-- @treturn Router
function M.new(opts)
	opts = opts or {}
	return setmetatable({
		routes = {},
		middleware = {},
		not_found = opts.not_found,
		allow_dots = opts.allow_dots,
	}, Router)
end

-- Splits a path into raw segments. "/" gives { "" }.
local function segments(path)
	local out = {}
	for seg in (path:sub(2) .. "/"):gmatch("([^/]*)/") do
		out[#out + 1] = seg
	end
	return out
end

-- Compiles a template into a list of matchers.
local function compile(template)
	assert(template:sub(1, 1) == "/", "a template starts with /")
	local parts = {}
	local segs = segments(template)
	for i, seg in ipairs(segs) do
		local name, pat = seg:match("^{([%a_][%w_]*):(.+)}$")
		if name then
			parts[i] = { kind = "pattern", name = name, pat = "^" .. pat .. "$", score = 3 }
		else
			name = seg:match("^{([%a_][%w_]*)}$")
			if name then
				parts[i] = { kind = "param", name = name, score = 2 }
			else
				name = seg:match("^%*([%a_][%w_]*)$")
				if name then
					assert(i == #segs, "a *rest segment must come last")
					parts[i] = { kind = "rest", name = name, score = 1 }
				else
					assert(not seg:find("[{}*]"), "bad template segment " .. seg)
					parts[i] = { kind = "literal", text = seg, score = 4 }
				end
			end
		end
	end
	return parts
end

-- Matches raw segments against compiled parts. Returns the params and
-- the score list, or nil.
local function match(parts, segs)
	local params, score = {}, {}
	for i, p in ipairs(parts) do
		local seg = segs[i]
		if p.kind == "rest" then
			local rest = table.concat(segs, "/", i)
			local v = url.decode(rest)
			if not v then
				return nil
			end
			params[p.name] = v
			score[i] = p.score
			return params, score
		end
		if seg == nil then
			return nil
		end
		if p.kind == "literal" then
			if seg ~= p.text then
				return nil
			end
		else
			if seg == "" then
				return nil
			end
			local v = url.decode(seg)
			if not v or (p.kind == "pattern" and not v:find(p.pat)) then
				return nil
			end
			params[p.name] = v
		end
		score[i] = p.score
	end
	if #segs ~= #parts then
		return nil
	end
	return params, score
end

-- True when score a beats score b.
local function better(a, b)
	if not b then
		return true
	end
	for i = 1, math.max(#a, #b) do
		local x, y = a[i] or 0, b[i] or 0
		if x ~= y then
			return x > y
		end
	end
	return false
end

--[[- Adds a route.
@tparam string|{string,...} method a method, a list of methods, or "*"
@tparam string template see the module description
@tparam function fn `fn(req, res)`
@treturn Router self
]]
function Router:route(method, template, fn)
	local methods = {}
	for _, m in ipairs(type(method) == "table" and method or { method }) do
		methods[m] = true
	end
	self.routes[#self.routes + 1] = {
		methods = methods, template = template, parts = compile(template), fn = fn,
	}
	return self
end

for _, m in ipairs({ "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS" }) do
	Router[m:lower()] = function(self, template, fn)
		return self:route(m, template, fn)
	end
end

--- Adds a route for every method.
function Router:any(template, fn)
	return self:route("*", template, fn)
end

--- Adds a function that runs before the routes, as `fn(req, res, next)`.
-- It calls `next()` to go on, or answers the request itself.
function Router:use(fn)
	self.middleware[#self.middleware + 1] = fn
	return self
end

--- Sends requests under prefix to another router.
-- The other router sees the path after the prefix; `req.base` holds
-- the prefix.
function Router:mount(prefix, other)
	prefix = prefix:gsub("/+$", "")
	return self:any(prefix .. "/*__rest", function(req, res)
		local saved_path, saved_base = req.route_path, req.base
		req.route_path = "/" .. req.params.__rest
		req.base = (saved_base or "") .. prefix
		local r = table.pack(other:dispatch(req, res))
		req.route_path, req.base = saved_path, saved_base
		return table.unpack(r, 1, r.n)
	end)
end

local function has_dots(segs)
	for _, s in ipairs(segs) do
		local d = url.decode(s) or s
		if d == "." or d == ".." then
			return true
		end
	end
	return false
end

--- Finds the route for a method and a raw path.
-- @return the route and its params; or nil, nil and the list of
-- methods that the path allows
function Router:find(method, path)
	local segs = segments(path)
	local best, best_params, best_score
	local allowed = {}
	for _, r in ipairs(self.routes) do
		local params, score = match(r.parts, segs)
		if params then
			local ok = r.methods["*"] or r.methods[method]
				or (method == "HEAD" and r.methods.GET)
			if ok then
				if better(score, best_score) then
					best, best_params, best_score = r, params, score
				end
			else
				for m in pairs(r.methods) do
					allowed[m] = true
				end
			end
		end
	end
	if best then
		return best, best_params
	end
	local list = {}
	for m in pairs(allowed) do
		list[#list + 1] = m
	end
	if allowed.GET and not allowed.HEAD then
		list[#list + 1] = "HEAD"
	end
	table.sort(list)
	return nil, nil, list
end

-- Routes one request, without the middleware.
function Router:dispatch(req, res)
	local path = req.route_path or req.path
	if not path and req.form == "absolute" then
		local u = url.parse(req.target)
		path = u and (u.path ~= "" and u.path or "/")
	end
	if not path then
		return res:send(400, "bad request target\n")
	end
	local segs = segments(path)
	if not self.allow_dots and has_dots(segs) then
		return res:send(400, "dot segments are not allowed\n")
	end
	local r, params, allowed = self:find(req.method, path)
	if r then
		local saved = req.params
		req.params = params
		local out = table.pack(r.fn(req, res))
		req.params = saved
		return table.unpack(out, 1, out.n)
	end
	if #allowed > 0 then
		local allow = table.concat(allowed, ", ")
		if req.method == "OPTIONS" then
			return res:send(204, "", { { "Allow", allow .. ", OPTIONS" } })
		end
		return res:send(405, "method not allowed\n", { { "Allow", allow } })
	end
	if self.not_found then
		return self.not_found(req, res)
	end
	return res:send(404, "not found\n")
end

--- Handles a request: runs the middleware, then the route.
-- Pass `router:handler()` to `mhttp.server.new`.
function Router:handle(req, res)
	local i = 0
	local function nxt()
		i = i + 1
		local mw = self.middleware[i]
		if mw then
			return mw(req, res, nxt)
		end
		return self:dispatch(req, res)
	end
	return nxt()
end

--- Returns a handler function for `mhttp.server.new`.
function Router:handler()
	return function(req, res)
		return self:handle(req, res)
	end
end

return M
