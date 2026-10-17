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
local metrics = require("mhttp.metrics")
local clock = require("mhttp.clock")
local rules = require("mhttpx.rules")

local M = {}

local function log(fmt, ...)
	io.stderr:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), "mhttpx[", unistd.getpid(), "]: ",
		fmt:format(...), "\n")
end
M.log = log

--- Logs msg, and sends it to syslog at warning level.
function M.warn(msg)
	log("%s", msg)
	local ok, syslog = pcall(require, "posix.syslog")
	if ok then
		syslog.openlog("mhttpx", syslog.LOG_PID, syslog.LOG_DAEMON)
		syslog.syslog(syslog.LOG_WARNING, msg)
	end
end

--[[- Splits a listen address into address and port: "addr:port",
"[v6]:port" or "port". "unix:/path" gives "unix" and the path. An entry
can be a table, `{ "unix:/path", mode = "0660", owner = "user", group =
"group" }`; the extra fields go to the socket file.
@return address, port and the table, or nil and the reason
]]
function M.parse_listen(e)
	local s, extra = e, nil
	if type(e) == "table" then
		s, extra = e[1], e
	end
	if type(s) ~= "string" then
		return nil, "bad listen address " .. tostring(s)
	end
	local path = s:match("^unix:(/.+)$")
	if path then
		return "unix", path, extra
	elseif extra then
		return nil, "only a unix socket takes a table: " .. s
	end
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

local KINDS = { "http", "https", "metrics" }
local FIELDS = {}
for name in ("user access_log log trust_forwarded drain pledge listen certs tls acme default sites "
	.. "server_name "
	.. "upstream_tls upstream_idle connect_timeout backlog max_body idle head body write "
	.. "promises unveil max_run "
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
		if k ~= "http" and k ~= "https" and k ~= "metrics" then
			return nil, "listen: unknown kind " .. tostring(k)
		end
		-- One entry alone: a string, or a unix socket table.
		if type(v) == "string" or type(v) == "table" and (v.mode or v.owner or v.group) then
			v = { v }
			cfg.listen[k] = v
		end
		for _, l in ipairs(v) do
			local a, port = M.parse_listen(l)
			if not a then
				return nil, ("listen %s: %s"):format(k, port)
			end
			if k == "https" and a ~= "unix" and not cfg.https_port then
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
	for _, f in ipairs({ "log", "access_log" }) do
		if cfg[f] ~= nil and not pcall(rules.check_log, cfg[f]) then
			return nil, f .. ": " .. select(2, pcall(rules.check_log, cfg[f]))
		end
	end
	if type(cfg.access_log) == "boolean" or type(cfg.access_log) == "function" then
		return nil, "access_log must be \"-\", \"syslog\" or a path"
	end
	local tf = cfg.trust_forwarded
	if tf ~= nil and tf ~= true and tf ~= false and type(tf) ~= "table" then
		return nil, "trust_forwarded must be true or a list of addresses"
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

--- The default access log line of an entry.
function M.line(e)
	return ("%s %s %s \"%s %s HTTP/%s\" %d %d %.3f\n"):format(
		os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(e.time)), e.client or "-", e.host or "-",
		e.method, e.target, e.version, e.status, e.bytes, e.duration)
end

--[[- Makes the access logger of a worker: `logger(req, res, t0)`.

req.log, set by the rules, or else cfg.log, picks what happens: true
writes to cfg.access_log, false writes nothing, and a destination
writes there. A destination is "-" for stdout, "syslog", or a path that
is opened and appended for each line, so that the file can be rotated.
A function gets the entry and returns a line for cfg.access_log, or nil.
]]
function M.logger(cfg)
	local default = cfg.access_log or "-"
	local failed = {}
	local syslog
	local function write(dest, line)
		if line:sub(-1) ~= "\n" then
			line = line .. "\n"
		end
		if dest == "-" then
			io.stdout:write(line)
			return
		elseif dest == "syslog" then
			syslog = syslog or require("posix.syslog")
			syslog.openlog("mhttpx", syslog.LOG_PID, syslog.LOG_DAEMON)
			syslog.syslog(syslog.LOG_INFO, line:sub(1, -2))
			return
		end
		local f, err = io.open(dest, "a")
		if f then
			f:write(line)
			f:close()
		-- Logs a failed path once in a minute at most.
		elseif clock.now() - (failed[dest] or -math.huge) >= 60 then
			failed[dest] = clock.now()
			log("access log %s: %s", dest, tostring(err))
		end
	end
	io.stdout:setvbuf("line")
	return function(req, res, t0)
		local how = req.log
		if how == nil then
			how = cfg.log
		end
		if how == nil then
			how = true
		end
		if how == false then
			return
		end
		local e = {
			time = os.time(), client = req.client or req.peer and req.peer.addr,
			host = req.headers:get("host"), method = req.method, target = req.target,
			path = req.path, version = req.version or "1.1", status = res.status or 0,
			bytes = res.bytes or 0, duration = clock.now() - t0,
			site = req.site and req.site.name, request = req.headers, response = res.headers,
		}
		if type(how) == "function" then
			local ok, line = pcall(how, e)
			if not ok then
				log("log function: %s", tostring(line))
			elseif line then
				write(default, tostring(line))
			end
			return
		end
		write(how == true and default or how, M.line(e))
	end
