-- SPDX-License-Identifier: ISC

--[[- The mhttpx process: a master that binds the ports, and a worker
that serves.

The master keeps root, binds every listen address and starts one
worker. The worker reads the TLS files, drops to the configured user,
pledges on OpenBSD, and serves on one `mhttp.io.poll` loop. SIGHUP makes
the master read the config again and start a new worker; the old one
stops accepting and ends when its connections end, or after `drain`
seconds. A worker that dies is started again.

@module mhttpx.daemon
]]

local unistd = require("posix.unistd")
local signal = require("posix.signal")
local wait = require("posix.sys.wait")
local pwd = require("posix.pwd")
local ppoll = require("posix.poll")
local posix = require("mhttp.io.posix")
local mpoll = require("mhttp.io.poll")
local server = require("mhttp.server")
local client = require("mhttp.client")
local tls = require("mhttp.tls")
local clock = require("mhttp.clock")
local rules = require("mhttpx.rules")

local M = {}

local function log(fmt, ...)
	io.stderr:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), "mhttpx[", unistd.getpid(), "]: ",
		fmt:format(...), "\n")
end
M.log = log

--- Splits "addr:port", "[v6]:port" or "port" into address and port.
function M.parse_listen(s)
	local addr, port = s:match("^%[(.+)%]:(%d+)$")
	if not addr then
		addr, port = s:match("^([^:]*):(%d+)$")
	end
	if not addr then
		addr, port = "0.0.0.0", s:match("^(%d+)$")
	end
	if not port then
		return nil, "bad listen address " .. s
	end
	if addr == "" or addr == "*" then
		addr = "0.0.0.0"
	end
	return addr, tonumber(port)
end

local KINDS = { "http", "https" }
local FIELDS = {}
for name in ("user access_log drain pledge listen certs tls acme default sites server_name "
	.. "upstream_tls upstream_idle connect_timeout backlog max_body idle head body write "
	.. "promises unveil "
	.. "max_conns https_port"):gmatch("%S+") do
	FIELDS[name] = true
end

-- Turns a cert name into the paths acme-client uses.
local function cert_pair(c)
	if type(c) == "string" then
		return { "/etc/ssl/" .. c .. ".crt", "/etc/ssl/private/" .. c .. ".key" }
	end
	return c
end

