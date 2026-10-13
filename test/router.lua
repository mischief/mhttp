-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local router = require("mhttp.router")

-- A response that records what was sent.
local function fake(method, path)
	local req = { method = method, path = path, form = "origin" }
	local res = {}
	function res:send(status, body, h)
		self.status, self.body, self.h = status, body, h
	end
	return req, res
end

local function run(r, method, path)
	local req, res = fake(method, path)
	r:handle(req, res)
	return res, req
end

local r = router.new()
local seen
r:get("/", function(_, res) res:send(200, "home") end)
r:get("/paste/new", function(_, res) res:send(200, "new") end)
r:get("/paste/{id}", function(req, res) res:send(200, "id " .. req.params.id) end)
r:get("/paste/{id:%d+}", function(req, res) res:send(200, "num " .. req.params.id) end)
r:post("/paste", function(_, res) res:send(201, "made") end)
r:route({ "PUT", "DELETE" }, "/paste/{id}", function(req, res) res:send(200, req.method) end)
r:get("/static/*path", function(req, res) res:send(200, "file " .. req.params.path) end)

local api = router.new()
api:get("/v1/{x}", function(req, res)
	seen = req.base
	res:send(200, "api " .. req.params.x)
end)
r:mount("/api", api)

local cases = {
	{ "GET", "/", 200, "home" },
	{ "GET", "/paste/new", 200, "new", "literal beats a parameter" },
	{ "GET", "/paste/42", 200, "num 42", "constrained beats plain" },
	{ "GET", "/paste/abc", 200, "id abc" },
	{ "GET", "/paste/a%20b", 200, "id a b", "parameters are decoded" },
	{ "GET", "/paste/a%2Fb", 200, "id a/b", "an encoded slash stays in one segment" },
	{ "GET", "/paste/", 404, nil, "an empty segment is no parameter" },
	{ "GET", "/paste/1/2", 404 },
	{ "HEAD", "/paste/abc", 200, "id abc", "HEAD uses GET" },
	{ "DELETE", "/paste/abc", 200, "DELETE" },
	{ "POST", "/paste/abc", 405, nil, "wrong method" },
	{ "GET", "/static/css/a.css", 200, "file css/a.css" },
	{ "GET", "/static/", 200, "file ", "rest may be empty" },
	{ "GET", "/static/../etc/passwd", 400, nil, "dot segments" },
	{ "GET", "/static/%2e%2e/etc/passwd", 400, nil, "encoded dot segments" },
	{ "GET", "/api/v1/z", 200, "api z", "mount" },
	{ "GET", "/nope", 404 },
	{ "GET", "/paste/%zz", 404, nil, "a bad escape matches no parameter" },
}
for _, c in ipairs(cases) do
	local res = run(r, c[1], c[2])
	local name = ("%s %s%s"):format(c[1], c[2], c[5] and (": " .. c[5]) or "")
	tap.ok(res.status == c[3] and (c[4] == nil or res.body == c[4]), name)
	if res.status ~= c[3] then
		tap.diag(("got %s %s"):format(res.status, res.body))
	end
end
tap.is(seen, "/api", "mount sets req.base")

local res = run(r, "POST", "/paste/abc")
tap.is(res.h and res.h[1][2], "DELETE, GET, HEAD, PUT", "405 lists Allow")
res = run(r, "OPTIONS", "/paste/abc")
tap.ok(res.status == 204 and res.h[1][2]:find("OPTIONS"), "OPTIONS gives Allow")

local order = {}
local m = router.new()
m:use(function(_, _, nxt)
	order[#order + 1] = "a"
	return nxt()
end)
m:use(function(req, res, nxt)
	order[#order + 1] = "b"
	if req.path == "/deny" then
		return res:send(403, "no")
	end
	return nxt()
end)
m:get("/x", function(_, res)
	order[#order + 1] = "x"
	res:send(200, "x")
end)
m:get("/deny", function(_, res) res:send(200, "should not run") end)
run(m, "GET", "/x")
tap.is(table.concat(order), "abx", "middleware runs in order")
res = run(m, "GET", "/deny")
tap.is(res.status, 403, "middleware can answer")

res = select(1, run(r, "GET", nil))
tap.is(res.status, 400, "no path: 400")
local req, res2 = fake("GET", nil)
req.form, req.target = "absolute", "http://h/paste/7"
r:handle(req, res2)
tap.is(res2.body, "num 7", "absolute form uses its path")

tap.ok(not pcall(router.new().get, router.new(), "/a/*r/b", print), "rest must be last")
tap.ok(not pcall(router.new().get, router.new(), "nope", print), "template starts with /")

tap.done()
