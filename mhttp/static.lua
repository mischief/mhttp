-- SPDX-License-Identifier: ISC

--[[- Serves files from a directory.

It answers GET and HEAD with ETag and Last-Modified, conditional
requests (304, 412), single byte ranges (206, 416), index files, and an
optional directory listing. A path with a NUL byte, a "." or ".."
segment, or a dot file is refused. A symbolic link that leads out of
the root is refused unless `follow_links` is true.

Needs luaposix.

@module mhttp.static
]]

local stat = require("posix.sys.stat")
local stdlib = require("posix.stdlib")
local dirent = require("posix.dirent")
local url = require("mhttp.url")
local date = require("mhttp.date")

local M = {}

--- File name suffix to media type. Change it or pass `types`.
M.types = {
	html = "text/html; charset=utf-8", htm = "text/html; charset=utf-8",
	css = "text/css; charset=utf-8", js = "text/javascript; charset=utf-8",
	mjs = "text/javascript; charset=utf-8", json = "application/json",
	txt = "text/plain; charset=utf-8", md = "text/markdown; charset=utf-8",
	xml = "application/xml", csv = "text/csv; charset=utf-8",
	svg = "image/svg+xml", png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg",
	gif = "image/gif", webp = "image/webp", avif = "image/avif", ico = "image/vnd.microsoft.icon",
	woff = "font/woff", woff2 = "font/woff2", ttf = "font/ttf", otf = "font/otf",
	wasm = "application/wasm", pdf = "application/pdf", zip = "application/zip",
	gz = "application/gzip", tgz = "application/gzip", xz = "application/x-xz",
	zst = "application/zstd", tar = "application/x-tar",
	mp3 = "audio/mpeg", ogg = "audio/ogg", opus = "audio/ogg", flac = "audio/flac",
	wav = "audio/wav", mp4 = "video/mp4", webm = "video/webm", mkv = "video/x-matroska",
	sig = "text/plain; charset=utf-8", pub = "text/plain; charset=utf-8",
	iso = "application/octet-stream", img = "application/octet-stream",
}

local function html_escape(s)
	return (s:gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
		['"'] = "&quot;", ["'"] = "&#39;" }))
end

-- Strong ETag from the inode, size and modification time.
local function etag(st)
	return ('"%x-%x-%x"'):format(st.st_ino, st.st_size, st.st_mtime)
end

-- Tells whether an If-None-Match or If-Match list holds tag.
local function tag_in(list, tag, weak)
	if list:find("^%s*%*%s*$") then
		return true
	end
	for t in list:gmatch('[^,%s][^,]*') do
		t = t:match("^(.-)%s*$")
		if t == tag or (weak and t == "W/" .. tag) then
			return true
		end
	end
	return false
end

-- Parses one byte range against size. Returns first, last; or nil when
-- the field has another form; or false when no byte is in range.
local function range(field, size)
	local a, b = field:match("^bytes=(%d*)%-(%d*)$")
	if not a or (a == "" and b == "") then
		return nil
	end
	local first, last
	if a == "" then
		local n = tonumber(b)
		if n == 0 then
			return false
		end
		first, last = math.max(0, size - n), size - 1
	else
		first = tonumber(a)
		last = b == "" and size - 1 or math.min(tonumber(b), size - 1)
		if tonumber(b) and tonumber(b) < first then
			return nil
		end
	end
	if first >= size or size == 0 then
		return false
	end
	return first, last
end

