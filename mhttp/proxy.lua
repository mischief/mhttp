-- SPDX-License-Identifier: ISC

--[[- A reverse proxy handler.

It sends each request on to an upstream server with `mhttp.client`, and
streams both bodies, so a large upload or download is never held in
memory. It drops the hop-by-hop fields, adds X-Forwarded-For and
X-Forwarded-Proto, and keeps the Host field of the client. An Upgrade
request, such as a WebSocket, becomes a tunnel when the upstream answers
101; the tunnel needs `spawn` to copy both ways at once.

@module mhttp.proxy
]]

local client = require("mhttp.client")
local clock = require("mhttp.clock")

local M = {}

-- Copies a to b until the end, then ends the write side of b.
local function copy(a, first, b, idle)
	if first and first ~= "" then
		if not b:write(first, clock.after(idle)) then
			return
		end
	end
	while true do
		local s = a:read(65536, clock.after(idle))
		if not s then
			break
		end
		if not b:write(s, clock.after(idle)) then
			break
		end
	end
	if b.shutdown then
		b:shutdown()
	end
end

-- The client address as text, for X-Forwarded-For.
local function peer_addr(req)
	local p = req.peer
	if type(p) == "table" then
		return p.addr
	end
	return p and tostring(p)
end

--[[- Makes a proxy handler.

@tparam table opts
 - `upstream`: a base URL such as "http://10.0.0.2:8080", or
   "unix:/path/to.sock" for http over a unix socket, or `fn(req)` that
   returns one, or nil and a status to answer with
 - `client`: an `mhttp.client`; default one with `connect`, `tls`,
   `idle` (60), `connect_timeout` (10) and no whole-request timeout
 - `connect`: a connector for the default client, such as `loop.connect`
 - `tls`: TLS options for https upstreams
 - `proto`: the X-Forwarded-Proto value, such as "https"; or
   `fn(req)`. Default: nothing is added.
 - `forwarded_for` (true): append the client address to X-Forwarded-For
 - `request_headers(req, h)`, `response_headers(req, res, up)`: change
   the fields on the way through
 - `spawn(fn)`: starts fn in a new task; needed for Upgrade
 - `idle`: seconds without data before a tunnel closes (300)
 - `on_error(err, req)`: called when the upstream fails
@treturn function `handler(req, res)`
]]
function M.handler(opts)
	local cl = opts.client or client.new({
		connect = opts.connect,
		tls = opts.tls,
		timeout = math.huge,
		idle = opts.read_idle or 60,
		connect_timeout = opts.connect_timeout or 10,
		max_idle = opts.max_idle or 16,
	})
	local tunnel_idle = opts.idle or 300

	return function(req, res)
		local base, status = opts.upstream, nil
		if type(base) == "function" then
			base, status = base(req)
		end
		if not base then
			return res:send(status or 502, "no upstream\n")
		end
		if req.method == "CONNECT" or req.form ~= "origin" then
			return res:send(400, "this is not a forward proxy\n")
		end

		local h = req.headers:clone()
		local upgrade = req.headers:has_token("connection", "upgrade") and req.headers:get("upgrade")
		h:strip_hop_by_hop()
		if upgrade then
			if not opts.spawn then
				return res:send(501, "upgrade is not supported here\n")
			end
			h:add("Connection", "upgrade")
			h:add("Upgrade", upgrade)
		end
		if opts.forwarded_for ~= false then
			local addr = peer_addr(req)
			if addr then
				local prev = req.headers:get_all("x-forwarded-for")
				h:del("x-forwarded-for")
				prev[#prev + 1] = addr
				h:add("X-Forwarded-For", table.concat(prev, ", "))
			end
		end
		local proto = opts.proto
		if type(proto) == "function" then
			proto = proto(req)
		end
		if proto then
			h:set("X-Forwarded-Proto", proto)
		end
		if opts.request_headers then
			opts.request_headers(req, h)
		end

		local body, length
		if not req.done then
			body = function()
				local s, err = req:read()
				if err then
					error(err.message or tostring(err), 0)
				end
				return s
			end
			length = req.length
		end
		local unix
		if base:find("^unix:") then
			unix, base = base:sub(6), "http://localhost"
		end
		local up, err = cl:request({
			unix = unix,
			url = base:gsub("/+$", "") .. req.target,
			method = req.method,
			headers = h,
			body = body,
			length = length,
			stream = true,
		})
		if not up then
			if opts.on_error then
				opts.on_error(err, req)
			end
			if res.started then
				return res:abort()
			end
			local code = err.kind == "timeout" and 504 or 502
			return res:send(code, (code == 504 and "upstream timed out\n" or "bad gateway\n"),
				{ { "Content-Type", "text/plain; charset=utf-8" } })
		end

		local rh = up.headers:clone()
		local up_upgrade = up.status == 101 and rh:get("upgrade")
		rh:strip_hop_by_hop()
		if up.status == 101 then
			if not upgrade or not up_upgrade then
				up:close()
				return res:send(502, "unexpected 101 from upstream\n")
			end
			rh:add("Connection", "upgrade")
			rh:add("Upgrade", up_upgrade)
		end
		if opts.response_headers then
			opts.response_headers(req, res, up, rh)
		end
		res.headers = rh
		if up.status == 101 then
			local ok, serr = res:start(101)
			if not ok then
				up:close()
				return nil, serr
			end
			local down, down_rest = res:hijack()
			local upstream, up_rest = up:hijack()
			if not down or not upstream then
				if down then
					down:close()
				end
				if upstream then
					upstream:close()
				end
				return
			end
			local done = 0
			local function finish()
				done = done + 1
				if done == 2 then
					down:close()
					upstream:close()
				end
			end
			opts.spawn(function()
				copy(upstream, up_rest, down, tunnel_idle)
				finish()
			end)
			copy(down, down_rest, upstream, tunnel_idle)
			finish()
			return
		end

		local ok, serr = res:start(up.status)
		if not ok then
			up:close()
			return nil, serr
		end
		while true do
			local s, rerr = up:read()
			if not s then
				if rerr then
					if opts.on_error then
						opts.on_error(rerr, req)
					end
					return res:abort()
				end
				break
			end
			if not res:write(s) then
				up:close()
				return res:abort()
			end
		end
		return res:finish()
	end
end

return M