end

--- The files the access log can write, for unveil.
function M.log_paths(cfg)
	local paths = {}
	local function add(v)
		if type(v) == "string" and v:sub(1, 1) == "/" then
			paths[v] = true
		end
	end
	add(cfg.access_log)
	rules.actions(cfg, function(a, v)
		if a == "log" then
			add(v)
		end
	end)
	return paths
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
	for _, list in pairs(cfg.listen) do
		for _, e in ipairs(list) do
			if M.parse_listen(e) == "unix" then
				promises.unix = true
			end
		end
	end
	-- The access log opens each file for each line, as the worker user.
	for p in pairs(M.log_paths(cfg)) do
		promises.wpath, promises.cpath = true, true
		paths[p] = "wc"
	end
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
	local access = M.logger(cfg)
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
		if a == "handler" and type(v) ~= "function" then
			require(rules.module_name(v))
		end
	end)
	for _, name in ipairs({ "posix.syslog", "mhttp.static", "mhttp.cgi", "mhttp.proxy",
		"mhttp.date", "mhttp.url", "mhttp.headers", "posix.dirent", "posix.stdlib", "posix.sys.stat",
		"posix.fcntl", "posix.errno" }) do
		require(name)
	end
	pcall(tls.backend, {})
	if unistd.geteuid() == 0 then
		drop(cfg.user or "nobody")
	end
	restrict(cfg)
	-- Say now when the worker user cannot write a log file.
	for p in pairs(M.log_paths(cfg)) do
		local f, ferr = io.open(p, "a")
		if f then
			f:close()
		else
			M.warn(("access log %s: %s"):format(p, tostring(ferr)))
		end
	end

	-- A task that runs max_run seconds without a yield fails, with its
	-- traceback in the log, so one stuck connection cannot stop the rest.
	local loop = mpoll.new({ max_run = cfg.max_run or 10, on_error = function(err)
		log("%s", tostring(err))
	end })
	local reg = metrics.new()
	local env = {
		metrics = reg,
		instances = {},
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
	-- One budget for all listeners. A proxied connection holds two fds.
	local gate = { max = cfg.max_conns or M.max_conns() }
	reg:gauge("mhttpx_connections", "open client connections", nil, function()
		return gate.n or 0
	end)
	reg:gauge("mhttpx_connections_max", "the connection limit", nil, function()
		return gate.max
	end)
	reg:gauge("mhttpx_worker_start_time_seconds", "when this worker started"):set(os.time())
	for _, kind in ipairs(KINDS) do
		local list = listeners[kind]
		if kind == "metrics" and list and #list > 0 then
			-- Scrapes have a gate of their own, so they work at the limit.
			local mhandler = reg:handler()
			local msrv = server.new({
				handler = function(req, res)
					if req.path == "/metrics" and (req.method == "GET" or req.method == "HEAD") then
						return mhandler(req, res)
					end
					return res:send(404, "not found\n")
				end,
				on_error = function(err)
					log("metrics: %s", tostring(err))
				end,
				idle = 30, head = 10, body = 10, write = 30,
				name = cfg.server_name,
			})
			servers[#servers + 1] = msrv
			for _, l in ipairs(list) do
				l.wait, l.on_close = loop.opts.wait, loop.opts.on_close
				l.opts = { wait = loop.opts.wait, on_close = loop.opts.on_close, unix = l.unix_path }
				loop:serve(l, msrv, { max = 16 })
			end
		elseif list and #list > 0 then
			local handle = rules.compile(cfg, M.env(cfg, kind, env))
			local srv = server.new({
				handler = function(req, res)
					local t0 = clock.now()
					local r = table.pack(handle(req, res))
					access(req, res, t0)
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
				l.opts = { wait = loop.opts.wait, on_close = loop.opts.on_close, tls = t,
					unix = l.unix_path }
				loop:serve(l, srv, { gate = gate })
			end
		end
	end

	-- Warns once when the connections reach 90% of the budget, and again
	-- only after they drop below 80%. Closes old idle upstream connections.
	loop:spawn(function()
		local warned, ticks = false, 0
		while not stopping do
			ticks = ticks + 1
			if ticks % 15 == 0 then
				env.client:prune()
			end
			if not warned and gate.n and gate.n >= 0.9 * gate.max then
				warned = true
				M.warn(("%d of %d connections in use"):format(gate.n, gate.max))
			elseif warned and gate.n < 0.8 * gate.max then
				warned = false
			end
			loop:sleep(1)
		end
	end)

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
		io.stdout:flush()
		os.exit(0, true)
	end)
	loop:run()
	os.exit(0, true)
end

-- Binds the listeners of cfg. Old ones with the same address and kind
-- are kept.
-- The mode and owner of a unix socket file. The owner is the worker
-- user unless the entry names one.
local function unix_opts(cfg, extra)
	extra = extra or {}
	local o = { mode = tonumber(extra.mode or "0660", 8) }
	if not o.mode then
		return nil, "bad mode " .. tostring(extra.mode)
	end
	local user = extra.owner or cfg.user
	if user and unistd.geteuid() == 0 then
		local pw = pwd.getpwnam(user)
		if not pw then
			return nil, "no such user " .. user
		end
		o.uid, o.gid = pw.pw_uid, pw.pw_gid
	end
	if extra.group then
		local grp = require("posix.grp").getgrnam(extra.group)
		if not grp then
			return nil, "no such group " .. extra.group
		end
		o.gid = grp.gr_gid
	end
	return o
end

local function bind(cfg, old)
	local all, by = {}, {}
	for _, kind in ipairs(KINDS) do
		all[kind] = {}
		for _, spec in ipairs(cfg.listen[kind] or {}) do
			local addr, port, extra = M.parse_listen(spec)
			local key = kind .. "|" .. addr .. "|" .. port
			local l = by[key] or old[key]
			local uo
			if addr == "unix" then
				local err
				uo, err = unix_opts(cfg, extra)
				if not uo then
					return nil, ("listen %s: %s"):format(port, err)
				end
			end
			if not l then
				local err
				l, err = posix.listen(addr, port, { backlog = cfg.backlog, unix = uo and port,
					mode = uo and uo.mode, uid = uo and uo.uid, gid = uo and uo.gid })
				if not l then
					return nil, ("listen %s: %s"):format(uo and port or spec, tostring(err))
				end
				l.unix_path = uo and port
			elseif uo then
				-- A kept socket takes the mode and owner of the new config.
				posix.own_unix(port, uo)
			end
			old[key] = nil
			by[key] = l
			table.insert(all[kind], l)
		end
	end
	return all, by
end

-- Closes a listener of the master, and removes its socket file.
local function unbind(l)
	l:close()
	if l.unix_path then
		os.remove(l.unix_path)
	end
end

-- Raises the soft limit of open files to the hard limit, as the login
-- class allows.
local function raise_nofile()
	local resource = require("posix.sys.resource")
	local rl = resource.getrlimit(resource.RLIMIT_NOFILE)
	if rl and rl.rlim_cur < rl.rlim_max then
		rl.rlim_cur = rl.rlim_max
		resource.setrlimit(resource.RLIMIT_NOFILE, rl)
	end
end

--- The default connection limit: half the open files, less a reserve.
function M.max_conns()
	local resource = require("posix.sys.resource")
	local rl = resource.getrlimit(resource.RLIMIT_NOFILE)
	local n = rl and rl.rlim_cur or 256
	return math.max(8, (n - 64) // 2)
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
	raise_nofile()
	log("max connections %d", cfg.max_conns or M.max_conns())
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

	-- Old workers drain, then get SIGKILL if they still run. A worker
	-- stuck in a loop never sees SIGTERM.
	local old = {}
	local function grace()
		return clock.after((cfg.drain or 30) + 5)
	end
	local function reap()
		while true do
			local pid, how, code = wait.wait(-1, wait.WNOHANG)
			if not pid or pid == 0 then
				break
			end
			log("worker %d %s %s", pid, tostring(how), tostring(code))
			old[pid] = nil
			if pid == current then
				current = nil
			end
		end
	end
	local function kill_late()
		for pid, deadline in pairs(old) do
			if clock.now() >= deadline then
				log("worker %d did not stop; killing it", pid)
				signal.kill(pid, signal.SIGKILL)
				old[pid] = nil
			end
		end
	end

	while true do
		ppoll.poll({}, 1000)
		if flags.chld then
			flags.chld = false
			reap()
		end
		kill_late()
		if flags.term then
			if current then
				signal.kill(current, signal.SIGTERM)
				old[current] = grace()
				current = nil
			end
			while next(old) do
				ppoll.poll({}, 250)
				reap()
				kill_late()
			end
			reap()
			for _, l in pairs(by) do
				unbind(l)
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
						unbind(l)
					end
					cfg, listeners, by = ncfg, nl, nby
					local prev = current
					current = start()
					if prev then
						signal.kill(prev, signal.SIGTERM)
						old[prev] = grace()
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