-- Sends a directory listing.
local function listing(res, dir, path, hidden, head)
	local names = {}
	for name in dirent.files(dir) do
		if name ~= "." and name ~= ".." and (hidden or name:sub(1, 1) ~= ".") then
			local st = stat.stat(dir .. "/" .. name)
			if st then
				names[#names + 1] = { name = name, dir = stat.S_ISDIR(st.st_mode) ~= 0, st = st }
			end
		end
	end
	table.sort(names, function(x, y)
		if x.dir ~= y.dir then
			return x.dir
		end
		return x.name < y.name
	end)
	local t = { ("<!DOCTYPE html>\n<meta charset=\"utf-8\">\n<title>%s</title>\n<h1>%s</h1>\n<pre>\n")
		:format(html_escape(path), html_escape(path)) }
	if path ~= "/" then
		t[#t + 1] = '<a href="../">../</a>\n'
	end
	for _, e in ipairs(names) do
		local shown = e.name .. (e.dir and "/" or "")
		t[#t + 1] = ('<a href="%s">%s</a>%s %s %12s\n'):format(
			html_escape(url.encode(e.name) .. (e.dir and "/" or "")), html_escape(shown),
			(" "):rep(math.max(1, 50 - #shown)),
			os.date("!%Y-%m-%d %H:%M", e.st.st_mtime), e.dir and "-" or tostring(e.st.st_size))
	end
	t[#t + 1] = "</pre>\n"
	local body = table.concat(t)
	res.headers:set("Content-Type", "text/html; charset=utf-8")
	return res:send(200, head and "" or body, head and { { "Content-Length", #body } } or nil)
end

--[[- Makes a handler that serves files under root.

@tparam string root a directory
@tparam[opt] table opts
 - `index`: names to try for a directory ({ "index.html" }); false for none
 - `list`: true to list directories without an index file
 - `hidden`: true to serve dot files
 - `follow_links`: true to follow links that lead out of root
 - `types`: suffix to media type, in front of `M.types`
 - `default_type` ("application/octet-stream")
 - `cache`: a Cache-Control value
 - `gzip`: true to send "name.gz" when the client accepts gzip
 - `headers(path, res)`: called before each response, to add fields
 - `not_found(req, res)`: default 404
@treturn function `handler(req, res)`. It serves `req.params.path` when the
router set it, else the request path.
]]
function M.handler(root, opts)
	opts = opts or {}
	local real_root = assert(stdlib.realpath(root), "no such directory: " .. root)
	local index = opts.index
	if index == nil then
		index = { "index.html" }
	end
	local types = setmetatable(opts.types or {}, { __index = M.types })
	local default_type = opts.default_type or "application/octet-stream"
	local read_size = 64 * 1024

	local function not_found(req, res)
		if opts.not_found then
			return opts.not_found(req, res)
		end
		return res:send(404, "not found\n", { { "Content-Type", "text/plain; charset=utf-8" } })
	end

	-- Checks that path stays under the root after links.
	local function inside(path)
		if opts.follow_links then
			return true
		end
		local real = stdlib.realpath(path)
		return real and (real == real_root or real:sub(1, #real_root + 1) == real_root .. "/")
	end

	return function(req, res)
		if req.method ~= "GET" and req.method ~= "HEAD" then
			return res:send(405, "method not allowed\n", { { "Allow", "GET, HEAD" } })
		end
		local raw
		if req.params and req.params.path then
			raw = "/" .. req.params.path
		else
			raw = url.decode((req.route_path or req.path or "/"):match("^[^?]*")) or ""
		end
		if raw:find("\0", 1, true) or raw:sub(1, 1) ~= "/" then
			return res:send(400, "bad path\n")
		end
		for seg in raw:gmatch("[^/]+") do
			if seg == "." or seg == ".." or (seg:sub(1, 1) == "." and not opts.hidden) then
				return not_found(req, res)
			end
		end
		local path = real_root .. raw
		local st = stat.stat(path)
		if not st or not inside(path) then
			return not_found(req, res)
		end
		if stat.S_ISDIR(st.st_mode) ~= 0 then
			if raw:sub(-1) ~= "/" then
				-- Relative, so it works under any mount or prefix.
				local loc = url.encode(raw:match("([^/]+)$")) .. "/"
				if req.query then
					loc = loc .. "?" .. req.query
				end
				return res:send(301, "", { { "Location", loc } })
			end
			local found
			for _, name in ipairs(index or {}) do
				local ist = stat.stat(path .. name)
				if ist and stat.S_ISREG(ist.st_mode) ~= 0 then
					found, path, st = true, path .. name, ist
					break
				end
			end
			if not found then
				if opts.list then
					if opts.headers then
						opts.headers(raw, res)
					end
					return listing(res, path, raw, opts.hidden, req.method == "HEAD")
				end
				return not_found(req, res)
			end
		elseif stat.S_ISREG(st.st_mode) == 0 then
			return not_found(req, res)
		end

		local h = res.headers
		local suffix = path:match("%.([%w]+)$")
		h:set("Content-Type", suffix and types[suffix:lower()] or default_type)
		if opts.gzip then
			h:set("Vary", "Accept-Encoding")
			local ae = req.headers:get("accept-encoding") or ""
			if ae:lower():find("gzip") then
				local gst = stat.stat(path .. ".gz")
				if gst and stat.S_ISREG(gst.st_mode) ~= 0 and inside(path .. ".gz") then
					path, st = path .. ".gz", gst
					h:set("Content-Encoding", "gzip")
				end
			end
		end
		local tag, mtime = etag(st), st.st_mtime
		h:set("ETag", tag)
		h:set("Last-Modified", date.format(mtime))
		h:set("Accept-Ranges", "bytes")
		if opts.cache then
			h:set("Cache-Control", opts.cache)
		end
		if opts.headers then
			opts.headers(raw, res)
		end

		-- RFC 9110 section 13.2.2: the order of the preconditions.
		local im, ius = req.headers:get("if-match"), req.headers:get("if-unmodified-since")
		if im then
			if not tag_in(im, tag, false) then
				return res:send(412, "")
			end
		elseif ius then
			local t = date.parse(ius)
			if t and mtime > t then
				return res:send(412, "")
			end
		end
		local inm, ims = req.headers:get("if-none-match"), req.headers:get("if-modified-since")
		if inm then
			if tag_in(inm, tag, true) then
				return res:send(304, "")
			end
		elseif ims then
			local t = date.parse(ims)
			if t and mtime <= t then
				return res:send(304, "")
			end
		end

		local size = st.st_size
		local first, last = 0, size - 1
		local status = 200
		local rf = req.headers:get("range")
		if rf and req.method == "GET" then
			local ir = req.headers:get("if-range")
			local fresh = not ir or ir == tag or date.parse(ir) == mtime
			if fresh then
				local a, b = range(rf, size)
				if a == false then
					h:set("Content-Range", "bytes */" .. size)
					return res:send(416, "")
				elseif a then
					first, last, status = a, b, 206
					h:set("Content-Range", ("bytes %d-%d/%d"):format(a, b, size))
				end
			end
		end

		local len = math.max(0, last - first + 1)
		h:set("Content-Length", len)
		if req.method == "HEAD" then
			return res:send(status, "")
		end
		local f, err = io.open(path, "rb")
		if not f then
			return res:send(500, "cannot open: " .. tostring(err) .. "\n")
		end
		local ok, serr = res:start(status)
		if not ok then
			f:close()
			return nil, serr
		end
		f:seek("set", first)
		local left = len
		while left > 0 do
			local s = f:read(math.min(read_size, left))
			if not s then
				break
			end
			left = left - #s
			local wok = res:write(s)
			if not wok then
				break
			end
		end
		f:close()
		return res:finish()
	end
end

return M
