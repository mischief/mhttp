-- SPDX-License-Identifier: ISC

--[[- Turns the sites of an mhttpx config into handlers.

A site has a `host`: one name or a list. Exact names win over `*.`
wildcards. A request for no site gets `default`. In a site, keys that
start with "/" are path patterns. The most specific path with an action
answers. Headers add up from the least to the most specific path. The
fields of the site itself apply to each path.

In a pattern, `*` stands for any run of characters, "/" included.

@module mhttpx.rules
]]

local proxy = require("mhttp.proxy")
local static = require("mhttp.static")
local cgi = require("mhttp.cgi")
local headers = require("mhttp.headers")
local metrics = require("mhttp.metrics")

local M = {}

M.ACTIONS = { "proxy", "static", "cgi", "handler", "redirect", "status" }

local ROUTE = {
	proxy = true, static = true, cgi = true, handler = true, redirect = true, status = true,
	body = true,
	headers = true, request_headers = true, strip = true, log = true,
}
local SITE = { host = true, http = true, https = true }
local ACME = "^/%.well%-known/acme%-challenge/"
local TEXT = { { "Content-Type", "text/plain; charset=utf-8" } }

-- Turns a pattern into an anchored Lua pattern.
local function glob(p)
	return "^" .. p:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*+", ".*") .. "$"
end

