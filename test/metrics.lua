-- SPDX-License-Identifier: ISC
-- mhttp.metrics: the registry, the text format, and instrument under a
-- real server.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local metrics = require("mhttp.metrics")
local mpoll = require("mhttp.io.poll")
local server = require("mhttp.server")
local client = require("mhttp.client")

local reg = metrics.new()
local c = reg:counter("app_hits_total", "pages served", { "page" })
c:inc({ page = "/" })
c:inc({ page = "/" }, 2)
c:inc({ page = 'a"b\\c\nd' })
local g = reg:gauge("app_queue", "jobs waiting")
g:set(5)
g:dec(2)
g:inc()
reg:gauge("app_temp", "made at render", { "room" }, function()
	return { { { room = "x" }, 1.5 }, { { room = "y" }, -2 } }
end)
reg:gauge("app_up", "one number", nil, function()
	return 1
end)
local h = reg:histogram("app_seconds", "time taken", nil, { 0.1, 1 })
h:observe(0.05)
h:observe(0.5)
h:observe(3)

tap.is(reg:counter("app_hits_total", "again", { "page" }), c, "the same name gives the same metric")
tap.ok(not pcall(reg.gauge, reg, "app_hits_total", "x", { "page" }), "another type is an error")
tap.ok(not pcall(reg.counter, reg, "bad-name", "x"), "a bad name is an error")
tap.ok(not pcall(c.inc, c, { page = "/" }, -1), "a counter cannot go down")

local want = [[
# HELP app_hits_total pages served
# TYPE app_hits_total counter
app_hits_total{page="/"} 3
app_hits_total{page="a\"b\\c\nd"} 1
# HELP app_queue jobs waiting
# TYPE app_queue gauge
app_queue 4
# HELP app_temp made at render
# TYPE app_temp gauge
app_temp{room="x"} 1.5
app_temp{room="y"} -2
# HELP app_up one number
# TYPE app_up gauge
app_up 1
# HELP app_seconds time taken
# TYPE app_seconds histogram
app_seconds_bucket{le="0.1"} 1
app_seconds_bucket{le="1"} 2
app_seconds_bucket{le="+Inf"} 3
app_seconds_sum 3.55
app_seconds_count 3
]]
tap.is(reg:render(), want, "text format")

-- instrument, and the handler, under a real server.
local r2 = metrics.new()
local loop = mpoll.new()
local app = metrics.instrument(r2, function(req, res)
	if req.path == "/boom" then
		error("boom")
	end
	return res:send(req.path == "/missing" and 404 or 200, "hello")
end, { prefix = "t", names = { "site" }, labels = { site = "a" } })
local srv = server.new({ handler = function(req, res)
	if req.path == "/metrics" then
		return r2:handler()(req, res)
	end
	return app(req, res)
end, on_error = function() end })
local l = assert(loop:listen("127.0.0.1", 0))
loop:serve(l, srv)
local text, ctype
loop:spawn(function()
	local cl = client.new({ connect = function(hh, p, o)
		return loop:connect(hh, p, o)
	end, timeout = 5 })
	local base = ("http://127.0.0.1:%d"):format(l:port())
	cl:get(base .. "/")
	cl:get(base .. "/")
	cl:get(base .. "/missing")
	cl:get(base .. "/boom")
	local res = cl:get(base .. "/metrics")
	text, ctype = res and res.body, res and res.headers:get("content-type")
	cl:close()
	l:close()
end)
loop:run()
tap.is(ctype, "text/plain; version=0.0.4; charset=utf-8", "content type")
tap.ok(text:find('t_requests_total{site="a",code="2xx"} 2', 1, true), "2xx counted")
tap.ok(text:find('t_requests_total{site="a",code="4xx"} 1', 1, true), "4xx counted")
tap.ok(text:find('t_requests_total{site="a",code="5xx"} 1', 1, true), "an error counts as 5xx")
tap.ok(text:find('t_response_bytes_total{site="a"} 15', 1, true), "body bytes")
tap.ok(text:find('t_request_duration_seconds_count{site="a"} 4', 1, true), "durations")
tap.ok(text:find('t_requests_active{site="a"} 0', 1, true), "nothing in progress")
tap.done()
