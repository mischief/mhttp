-- SPDX-License-Identifier: ISC

--[[- TLS backend for `mhttp.tls` with luasec (OpenSSL or LibreSSL).

luasec checks the chain but not the host name, so `mhttp.tls` checks
the name. A connection owns its fd: `close` closes it.

@module mhttp.tls.luasec
]]

local ssl = require("ssl")
local core = require("ssl.core")

local M = { name = "luasec", checks_host = false }

-- Contexts load the CA file, so they are kept by their options.
local contexts = {}

local function context(cfg)
	local alpn = cfg.alpn and table.concat(cfg.alpn, ",") or ""
	local key = table.concat({ cfg.mode, tostring(cfg.verify), cfg.ca or "", cfg.ca_dir or "",
		cfg.cert or "", cfg.key or "", cfg.client_auth or "", alpn }, "\0")
	local ctx = contexts[key]
	if ctx then
		return ctx
	end
	local verify = "none"
	if cfg.mode == "client" and cfg.verify then
		verify = "peer"
	elseif cfg.mode == "server" and cfg.client_auth == "require" then
		verify = { "peer", "fail_if_no_peer_cert" }
	elseif cfg.mode == "server" and cfg.client_auth == "optional" then
		verify = "peer"
	end
	local err
	ctx, err = ssl.newcontext({
		mode = cfg.mode,
		protocol = "any",
		options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
		verify = verify,
		cafile = cfg.ca,
		capath = cfg.ca_dir,
		certificate = cfg.cert,
		key = cfg.key,
		alpn = cfg.alpn,
	})
	if not ctx then
		return nil, err
	end
	contexts[key] = ctx
	return ctx
end

local Conn = {}
Conn.__index = Conn

-- luasec reports end of stream as "closed".
local function want(err)
	if err == "closed" then
		return "eof"
	end
	return err
end

--- Starts TLS on a connected, non-blocking fd.
-- @tparam int fd
-- @tparam table cfg from `mhttp.tls`, with `mode` "client" or "server"
-- @return a connection, or nil and the reason
function M.new(fd, cfg)
	local ctx, err = context(cfg)
	if not ctx then
		return nil, err
	end
	local c
	c, err = core.create(ctx)
	if not c then
		return nil, err
	end
	core.setfd(c, fd)
	c:settimeout(0)
	-- An address is not a name, so it is not sent as one.
	if cfg.mode == "client" and cfg.sni and not cfg.sni:find("^[%d.]+$")
	    and not cfg.sni:find(":") then
		c:sni(cfg.sni)
	end
	return setmetatable({ c = c, ctx = ctx }, Conn)
end

function Conn:handshake()
	local ok, err = self.c:dohandshake()
	if ok then
		return true
	end
	return nil, want(err)
end

function Conn:read(max)
	local s, err, partial = self.c:receive(max)
	if s then
		return s
	end
	if partial and partial ~= "" then
		return partial
	end
	return nil, want(err)
end

function Conn:write(buf)
	local last, err, sent = self.c:send(buf)
	if last then
		return last
	end
	if sent and sent > 0 then
		return sent
	end
	return nil, want(err)
end

-- Turns a certificate into names and fields for `info`.
local function describe(cert)
	if not cert then
		return nil
	end
	-- Subject and issuer as libtls gives them: "/CN=x/O=y".
	local short = {
		commonName = "CN", countryName = "C", localityName = "L",
		stateOrProvinceName = "ST", organizationName = "O",
		organizationalUnitName = "OU", emailAddress = "emailAddress",
	}
	local function dn(list)
		local t = {}
		for _, e in ipairs(list or {}) do
			t[#t + 1] = "/" .. (short[e.name] or e.name or e.oid) .. "=" .. e.value
		end
		return table.concat(t)
	end
	local out = { dns = {}, ip = {}, pem = cert:pem(), subject = dn(cert:subject()),
		issuer = dn(cert:issuer()) }
	local ext = cert:extensions() or {}
	local san = ext["2.5.29.17"] or {}
	for _, n in ipairs(san.dNSName or {}) do
		out.dns[#out.dns + 1] = n
	end
	for _, n in ipairs(san.iPAddress or {}) do
		out.ip[#out.ip + 1] = n
	end
	out.not_before, out.not_after = cert:notbefore(), cert:notafter()
	return out
end

function Conn:info()
	local i = self.c:info() or {}
	local ok, why = self.c:getpeerverification()
	if not ok and type(why) == "table" then
		local msgs = {}
		for _, depth in pairs(why) do
			for _, m in ipairs(depth) do
				msgs[#msgs + 1] = m
			end
		end
		why = table.concat(msgs, "; ")
	end
	return {
		version = i.protocol,
		cipher = i.cipher,
		alpn = self.c:getalpn(),
		peer = describe(self.c:getpeercertificate()),
		verified = ok and true or false,
		verify_error = not ok and why or nil,
		sni = self.c:getsniname(),
	}
end

function Conn:close()
	if self.c then
		self.c:close()
		self.c = nil
	end
end

return M
