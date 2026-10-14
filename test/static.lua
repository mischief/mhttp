-- SPDX-License-Identifier: ISC
-- mhttp.static, end to end under mhttp.io.poll.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local mpoll = require("mhttp.io.poll")
local server = require("mhttp.server")
local client = require("mhttp.client")
local router = require("mhttp.router")
local static = require("mhttp.static")
local date = require("mhttp.date")
local unistd = require("posix.unistd")

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p " .. dir .. "/root/sub " .. dir .. "/root/empty " .. dir .. "/outside"))
local function put(name, data)
	local f = assert(io.open(dir .. "/" .. name, "wb"))
	f:write(data)
	f:close()
end
local big = {}
for i = 1, 1 << 14 do
	big[i] = ("%063d\n"):format(i)
end
big = table.concat(big)
put("root/hello.txt", "hello world\n")
put("root/big.bin", big)
put("root/sub/index.html", "<p>index</p>\n")
put("root/app.wasm", "\0asm")
put("root/.secret", "no")
put("root/style.css", "body{}")
put("root/style.css.gz", "GZ")
put("root/<b>.txt", "x")
put("outside/leak.txt", "leak")
assert(unistd.link(dir .. "/outside/leak.txt", dir .. "/root/link.txt", true) == 0)

local loop = mpoll.new()
local r = router.new()
r:get("/files/*path", static.handler(dir .. "/root", { list = true, gzip = true }))
r:mount("/m", router.new():get("/*path", static.handler(dir .. "/root")))
local l = assert(loop:listen("127.0.0.1", 0))
loop:serve(l, server.new({ handler = r:handler(), on_error = function(e)
	io.stderr:write(e, "\n")
end }))
local base = ("http://127.0.0.1:%d"):format(l:port())

loop:spawn(function()
	local c = client.new({ connect = function(h, p, o)
		return loop:connect(h, p, o)
	end })
	local function get(path, h, method)
		local res, err = c:request({ url = base .. path, headers = h, method = method })
		assert(res, err and err.message)
		return res
	end

	local res = get("/files/hello.txt")
	tap.is(res.status, 200, "get")
	tap.is(res.body, "hello world\n", "body")
	tap.is(res.headers:get("content-type"), "text/plain; charset=utf-8", "type")
	local tag, lm = res.headers:get("etag"), res.headers:get("last-modified")
	tap.ok(tag and lm, "etag and last-modified")

	tap.is(get("/files/hello.txt", { { "If-None-Match", tag } }).status, 304, "if-none-match")
	tap.is(get("/files/hello.txt", { { "If-None-Match", "W/" .. tag } }).status, 304,
		"if-none-match, weak")
	tap.is(get("/files/hello.txt", { { "If-Modified-Since", lm } }).status, 304, "if-modified-since")
	tap.is(get("/files/hello.txt", { { "If-Modified-Since", date.format(0) } }).status, 200,
		"if-modified-since, older")
	tap.is(get("/files/hello.txt", { { "If-Match", '"other"' } }).status, 412, "if-match fails")
	tap.is(get("/files/hello.txt", { { "If-Match", tag } }).status, 200, "if-match passes")

	res = get("/files/big.bin", { { "Range", "bytes=64-127" } })
	tap.is(res.status, 206, "range")
	tap.is(res.body, big:sub(65, 128), "range body")
	tap.is(res.headers:get("content-range"), "bytes 64-127/" .. #big, "content-range")
	res = get("/files/big.bin", { { "Range", "bytes=-10" } })
	tap.is(res.body, big:sub(-10), "suffix range")
	res = get("/files/big.bin", { { "Range", "bytes=" .. #big .. "-" } })
	tap.is(res.status, 416, "range past the end")
	tap.is(res.headers:get("content-range"), "bytes */" .. #big, "416 content-range")
	res = get("/files/big.bin", { { "Range", "bytes=0-0" }, { "If-Range", '"stale"' } })
	tap.is(res.status, 200, "if-range with another tag gives the whole file")
	res = get("/files/big.bin", { { "Range", "bytes=0-1,5-6" } })
	tap.is(res.status, 200, "several ranges give the whole file")
	tap.is(res.body, big, "1 MiB body")

	res = get("/files/big.bin", nil, "HEAD")
	tap.is(res.headers:get("content-length"), tostring(#big), "head length")
	tap.is(res.body, "", "head body")

	res = get("/files/sub")
	tap.is(res.status, 301, "directory without slash")
	tap.is(res.headers:get("location"), "sub/", "redirect target is relative")
	tap.is(get("/files/sub/").body, "<p>index</p>\n", "index file")
	res = get("/files/")
	tap.ok(res.body:find("&lt;b&gt;.txt", 1, true) and not res.body:find("<b>", 1, true),
		"listing escapes names")
	tap.ok(not res.body:find("secret", 1, true), "listing hides dot files")
	tap.is(get("/files/app.wasm").headers:get("content-type"), "application/wasm", "wasm type")

	tap.is(get("/files/.secret").status, 404, "dot file")
	tap.is(get("/files/%2e%2e/outside/leak.txt").status, 400, "encoded dot segment")
	tap.is(get("/files/link.txt").status, 404, "link out of root")
	tap.is(get("/files/nosuch").status, 404, "missing")
	tap.is(get("/files/hello.txt%00").status, 400, "nul byte")

	res = get("/files/style.css", { { "Accept-Encoding", "gzip, br" } })
	tap.is(res.headers:get("content-encoding"), "gzip", "precompressed")
	tap.is(res.body, "GZ", "precompressed body")
	tap.is(get("/files/style.css").body, "body{}", "plain without accept-encoding")

	tap.is(get("/files/hello.txt", nil, "POST").status, 405, "post")

	tap.is(get("/m/sub/").body, "<p>index</p>\n", "index under a mount")
	tap.is(get("/m/empty/").status, 404, "no listing unless asked")
	tap.is(get("/m/hello.txt").body, "hello world\n", "mounted file")
	c:close()
	l:close()
end)
loop:run()
os.execute("rm -rf " .. dir)
tap.done()
