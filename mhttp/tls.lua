-- SPDX-License-Identifier: ISC

--[[- TLS streams over any backend.

A TLS stream wraps a non-blocking stream that has an fd and a wait
hook, such as one from `mhttp.io.posix`, `mhttp.io.poll` or
`mhttp.io.event`. When the backend wants to read or write, the stream
calls that wait hook, so TLS works under every loop.

DESIGN.md lists the options and the backend contract. A client verifies
the chain and the host name by default. Without a CA option it uses
SSL_CERT_FILE, SSL_CERT_DIR or the first file of `M.ca_files`.

@module mhttp.tls
]]

local M = {}

--- Backends to try, in order, when none is named.
M.backends = { "mhttp.tls.libtls", "mhttp.tls.luasec" }

--- CA bundles to look for when no CA option is given.
M.ca_files = {
	"/etc/ssl/certs/ca-certificates.crt", -- Debian, Gentoo, Alpine, Arch
	"/etc/pki/tls/certs/ca-bundle.crt", -- Fedora, RHEL
	"/etc/ssl/ca-bundle.pem", -- openSUSE
	"/etc/ssl/cert.pem", -- OpenBSD, macOS
	"/usr/local/share/certs/ca-root-nss.crt", -- FreeBSD
	"/opt/homebrew/etc/ca-certificates/cert.pem", -- Homebrew
	"/usr/local/etc/ca-certificates/cert.pem",
}