--[[- Loads and checks a config file. See mhttpx.conf.example.
@return the config, or nil and the reason
]]
function M.load(path)
	local env = setmetatable({}, { __index = _G })
	local chunk, err = loadfile(path, "t", env)
	if not chunk then
		return nil, err
	end
	local ok, cfg = pcall(chunk)
	if not ok then
		return nil, cfg
	end
	if type(cfg) ~= "table" then
		return nil, path .. ": the config returns a table"
	end
	for k in pairs(cfg) do
		if not FIELDS[k] then
			return nil, "unknown field " .. tostring(k)
		end
	end
	if type(cfg.listen) ~= "table" then
		return nil, "listen needs http or https addresses"
	end
	local n = 0
	for k, v in pairs(cfg.listen) do
		if k ~= "http" and k ~= "https" then
			return nil, "listen: unknown kind " .. tostring(k)
		end
		if type(v) == "string" then
			v = { v }
			cfg.listen[k] = v
		end
		for _, l in ipairs(v) do
			local a, port = M.parse_listen(l)
			if not a then
				return nil, ("listen %s: %s"):format(k, port)
			end
			if k == "https" and not cfg.https_port then
				cfg.https_port = port
			end
			n = n + 1
		end
	end
	if n == 0 then
		return nil, "listen needs http or https addresses"
	end
	if cfg.listen.https and #cfg.listen.https > 0 then
		local t = {}
		for k, v in pairs(cfg.tls or {}) do
			t[k] = v
		end
		local certs = {}
		for _, c in ipairs(t.certs or {}) do
			certs[#certs + 1] = cert_pair(c)
		end
		for _, c in ipairs(cfg.certs or {}) do
			certs[#certs + 1] = cert_pair(c)
		end
		t.certs = #certs > 0 and certs or nil
		if not t.certs and not t.cert then
			return nil, "https needs certs"
		end
		cfg.tls = t
	end
	-- Compile once now, so a bad site fails here and not in a worker.
	local cok, cerr = pcall(rules.compile, cfg, M.env(cfg, "https", { check = true }))
	if not cok then
		return nil, tostring(cerr)
	end
	return cfg
end

--- The env of rules.compile for one kind of listener, over base.
function M.env(cfg, kind, base)
	return setmetatable({
		kind = kind,
		has_https = cfg.listen.https ~= nil and #cfg.listen.https > 0,
		https_port = cfg.https_port,
	}, { __index = base })
end

-- The access log line of one request.
local function access(out, req, res, t0)
	local peer = req.peer and req.peer.addr or "-"
	out:write(("%s %s %s \"%s %s HTTP/%s\" %d %.3f\n"):format(
		os.date("!%Y-%m-%dT%H:%M:%SZ"), peer, req.headers:get("host") or "-",
		req.method, req.target, req.version or "1.1", res.status or 0, clock.now() - t0))
end

-- Drops root: the groups, the group, then the user.
local function drop(user)
	local pw = pwd.getpwnam(user)
	if not pw then
		error("no such user: " .. user, 0)
	end
	local sys = require("mhttp.sys")
	assert(sys.setgroups({ pw.pw_gid }))
	assert(unistd.setpid("g", pw.pw_gid))
	assert(unistd.setpid("u", pw.pw_uid))
	assert(unistd.getuid() == pw.pw_uid and unistd.geteuid() == pw.pw_uid, "setuid failed")
end

-- Restricts the worker on OpenBSD: pledge, and unveil for the files it
-- uses. cfg.promises and cfg.unveil add to what the actions need.
-- Elsewhere it does nothing.
local function restrict(cfg)
	local ok, sys = pcall(require, "mhttp.sys")
	if not ok or cfg.pledge == false then
		return
	end
	-- The dns promise reads /etc/hosts and /etc/resolv.conf without rpath.
	local promises = { stdio = true, inet = true, dns = true }
	local paths = { ["/etc/hosts"] = "r", ["/etc/resolv.conf"] = "r" }
	rules.actions(cfg, function(a, v)
		if a == "static" then
			promises.rpath = true
			paths[type(v) == "table" and v.root or v] = "r"
		elseif a == "cgi" then
			promises.rpath, promises.proc, promises.exec = true, true, true
			local c = type(v) == "table" and v or { root = v }
			paths[c.root or c.script] = "rx"
		elseif a == "proxy" then
			local u = type(v) == "table" and v.url or v
			if u:find("^unix:") then
				promises.unix = true
				paths[u:sub(6)] = "rw"
			end
		end
	end)
	for p in (cfg.promises or ""):gmatch("%S+") do
		promises[p] = true
	end
	for p, perm in pairs(cfg.unveil or {}) do
		paths[p] = perm
	end
	if sys.unveil("/", "") == nil then
		return
	end
	for p, perm in pairs(paths) do
		sys.unveil(p, perm)
	end
	assert(sys.unveil())
	local list = {}
	for p in pairs(promises) do
		list[#list + 1] = p
	end
	table.sort(list)
	local pl = table.concat(list, " ")
	assert(sys.pledge(pl))
	log("pledge %s", pl)
end

-- Runs one worker on the listeners. It does not return.
local function worker(cfg, listeners)
	signal.signal(signal.SIGHUP, signal.SIG_IGN)
	signal.signal(signal.SIGCHLD, signal.SIG_DFL)
	local stopping = false
	local function stop()
		stopping = true
	end
	signal.signal(signal.SIGTERM, stop)
	signal.signal(signal.SIGINT, stop)
	pcall(function()
		require("mhttp.sys").setproctitle("mhttpx: worker")
	end)

	-- Everything that reads files runs before the privileges go.
	local out = io.stdout
	if cfg.access_log and cfg.access_log ~= "-" then
		out = assert(io.open(cfg.access_log, "a"))
	end
	out:setvbuf("line")
	if cfg.tls then
		assert(tls.prepare(cfg.tls, "server"))
	end
	rules.actions(cfg, function(a, v)
		local p = type(v) == "table" and v or { url = v }
		if a == "proxy" and (p.url or ""):find("^https://") then
			assert(tls.prepare(p.tls or cfg.upstream_tls or {}, "client"))
		end
	end)
	-- Handler modules load as root, before unveil hides package.path.
	rules.actions(cfg, function(a, v)
		if a == "handler" and type(v) == "string" then
			require(v)
		end
	end)
	for _, name in ipairs({ "mhttp.static", "mhttp.cgi", "mhttp.proxy", "mhttp.date",
		"mhttp.url", "mhttp.headers", "posix.dirent", "posix.stdlib", "posix.sys.stat",
		"posix.fcntl", "posix.errno" }) do
		require(name)
	end
	pcall(tls.backend, {})
	if unistd.geteuid() == 0 then
		drop(cfg.user or "nobody")
	end
	restrict(cfg)

	local loop = mpoll.new({ on_error = function(err)
		log("%s", tostring(err))
	end })
	local env = {
		client = client.new({
			connect = function(h, p, o)
				return loop:connect(h, p, o)
			end,
			tls = cfg.upstream_tls,
			timeout = math.huge,
			idle = cfg.upstream_idle or 60,
			connect_timeout = cfg.connect_timeout or 10,
			max_idle = 32,
		}),
		spawn = function(fn)
			loop:spawn(fn)
		end,
		sleep = function(sec)
			loop:sleep(sec)
		end,
		stream = function(fd)
			return loop:stream(fd)
		end,
		connect = function(h, p, o)
			return loop:connect(h, p, o)
		end,
		log = log,
		on_error = function(err, req)
			log("upstream: %s %s: %s", req.headers:get("host") or "-", req.target,
				type(err) == "table" and err.message or tostring(err))
		end,
	}
	local servers = {}
	for _, kind in ipairs(KINDS) do
		local list = listeners[kind]
		if list and #list > 0 then
			local handle = rules.compile(cfg, M.env(cfg, kind, env))
			local srv = server.new({
				handler = function(req, res)
					local t0 = clock.now()
					local r = table.pack(handle(req, res))
					access(out, req, res, t0)
					return table.unpack(r, 1, r.n)
				end,
				on_error = function(err)
					log("handler: %s", tostring(err))
				end,
				max_body = cfg.max_body or math.huge,
				idle = cfg.idle or 60,
				head = cfg.head or 30,
				body = cfg.body or 60,
				write = cfg.write or 60,
				name = cfg.server_name,
			})
			servers[#servers + 1] = srv
			local t = kind == "https" and cfg.tls or nil
			for _, l in ipairs(list) do
				l.wait = loop.opts.wait
				l.on_close = loop.opts.on_close
				l.opts = { wait = loop.opts.wait, on_close = loop.opts.on_close, tls = t }
				loop:serve(l, srv, { max = cfg.max_conns or 1024 })
			end
		end
	end

	-- Drains on SIGTERM: no new connections, close idle ones as they
	-- finish, then exit.
	loop:spawn(function()
		while not stopping do
			loop:sleep(0.25)
		end
		log("draining")
		for _, list in pairs(listeners) do
			for _, l in ipairs(list) do
				l:close()
			end
		end
		for _, srv in ipairs(servers) do
			srv:shutdown()
		end
		local deadline = clock.after(cfg.drain or 30)
		while loop.count > 1 and clock.now() < deadline do
			loop:sleep(0.25)
		end
		out:flush()
		os.exit(0, true)
	end)
	loop:run()
	os.exit(0, true)
end

-- Binds the listeners of cfg. Old ones with the same address and kind
-- are kept.
local function bind(cfg, old)
	local all, by = {}, {}
	for _, kind in ipairs(KINDS) do
		all[kind] = {}
		for _, spec in ipairs(cfg.listen[kind] or {}) do
			local addr, port = M.parse_listen(spec)
			local key = kind .. "|" .. addr .. "|" .. port
			local l = by[key] or old[key]
			if not l then
				local err
				l, err = posix.listen(addr, port, { backlog = cfg.backlog })
				if not l then
					return nil, ("listen %s: %s"):format(spec, tostring(err))
				end
			end
			old[key] = nil
			by[key] = l
			table.insert(all[kind], l)
		end
	end
	return all, by
end

--[[- Runs the master. It returns only on an error at startup, or after
SIGTERM.
@tparam string path the config file
]]
function M.run(path)
	local cfg, err = M.load(path)
	if not cfg then
		return nil, err
	end
	local listeners, by
	listeners, by = bind(cfg, {})
	if not listeners then
		return nil, by
	end
	pcall(function()
		require("mhttp.sys").setproctitle("mhttpx: master")
	end)

	local flags = {}
	signal.signal(signal.SIGHUP, function()
		flags.hup = true
	end)
	signal.signal(signal.SIGTERM, function()
		flags.term = true
	end)
	signal.signal(signal.SIGINT, function()
		flags.term = true
	end)
	signal.signal(signal.SIGCHLD, function()
		flags.chld = true
	end)
	signal.signal(signal.SIGPIPE, signal.SIG_IGN)

	local current, last_start = nil, 0
	local function start()
		last_start = clock.now()
		local pid = assert(unistd.fork())
		if pid == 0 then
			local ok, werr = pcall(worker, cfg, listeners)
			log("worker failed: %s", tostring(werr))
			unistd._exit(ok and 0 or 1)
		end
		log("started worker %d", pid)
		return pid
	end
	current = start()

	while true do
		ppoll.poll({}, 1000)
		if flags.chld then
			flags.chld = false
			while true do
				local pid, how, code = wait.wait(-1, wait.WNOHANG)
				if not pid or pid == 0 then
					break
				end
				log("worker %d %s %s", pid, tostring(how), tostring(code))
				if pid == current then
					current = nil
				end
			end
		end
		if flags.term then
			if current then
				signal.kill(current, signal.SIGTERM)
				wait.wait(current)
			end
			log("stopped")
			return true
		end
		if flags.hup then
			flags.hup = false
			local ncfg, lerr = M.load(path)
			if not ncfg then
				log("reload: %s", lerr)
			else
				local nl, nby = bind(ncfg, by)
				if not nl then
					log("reload: %s", nby)
				else
					-- What is left in by is no longer in the config.
					for _, l in pairs(by) do
						l:close()
					end
					cfg, listeners, by = ncfg, nl, nby
					local old = current
					current = start()
					if old then
						signal.kill(old, signal.SIGTERM)
					end
					log("reloaded")
				end
			end
		end
		if not current and clock.now() - last_start > 1 then
			current = start()
		end
	end
end

return M
