-- SPDX-License-Identifier: ISC

--[[- TLS backend for `mhttp.tls` with libtls.

libtls is in OpenBSD base, and libretls gives it on Linux. It checks the
chain and the host name in the handshake. A connection owns its fd:
`close` closes it.

@module mhttp.tls.libtls
]]

local core = require("mhttp.tls.libtls_core")

local M = { name = "libtls", checks_host = true }

-- A config holds the loaded CA, cert and key, so configs are kept by
-- their options. A server context is kept the same way.
local configs, servers = {}, {}

local function keyof(cfg)
	local alpn = cfg.alpn and table.concat(cfg.alpn, ",") or ""
	return table.concat({ cfg.mode, tostring(cfg.verify), cfg.ca or "", cfg.ca_dir or "",
		cfg.cert or "", cfg.key or "", cfg.client_auth or "", alpn }, "\0")
end

local function config(cfg, key)
	local c = configs[key]
	if c then
		return c
	end
	local err
	c, err = core.config({
		ca = cfg.ca,
		ca_dir = cfg.ca_dir,
		cert = cfg.cert,
		key = cfg.key,
		alpn = cfg.alpn and table.concat(cfg.alpn, ","),
		verify = cfg.verify,
		-- mhttp.tls checks the name when host differs from sni.
		verify_name = cfg.host == nil or cfg.host == cfg.sni,
		client_auth = cfg.mode == "server" and (cfg.client_auth or "none") or nil,
	})
	if not c then
		return nil, err
	end
	configs[key] = c
	return c
end

--- Starts TLS on a connected, non-blocking fd.
-- @tparam int fd
-- @tparam table cfg from `mhttp.tls`, with `mode` "client" or "server"
-- @return a connection, or nil and the reason
function M.new(fd, cfg)
	local key = keyof(cfg) .. "\0" .. tostring(cfg.host == nil or cfg.host == cfg.sni)
	local c, err = config(cfg, key)
	if not c then
		return nil, err
	end
	if cfg.mode == "client" then
		local ctx
		ctx, err = core.client(c)
		if not ctx then
			return nil, err
		end
		local ok
		ok, err = ctx:connect(fd, cfg.sni or cfg.host)
		if not ok then
			ctx:close()
			return nil, err
		end
		return ctx
	end
	local srv = servers[key]
	if not srv then
		srv, err = core.server(c)
		if not srv then
			return nil, err
		end
		servers[key] = srv
	end
	return srv:accept(fd)
end

return M