local function exists(path)
	local f = io.open(path, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

--- Returns the default CA file and directory, or nil when none is found.
function M.default_ca()
	local file, dir = os.getenv("SSL_CERT_FILE"), os.getenv("SSL_CERT_DIR")
	if file or dir then
		return file, dir
	end
	for _, f in ipairs(M.ca_files) do
		if exists(f) then
			return f
		end
	end
end

local loaded

--- Returns the backend for opts, or nil and the reason.
function M.backend(opts)
	local b = opts and opts.backend or M.default
	if type(b) == "table" then
		return b
	end
	if type(b) == "string" then
		local ok, mod = pcall(require, b)
		if not ok then
			return nil, "TLS backend " .. b .. ": " .. tostring(mod)
		end
		return mod
	end
	if loaded then
		return loaded
	end
	local why = {}
	for _, name in ipairs(M.backends) do
		local ok, mod = pcall(require, name)
		if ok then
			loaded = mod
			return mod
		end
		why[#why + 1] = name
	end
	return nil, "no TLS backend; install luasec or libtls (tried " .. table.concat(why, ", ") .. ")"
end

-- Lower case, without a trailing dot.
local function norm(name)
	return (name:lower():gsub("%.$", ""))
end

--[[- Tells whether a certificate is for host, as RFC 6125 says.

A wildcard is the whole left label, as in `*.example.com`, and stands
for exactly one label. It must have two labels to its right. The
subject common name is not used. An IP address matches only an IP
address entry.

@tparam table peer `dns` and `ip` lists, from a backend `info().peer`
@tparam string host
@treturn boolean
]]
function M.match_host(peer, host)
	if not peer or not host or host == "" then
		return false
	end
	local h = host:match("^%[(.*)%]$") or host
	if h:find(":", 1, true) or h:find("^%d+%.%d+%.%d+%.%d+$") then
		for _, ip in ipairs(peer.ip or {}) do
			if ip:lower() == h:lower() then
				return true
			end
		end
		return false
	end
	h = norm(h)
	for _, name in ipairs(peer.dns or {}) do
		name = norm(name)
		if name == h then
			return true
		end
		local rest = name:match("^%*(%.[^*]+)$")
		if rest and rest:find("%.[^.]+%.[^.]+$") then
			local first, tail = h:match("^([^.]+)(%..+)$")
			if first and tail == rest then
				return true
			end
		end
	end
	return false
end

local Stream = {}
Stream.__index = Stream

-- Runs the handshake once, then the checks.
function Stream:handshake(deadline)
	if self.ready then
		return true
	end
	if self.failed then
		return nil, self.failed
	end
	while true do
		if not self.conn then
			return nil, "closed"
		end
		local ok, err = self.conn:handshake()
		if ok then
			break
		end
		if err == "wantread" or err == "wantwrite" then
			local wok, werr = self.raw:wait(err == "wantread" and "r" or "w", deadline)
			if not wok then
				return nil, werr
			end
		else
			self.failed = "tls: " .. tostring(err)
			return nil, self.failed
		end
	end
	local info = self.conn:info()
	local cfg = self.cfg
	if cfg.mode == "client" and cfg.verify then
		-- A backend that checks in the handshake fails there instead.
		if info.verified == false then
			self.failed = "tls: certificate: " .. tostring(info.verify_error or "not verified")
		elseif not (self.backend.checks_host and cfg.host == cfg.sni) then
			local named
			if self.conn.contains_name then
				named = self.conn:contains_name(cfg.host)
			else
				named = M.match_host(info.peer, cfg.host)
			end
			if not named then
				self.failed = "tls: certificate is not for " .. tostring(cfg.host)
			end
		end
	end
	if not self.failed and cfg.verify_cb then
		local ok, why = cfg.verify_cb(info, cfg.host)
		if not ok then
			self.failed = "tls: " .. tostring(why or "rejected")
		end
	end
	if self.failed then
		return nil, self.failed
	end
	self.ready = true
	self.info_t.tls = info
	return true
end

--- Reads up to max bytes, as a `mhttp.io.posix` stream does.
function Stream:read(max, deadline)
	local ok, err = self:handshake(deadline)
	if not ok then
		return nil, err
	end
	while true do
		if not self.conn then
			return nil, "closed"
		end
		local s, rerr = self.conn:read(max or 65536)
		if s then
			return s
		end
		if rerr == "wantread" or rerr == "wantwrite" then
			local wok, werr = self.raw:wait(rerr == "wantread" and "r" or "w", deadline)
			if not wok then
				return nil, werr
			end
		else
			return nil, rerr
		end
	end
end

--- Writes all of buf.
function Stream:write(buf, deadline)
	local ok, err = self:handshake(deadline)
	if not ok then
		return nil, err
	end
	local off = 1
	while off <= #buf do
		if not self.conn then
			return nil, "closed"
		end
		local n, werr = self.conn:write(off == 1 and buf or buf:sub(off))
		if n then
			off = off + n
		elseif werr == "wantread" or werr == "wantwrite" then
			local wok, waiterr = self.raw:wait(werr == "wantread" and "r" or "w", deadline)
			if not wok then
				return nil, waiterr
			end
		else
			return nil, werr
		end
	end
	return true
end

--- Closes TLS and the fd. A second close does nothing.
function Stream:close()
	if not self.conn then
		return
	end
	local raw = self.raw
	if raw.on_close then
		raw:on_close()
	end
	local conn = self.conn
	self.conn = nil
	conn:close()
	-- The backend closed the fd.
	raw.fd = nil
end

Stream.__close = Stream.close

--- Returns the info of the raw stream, with `tls` once the handshake
-- is done: version, cipher, alpn, peer (dns, ip, subject, pem) and sni.
-- It is the same table each time, so a copy taken early fills in later.
function Stream:info()
	return self.info_t
end

-- Fills in the defaults. Returns the backend and the config, or nil
-- and the reason.
local function normalize(opts, mode)
	local backend, berr = M.backend(opts)
	if not backend then
		return nil, berr
	end
	local cfg = {}
	for k, v in pairs(opts) do
		cfg[k] = v
	end
	cfg.mode = mode
	if cfg.verify == nil then
		cfg.verify = true
	end
	cfg.host = cfg.host or cfg.sni
	if mode == "client" and cfg.verify and not cfg.ca and not cfg.ca_dir then
		cfg.ca, cfg.ca_dir = M.default_ca()
		if not cfg.ca and not cfg.ca_dir then
			return nil, "tls: no CA bundle found; set the ca option"
		end
	end
	return backend, cfg
end

--[[- Loads the files that opts name now, so that a process can read
its keys and then give up the rights to read them. `mhttp.io.posix`
calls it for a listener.
@tparam table opts
@tparam string mode "client" or "server"
@return true, or nil and the reason
]]
function M.prepare(opts, mode)
	local backend, cfg = normalize(opts, mode)
	if not backend then
		return nil, cfg
	end
	if backend.prepare then
		local ok, err = backend.prepare(cfg)
		if not ok then
			return nil, "tls: " .. tostring(err)
		end
	end
	return true
end

--- Makes every backend read its files again for new connections.
function M.reset()
	for _, name in ipairs(M.backends) do
		local mod = package.loaded[name]
		if mod and mod.reset then
			mod.reset()
		end
	end
end

-- Wraps raw in a TLS stream. Returns the stream, or nil and the reason.
local function wrap(raw, opts, mode)
	local backend, cfg = normalize(opts, mode)
	if not backend then
		return nil, cfg
	end
	local conn, err = backend.new(raw.fd, cfg)
	if not conn then
		return nil, "tls: " .. tostring(err)
	end
	local info = raw.info and raw:info() or {}
	return setmetatable({ raw = raw, conn = conn, cfg = cfg, backend = backend,
		info_t = info }, Stream)
end

--[[- Starts TLS as a client on raw and runs the handshake.
@param raw a connected stream with `fd` and `wait`
@tparam table opts see the module description
@tparam[opt] number deadline
@return the TLS stream, or nil and the reason. On an error raw is closed.
]]
function M.client(raw, opts, deadline)
	local s, err = wrap(raw, opts or {}, "client")
	if not s then
		raw:close()
		return nil, err
	end
	local ok, herr = s:handshake(deadline)
	if not ok then
		s:close()
		return nil, herr
	end
	return s
end

--[[- Starts TLS as a server on raw. The handshake runs on the first read
or write, with its deadline, so a slow client does not hold up accept.
@return the TLS stream, or nil and the reason. On an error raw is closed.
]]
function M.server(raw, opts)
	local s, err = wrap(raw, opts or {}, "server")
	if not s then
		raw:close()
		return nil, err
	end
	return s
end

return M