-- Ranks a pattern: a pattern without `*` first, then by the text before
-- the first `*`, then by all its text.
local function rank(p)
	local star = p:find("*", 1, true)
	if not star then
		return { 1, #p, #p }
	end
	return { 0, star - 1, #(p:gsub("%*", "")) }
end

local function more_specific(a, b)
	for i = 1, 3 do
		if a.rank[i] ~= b.rank[i] then
			return a.rank[i] > b.rank[i]
		end
	end
	return a.pattern < b.pattern
end

local function is_path(k)
	return type(k) == "string" and k:sub(1, 1) == "/"
end

--- Returns the sites of cfg as a list of {site, name, hosts}. `sites`
-- is a list of sites with a `host`, or a table keyed by host.
function M.sites(cfg)
	local t = cfg.sites
	if type(t) ~= "table" then
		error("sites must be a table", 0)
	end
	local out = {}
	for i, s in ipairs(t) do
		out[#out + 1] = { site = s, name = ("site %d"):format(i), hosts = type(s) == "table" and s.host }
	end
	local keys = {}
	for k in pairs(t) do
		if type(k) == "string" then
			keys[#keys + 1] = k
		end
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		out[#out + 1] = { site = t[k], name = k, hosts = k }
	end
	return out
end

-- The default site of cfg: a URL to proxy to, a status, or a site.
local function default_site(cfg)
	local d = cfg.default
	if d == nil then
		return { status = 421, body = "unknown host\n" }
	elseif type(d) == "string" then
		return { proxy = d }
	elseif type(d) == "number" then
		return { status = d }
	end
	return d
end

-- The route of cfg.acme: a URL to proxy to, or a directory.
local function acme_route(cfg)
	local a = cfg.acme
	if a == nil then
		return nil
	elseif type(a) == "string" and a:find("^https?://") then
		return { proxy = a }
	elseif type(a) == "string" then
		return { static = a, strip = "/.well-known/acme-challenge" }
	end
	return a
end

--- Calls fn(action, value) for each action in cfg, as for "static" and
-- its root, and fn("log", value) for each log setting.
function M.actions(cfg, fn)
	local function visit(r)
		if type(r) ~= "table" then
			return
		end
		for _, a in ipairs(M.ACTIONS) do
			if r[a] ~= nil then
				fn(a, r[a])
			end
		end
		if r.log ~= nil then
			fn("log", r.log)
		end
		for k, v in pairs(r) do
			if is_path(k) then
				visit(v)
			end
		end
	end
	for _, e in ipairs(M.sites(cfg)) do
		visit(e.site)
	end
	visit(default_site(cfg))
	visit(acme_route(cfg))
	if cfg.log ~= nil then
		fn("log", cfg.log)
	end
end

--- Checks a log setting: true, false, "-", "syslog", a path or a
-- function. Returns it, or raises.
function M.check_log(v)
	local t = type(v)
	if t == "boolean" or t == "function" or v == "-" or v == "syslog"
	    or t == "string" and v:sub(1, 1) == "/" then
		return v
	end
	error("log must be true, false, \"-\", \"syslog\", a path or a function", 0)
end

--- The name of a handler module, from a name or a table with `module`.
function M.module_name(h)
	return type(h) == "table" and (h.module or h[1]) or h
end

-- Fills {host}, {path}, {target} and {query} in a redirect template.
local function expand(tpl, req, host)
	return (tpl:gsub("{(%w+)}", {
		host = host,
		path = req.path or "/",
		target = req.target,
		query = req.query and "?" .. req.query or "",
	}))
end

--[[- Makes the handler of a `handler` action.

The value is a function `handler(req, res)`, the name of a module, or a
table `{ module = name, ... }` that the module gets as `env.config`.
The module returns a handler, or a table with `new(env)` that returns
one. env has `spawn`, `sleep`, `stream`, `connect`, `client`, `log` and
`metrics`, an `mhttp.metrics` registry for the metrics of the module.
The worker loads the module before it drops root.
]]
function M.handler(h, env)
	if type(h) == "function" then
		return h
	end
	local name = M.module_name(h)
	assert(type(name) == "string", "handler must be a function, a module name or a table with module")
	if env.check then
		assert(package.searchpath(name, package.path) or package.searchpath(name, package.cpath),
			"no module " .. name)
		return function() end
	end
	-- http and https share one instance of each module and config.
	if env.instances and env.instances[h] then
		return env.instances[h]
	end
	local m = require(name)
	if type(m) == "table" and m.new then
		m = m.new(setmetatable({ config = type(h) == "table" and h or {} }, { __index = env }))
	end
	assert(type(m) == "function", "module " .. name .. " gives no handler")
	if env.instances then
		env.instances[h] = m
	end
	return m
end

-- Makes the handler of the action in r, or returns nil.
local function action(r, env)
	if r.proxy then
		local p = type(r.proxy) == "table" and r.proxy or { url = r.proxy }
		assert(type(p.url) == "string" and (p.url:find("^https?://") or p.url:find("^unix:/")),
			"proxy needs an http, https or unix:/ URL")
		local up = p.url:gsub("/+$", "")
		return proxy.handler({
			upstream = function()
				return up
			end,
			client = env.client,
			proto = env.kind,
			spawn = env.spawn,
			idle = p.idle,
			on_error = env.on_error,
			metrics = env.metrics,
			name = up,
		})
	elseif r.static then
		local s = type(r.static) == "table" and r.static or { root = r.static }
		return static.handler(assert(s.root, "static needs a root"), s)
	elseif r.cgi then
		local c = type(r.cgi) == "table" and r.cgi or { root = r.cgi }
		local o = {}
		for k, v in pairs(c) do
			o[k] = v
		end
		o.stream, o.spawn, o.sleep, o.metrics = env.stream, env.spawn, env.sleep, env.metrics
		return cgi.handler(o)
	elseif r.handler then
		return M.handler(r.handler, env)
	elseif r.redirect then
		local d = type(r.redirect) == "table" and r.redirect or { to = r.redirect }
		assert(type(d.to) == "string", "redirect needs a target")
		local status = d.status or 301
		return function(req, res)
			local host = (req.headers:get("host") or ""):gsub(":%d+$", "")
			return res:send(status, "", { { "Location", expand(d.to, req, host) } })
		end
	elseif r.status or r.body then
		local status, body = r.status or 200, r.body
		assert(math.type(status) == "integer", "status must be a number")
		assert(body == nil or type(body) == "string", "body must be a string")
		return function(_, res)
			return res:send(status, body or "", body and TEXT)
		end
	end
	return nil
end

-- Compiles one route: the fields of a path, or of a site itself.
local function route(r, env, where, pattern)
	local n = 0
	for _, a in ipairs(M.ACTIONS) do
		if r[a] ~= nil then
			n = n + 1
		end
	end
	if n > 1 then
		error(where .. ": one action at most", 0)
	end
	for _, f in ipairs({ "headers", "request_headers" }) do
		if r[f] ~= nil and type(r[f]) ~= "table" then
			error(("%s: %s must be a table"):format(where, f), 0)
		end
	end
	local strip = r.strip
	if strip == true then
		strip = pattern:match("^[^*]*")
	end
	if strip ~= nil and type(strip) ~= "string" then
		error(where .. ": strip must be a path or true", 0)
	end
	local ok, fn = pcall(action, r, env)
	if not ok then
		error(("%s: %s"):format(where, tostring(fn)), 0)
	end
	if r.log ~= nil then
		local lok, lerr = pcall(M.check_log, r.log)
		if not lok then
			error(("%s: %s"):format(where, lerr), 0)
		end
	end
	return {
		fn = fn,
		headers = r.headers,
		request_headers = r.request_headers,
		strip = strip and strip:gsub("/+$", ""),
		log = r.log,
	}
end

-- Compiles a site. has_https says if the config has https listeners.
local function site(s, env, where, has_https)
	if type(s) ~= "table" then
		error(where .. ": a site must be a table", 0)
	end
	local base, paths = {}, {}
	for k, v in pairs(s) do
		if is_path(k) then
			if type(v) ~= "table" then
				error(("%s %s: a path takes a table"):format(where, k), 0)
			end
			for f in pairs(v) do
				if not ROUTE[f] then
					error(("%s %s: unknown field %s"):format(where, k, tostring(f)), 0)
				end
			end
			paths[#paths + 1] = { pattern = k, rank = rank(k), match = glob(k),
				r = route(v, env, where .. " " .. k, k) }
		elseif ROUTE[k] then
			base[k] = v
		elseif not SITE[k] then
			error(("%s: unknown field %s"):format(where, tostring(k)), 0)
		end
	end
	table.sort(paths, more_specific)
	local https = s.https ~= false and has_https
	local http = s.http
	if http == nil then
		http = https and "redirect" or "serve"
	end
	if http ~= "redirect" and http ~= "serve" and http ~= false then
		error(where .. ": http must be \"redirect\", \"serve\" or false", 0)
	end
	return { base = route(base, env, where, ""), paths = paths, http = http, https = https }
end

-- Applies a header table: a string sets, false deletes.
local function apply(h, t)
	local names = {}
	for name in pairs(t) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local v = t[name]
		if v == false then
			h:del(name)
		else
			h:set(name, v)
		end
	end
end

-- Runs the route of one request in a compiled site.
local function serve(cs, req, res)
	local path = req.path or "/"
	local chain = { cs.base }
	for i = #cs.paths, 1, -1 do
		local p = cs.paths[i]
		if path:find(p.match) then
			chain[#chain + 1] = p.r
		end
	end
	local resp, fn, strip = {}, nil, nil
	for _, r in ipairs(chain) do
		if r.request_headers then
			apply(req.headers, r.request_headers)
		end
		if r.headers then
			resp[#resp + 1] = r.headers
		end
		if r.fn then
			fn, strip = r.fn, r.strip
		end
		if r.log ~= nil then
			req.log = r.log
		end
	end
	if #resp > 0 then
		-- Header changes win over what the action sets.
		local start = res.start
		res.start = function(self, status, h)
			if h then
				for _, name, value in headers.from(h):each() do
					self.headers:add(name, value)
				end
			end
			for _, t in ipairs(resp) do
				apply(self.headers, t)
			end
			return start(self, status)
		end
	end
	if not fn then
		return res:send(404, "not found\n", TEXT)
	end
	if strip and strip ~= "" and path:sub(1, #strip) == strip then
		req.route_path = path:sub(#strip + 1)
		if req.route_path:sub(1, 1) ~= "/" then
			req.route_path = "/" .. req.route_path
		end
		req.base = (req.base or "") .. strip
	end
	return fn(req, res)
end

--[[- Compiles the sites of cfg into the handler of one kind of listener.
@tparam table cfg the config
@tparam table env `kind` ("http" or "https"), `has_https`, `https_port`,
`client` for proxies, `spawn`, `sleep` and `stream` from the loop,
`on_error`, `metrics` for an `mhttp.metrics` registry
@treturn function `handler(req, res)`
@raise on a bad site, with its name
]]
function M.compile(cfg, env)
	local kind, has_https = env.kind, env.has_https
	local exact, wild = {}, {}
	for _, e in ipairs(M.sites(cfg)) do
		local cs = site(e.site, env, e.name, has_https)
		local hosts = e.hosts
		if type(hosts) == "string" then
			hosts = { hosts }
		end
		if type(hosts) ~= "table" or #hosts == 0 then
			error(e.name .. ": no host", 0)
		end
		-- The site label of the metrics.
		cs.name = tostring(hosts[1]):lower()
		for _, h in ipairs(hosts) do
			if type(h) ~= "string" then
				error(e.name .. ": a host must be a string", 0)
			end
			h = h:lower()
			if h:find("*", 1, true) then
				wild[#wild + 1] = { pattern = h, rank = rank(h), match = glob(h), site = cs }
			elseif exact[h] then
				error(("%s: host %s is in two sites"):format(e.name, h), 0)
			else
				exact[h] = cs
			end
		end
	end
	table.sort(wild, more_specific)
	local dflt = site(default_site(cfg), env, "default", has_https)
	dflt.name = "default"
	local acme = acme_route(cfg)
	if acme then
		acme = site(acme, env, "acme", has_https)
		acme.name = "acme"
	end
	local port = env.https_port and env.https_port ~= 443 and ":" .. env.https_port or ""

	local function lookup(host)
		local cs = exact[host]
		if not cs then
			for _, w in ipairs(wild) do
				if host:find(w.match) then
					cs = w.site
					break
				end
			end
		end
		if cs and (kind == "https" and cs.https or kind == "http" and cs.http) then
			return cs
		end
		return dflt
	end

	-- Finds the site, then answers through answer. With metrics, answer
	-- counts each request under its site.
	local answer = function(req, res)
		local cs, host = req.site, req.site_host
		req.log = cs.base.log
		if cs == acme then
			return serve(cs, req, res)
		elseif kind == "http" and cs.http == "redirect" then
			if host == "" then
				return res:send(400, "no host\n", TEXT)
			end
			return res:send(301, "", { { "Location", "https://" .. host .. port .. req.target } })
		elseif kind == "http" and not cs.http or kind == "https" and not cs.https then
			return res:send(421, "unknown host\n", TEXT)
		end
		return serve(cs, req, res)
	end
	if env.metrics then
		answer = metrics.instrument(env.metrics, answer, {
			prefix = "mhttpx",
			names = { "site", "scheme" },
			labels = function(req)
				return { site = req.site.name, scheme = kind }
			end,
		})
	end
	-- The client address: the peer, or with trust_forwarded the last
	-- X-Forwarded-For entry when the peer is trusted. A unix socket peer
	-- is "unix".
	local trust = cfg.trust_forwarded
	local trusted = {}
	for _, a in ipairs(type(trust) == "table" and trust or {}) do
		trusted[a] = true
	end
	local function client(req)
		local p = req.peer
		local addr = type(p) == "table" and p.addr or nil
		if trust == true or trusted[addr or "unix"] then
			local all = req.headers:get_all("x-forwarded-for")
			local last = all[#all] and all[#all]:match("([^,%s]+)%s*$")
			if last then
				return last
			end
		end
		return addr
	end
	local function route(req, res)
		if kind == "http" and acme and (req.path or ""):find(ACME) then
			req.site, req.site_host = acme, ""
			return answer(req, res)
		end
		local host = (req.headers:get("host") or ""):lower():gsub(":%d+$", ""):gsub("%.$", "")
		req.site, req.site_host = lookup(host), host
		return answer(req, res)
	end
	return function(req, res)
		req.client = client(req)
		return route(req, res)
	end
end

return M
