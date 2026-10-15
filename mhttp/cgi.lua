-- SPDX-License-Identifier: ISC

--[[- Runs CGI programs (RFC 3875).

The handler finds the program under a directory, or runs one fixed
program. It streams the request body to the program and the program's
output to the client. A program that sends no Status gets 200, or 302
with Location. The handler never sets HTTP_PROXY (httpoxy), and the
program starts with only the CGI variables and PATH.

Needs luaposix.

@module mhttp.cgi
]]

local unistd = require("posix.unistd")
local stat = require("posix.sys.stat")
local wait = require("posix.sys.wait")
local signal = require("posix.signal")
local stdlib = require("posix.stdlib")
local posix = require("mhttp.io.posix")
local clock = require("mhttp.clock")
local url = require("mhttp.url")

local M = {}

-- Finds the program for path under root: the longest leading part that
-- is an executable file. Returns its file, SCRIPT_NAME and PATH_INFO.
local function find(root, path)
	local segs = {}
	for seg in path:gmatch("[^/]+") do
		if seg == "." or seg == ".." or seg:sub(1, 1) == "." then
			return nil
		end
		segs[#segs + 1] = seg
	end
	local file = root
	for i, seg in ipairs(segs) do
		file = file .. "/" .. seg
		local st = stat.stat(file)
		if not st then
			return nil
		end
		if stat.S_ISREG(st.st_mode) ~= 0 then
			if unistd.access(file, "x") ~= 0 then
				return nil
			end
			local rest = {}
			for j = i + 1, #segs do
				rest[#rest + 1] = segs[j]
			end
			local info = #rest > 0 and "/" .. table.concat(rest, "/") or ""
			if path:sub(-1) == "/" and info ~= "" then
				info = info .. "/"
			end
			return file, "/" .. table.concat(segs, "/", 1, i), info
		elseif stat.S_ISDIR(st.st_mode) == 0 then
			return nil
		end
	end
	return nil
end

-- Builds the CGI variables.
local function environment(req, script_name, path_info, file, opts)
	local info = req.stream_info or {}
	local loc = info["local"] or {}
	local host = req.headers:get("host") or loc.addr or ""
	local env = {
		GATEWAY_INTERFACE = "CGI/1.1",
		SERVER_PROTOCOL = "HTTP/" .. (req.version or "1.1"),
		SERVER_SOFTWARE = opts.software or "mhttp",
		REQUEST_METHOD = req.method,
		QUERY_STRING = req.query or "",
		SCRIPT_NAME = (req.base or "") .. (opts.prefix or "") .. script_name,
		SCRIPT_FILENAME = file,
		PATH_INFO = path_info ~= "" and path_info or nil,
		REQUEST_URI = req.target,
		SERVER_NAME = host:match("^%[[^%]]+%]") or host:match("^[^:]+") or "",
		SERVER_PORT = tostring(loc.port or ""),
		REMOTE_ADDR = req.peer and req.peer.addr or nil,
		REMOTE_PORT = req.peer and req.peer.port and tostring(req.peer.port) or nil,
		HTTPS = info.tls and "on" or nil,
		DOCUMENT_ROOT = opts.root,
		PATH = opts.path or "/usr/bin:/bin:/usr/local/bin",
		CONTENT_TYPE = req.headers:get("content-type"),
		CONTENT_LENGTH = req.length and tostring(req.length) or nil,
	}
	if env.PATH_INFO and opts.root then
		env.PATH_TRANSLATED = opts.root .. env.PATH_INFO
	end
	for _, name, value in req.headers:each() do
		local n = name:upper():gsub("%-", "_")
		if n ~= "PROXY" and n ~= "CONTENT_TYPE" and n ~= "CONTENT_LENGTH"
		    and not n:find("[^A-Z0-9_]") then
			local key = "HTTP_" .. n
			env[key] = env[key] and env[key] .. ", " .. value or value
		end
	end
	for k, v in pairs(opts.env or {}) do
		env[k] = v
	end
	return env
end

-- Starts the program. Returns the pid and the parent ends of its stdin
-- and stdout.
local function spawn(file, env, dir)
	local in_r, in_w = unistd.pipe()
	local out_r, out_w = unistd.pipe()
	if not in_r or not out_r then
		return nil, "pipe failed"
	end
	local pid, err = unistd.fork()
	if not pid then
		for _, fd in ipairs({ in_r, in_w, out_r, out_w }) do
			unistd.close(fd)
		end
		return nil, err
	end
	if pid == 0 then
		unistd.dup2(in_r, 0)
		unistd.dup2(out_w, 1)
		-- Close everything else this process holds: listeners, other
		-- connections, the pipes.
		for fd = 3, 4095 do
			unistd.close(fd)
		end
		signal.signal(signal.SIGPIPE, signal.SIG_DFL)
		for k in pairs(stdlib.getenv()) do
			stdlib.setenv(k, nil)
		end
		for k, v in pairs(env) do
			stdlib.setenv(k, v)
		end
		if dir then
			unistd.chdir(dir)
		end
		unistd.exec(file, {})
		unistd._exit(127)
	end
	unistd.close(in_r)
	unistd.close(out_w)
	return pid, in_w, out_r
end

-- Parses the header block of the program output.
local function parse_head(block)
	local fields, status, reason = {}, nil, nil
	for line in block:gmatch("([^\n]*)\n") do
		line = line:gsub("\r$", "")
		local name, value = line:match("^([%w!#$%%&'*+.^_`|~-]+):[ \t]*(.-)[ \t]*$")
		if not name then
			return nil, "bad header line from the program"
		end
		if name:lower() == "status" then
			status, reason = value:match("^(%d%d%d)%s*(.*)$")
			if not status then
				return nil, "bad Status from the program"
			end
			status = tonumber(status)
		else
			fields[#fields + 1] = { name, value }
		end
	end
	return fields, status, reason
end

--[[- Makes a CGI handler.

@tparam table opts
 - `root`: a directory of programs; the request path picks one, and
   the rest of the path is PATH_INFO
 - `script`: one program for every request instead; the whole path is
   PATH_INFO
 - `prefix`: what comes before the path in SCRIPT_NAME
 - `env`: more variables; `path`: the PATH variable
 - `stream(fd)`: wraps a pipe end, such as `loop.stream`; default
   `mhttp.io.posix.stream`, which blocks the process while it waits
 - `spawn(fn)`: starts a task, so the body goes in while the output
   comes out; without it the whole body goes in first
 - `sleep(sec)`: waits without blocking the loop, such as `loop.sleep`
 - `timeout`: seconds with no output before the program is killed (60)
 - `max_head`: bytes of program header (16 KiB)
 - `metrics`: an `mhttp.metrics` registry for programs running and
   failures by reason
 - `max_hold`: bytes of output to hold while the request body still
   comes in (8 MiB)
@treturn function `handler(req, res)`
]]
function M.handler(opts)
	local wrap = opts.stream or function(fd)
		return posix.stream(fd)
	end
	local timeout = opts.timeout or 60
	local max_head = opts.max_head or 16 * 1024
	local max_hold = opts.max_hold or 8 * 1024 * 1024
	local running, failures
	if opts.metrics then
		running = opts.metrics:gauge("mhttp_cgi_running", "CGI programs running")
		failures = opts.metrics:counter("mhttp_cgi_failures_total",
			"CGI requests that failed", { "reason" })
	end
	local function failed(reason)
		if failures then
			failures:inc({ reason = reason })
		end
	end

	local function reap(pid)
		if running then
			running:dec()
		end
		for _ = 1, 40 do
			local p = wait.wait(pid, wait.WNOHANG)
			if p ~= 0 then
				return
			end
			if opts.sleep then
				opts.sleep(0.05)
			else
				break
			end
		end
		signal.kill(pid, signal.SIGKILL)
		wait.wait(pid)
	end

	return function(req, res)
		local path = req.params and req.params.path and "/" .. req.params.path
			or url.decode(req.route_path or req.path or "/")
		if not path or path:find("\0", 1, true) then
			return res:send(400, "bad path\n")
		end
		local file, script_name, path_info
		if opts.script then
			file, script_name, path_info = opts.script, "", path ~= "/" and path or ""
		else
			file, script_name, path_info = find(opts.root, path)
			if not file then
				return res:send(404, "not found\n")
			end
		end
		local dir = file:match("^(.*)/[^/]*$")
		local env = environment(req, script_name, path_info, file, opts)
		local pid, in_fd, out_fd = spawn(file, env, dir)
		if not pid then
			failed("start")
			return res:send(500, "cannot start the program\n")
		end
		if running then
			running:inc()
		end
		local stdin, stdout = wrap(in_fd), wrap(out_fd)

		local fed = false
		local function feed()
			while not req.done do
				local s = req:read()
				if not s or not stdin:write(s, clock.after(timeout)) then
					break
				end
			end
			stdin:close()
			fed = true
		end
		if req.done then
			stdin:close()
			fed = true
		elseif opts.spawn then
			opts.spawn(feed)
		else
			feed()
		end

		local buf, fields, status, reason = "", nil, nil, nil
		while true do
			local s, err = stdout:read(65536, clock.after(timeout))
			if not s then
				stdout:close()
				stdin:close()
				reap(pid)
				if err == "timeout" then
					failed("timeout")
					return res:send(504, "the program timed out\n")
				end
				failed("header")
				return res:send(502, "the program ended without a header\n")
			end
			buf = buf .. s
			local i, j = buf:find("\r?\n\r?\n")
			if i then
				local ferr
				fields, status, reason = parse_head(buf:sub(1, i - 1):gsub("\r?\n", "\n") .. "\n")
				ferr = status
				if not fields then
					stdout:close()
					reap(pid)
					failed("header")
					return res:send(502, tostring(ferr) .. "\n")
				end
				buf = buf:sub(j + 1)
				break
			end
			if #buf > max_head then
				stdout:close()
				reap(pid)
				failed("header")
				return res:send(502, "the program header is too long\n")
			end
		end

		local has_location = false
		for _, f in ipairs(fields) do
			if f[1]:lower() == "location" then
				has_location = true
			end
		end
		status = status or (has_location and 302 or 200)
		res.reason = reason ~= "" and reason or nil
		-- Many clients read the response only after they sent the whole
		-- body. Hold the output until the body is in, so that neither
		-- side waits for the other.
		local held, size, ended = { buf }, #buf, false
		while not fed and size <= max_hold do
			local s, err = stdout:read(65536, clock.after(timeout))
			if not s then
				if err ~= "eof" then
					stdout:close()
					reap(pid)
					failed("timeout")
					return res:send(504, "the program timed out\n")
				end
				ended = true
				break
			end
			held[#held + 1] = s
			size = size + #s
		end
		local ok = res:start(status, fields)
		if not ok then
			stdout:close()
			reap(pid)
			failed("header")
			return res:send(502, "the program sent bad fields\n")
		end
		local first = table.concat(held)
		if first ~= "" and not res:write(first) then
			stdout:close()
			reap(pid)
			failed("aborted")
			return res:abort()
		end
		while not ended do
			local s, err = stdout:read(65536, clock.after(timeout))
			if not s then
				if err ~= "eof" then
					stdout:close()
					reap(pid)
					failed("aborted")
					return res:abort()
				end
				break
			end
			if not res:write(s) then
				stdout:close()
				reap(pid)
				failed("aborted")
				return res:abort()
			end
		end
		stdout:close()
		reap(pid)
		-- The body task still reads the request. Close the connection,
		-- so the next request does not race it.
		if not fed then
			res.conn.broken = true
		end
		return res:finish()
	end
end

return M
