-- SPDX-License-Identifier: ISC

--[[- Turns the rules of an mhttpx server into one handler.

Rules run in order. A rule matches when each of `host`, `path` and
`method` that it has matches. A rule with only `request_headers` or
`response_headers` changes those fields and goes on. The first rule with
an action answers the request. The actions are `proxy`, `static`, `cgi`,
`redirect` and `status`. Without a match the answer is 404.

`host` and `path` take a pattern or a list. In a pattern `*` stands for
any run of characters, "/" included; `**` is the same. Host patterns
ignore case and the port.

@module mhttpx.rules
]]

local proxy = require("mhttp.proxy")
local static = require("mhttp.static")
local cgi = require("mhttp.cgi")
local headers = require("mhttp.headers")

local M = {}

-- Turns a glob into an anchored Lua pattern.
local function glob(p)
	return "^" .. p:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*+", ".*") .. "$"
end

local function list(v)
	if v == nil then
		return nil
	end
	return type(v) == "table" and v or { v }
end

local function matcher(v, lower)
	local pats = list(v)
	if not pats then
		return nil
	end
	local compiled = {}
	for i, p in ipairs(pats) do
		assert(type(p) == "string", "a pattern must be a string")
		compiled[i] = glob(lower and p:lower() or p)
	end
	return function(s)
		for _, p in ipairs(compiled) do
			if s:find(p) then
				return true
			end
		end
		return false
	end
end

local ACTIONS = { "proxy", "static", "cgi", "redirect", "status" }

-- Fills {host}, {path}, {target} and {query} in a redirect template.
local function expand(tpl, req, host)
	return (tpl:gsub("{(%w+)}", {
		host = host,
		path = req.path or "/",
		target = req.target,
		query = req.query and "?" .. req.query or "",
	}))
end

-- Makes the handler of one action.
local function action(rule, env)
	if rule.proxy then
		local p = type(rule.proxy) == "table" and rule.proxy or { url = rule.proxy }
		assert(type(p.url) == "string" and p.url:find("^https?://"), "proxy needs an http or https URL")
		local up = p.url:gsub("/+$", "")
		return proxy.handler({
			upstream = function()
				return up
			end,
			client = env.client,
			proto = env.proto,
			spawn = env.spawn,
			idle = p.idle,
			on_error = env.on_error,
		})
	elseif rule.static then
		local s = type(rule.static) == "table" and rule.static or { root = rule.static }
		return static.handler(assert(s.root, "static needs a root"), s)
	elseif rule.cgi then
		local c = type(rule.cgi) == "table" and rule.cgi or { root = rule.cgi }
		local o = {}
		for k, v in pairs(c) do
			o[k] = v
		end
		o.stream, o.spawn, o.sleep = env.stream, env.spawn, env.sleep
		return cgi.handler(o)
	elseif rule.redirect then
		local r = type(rule.redirect) == "table" and rule.redirect or { to = rule.redirect }
		local status = r.status or 301
		return function(req, res)
			local host = (req.headers:get("host") or ""):gsub(":%d+$", "")
			return res:send(status, "", { { "Location", expand(r.to, req, host) } })
		end
	end
	local status, body = rule.status, rule.body
	return function(_, res)
		return res:send(status, body or "", body and { { "Content-Type", "text/plain; charset=utf-8" } })
	end
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

--[[- Compiles rules into a handler.
@tparam table rules
@tparam table env `client` for proxies, `proto` for X-Forwarded-Proto,
`spawn`, `sleep` and `stream` from the loop, `on_error`
@treturn function `handler(req, res)`
@raise on a bad rule, with its number
]]
function M.compile(rules, env)
	local compiled = {}
	for i, rule in ipairs(rules) do
		local ok, err = pcall(function()
			local n = 0
			for _, a in ipairs(ACTIONS) do
				if rule[a] ~= nil then
					n = n + 1
				end
			end
			assert(n <= 1, "a rule has one action at most")
			assert(n == 1 or rule.request_headers or rule.response_headers,
				"a rule needs an action or header changes")
			local methods
			if rule.method then
				methods = {}
				for _, m in ipairs(list(rule.method)) do
					methods[m:upper()] = true
				end
			end
			local strip = rule.strip and rule.strip:gsub("/+$", "")
			compiled[i] = {
				host = matcher(rule.host, true),
				path = matcher(rule.path),
				methods = methods,
				request_headers = rule.request_headers,
				response_headers = rule.response_headers,
				strip = strip,
				fn = n == 1 and action(rule, env) or nil,
			}
		end)
		if not ok then
			error(("rule %d: %s"):format(i, tostring(err)), 0)
		end
	end

	return function(req, res)
		local host = (req.headers:get("host") or ""):lower():gsub(":%d+$", ""):gsub("%.$", "")
		local path = req.path or ""
		local resp = {}
		for _, r in ipairs(compiled) do
			if (not r.host or r.host(host)) and (not r.path or r.path(path))
			    and (not r.methods or r.methods[req.method]) then
				if r.request_headers then
					apply(req.headers, r.request_headers)
				end
				if r.response_headers then
					resp[#resp + 1] = r.response_headers
				end
				if r.fn then
					if #resp > 0 then
						-- Header rules win over what the action sets.
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
					if r.strip and path:sub(1, #r.strip) == r.strip then
						req.route_path = path:sub(#r.strip + 1)
						if req.route_path == "" or req.route_path:sub(1, 1) ~= "/" then
							req.route_path = "/" .. req.route_path
						end
						req.base = (req.base or "") .. r.strip
					end
					return r.fn(req, res)
				end
			end
		end
		return res:send(404, "not found\n", { { "Content-Type", "text/plain; charset=utf-8" } })
	end
end

return M
