-- SPDX-License-Identifier: ISC

--[[- Metrics in the Prometheus text format.

A registry holds counters, gauges and histograms. Each metric has fixed
label names; each set of label values is one series. `render` gives the
text that Prometheus scrapes, and `handler` serves it. `instrument` wraps
any handler with request metrics.

    local reg = metrics.new()
    local hits = reg:counter("app_hits_total", "pages served", { "page" })
    hits:inc({ page = "/" })

@module mhttp.metrics
]]

local clock = require("mhttp.clock")

local M = {}

--- The default histogram buckets, in seconds.
M.BUCKETS = { 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 }

local CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

local function check_name(s, what)
	if type(s) ~= "string" or not s:find("^[%a_:][%w_:]*$") then
		error(("bad %s name: %s"):format(what, tostring(s)), 3)
	end
end

local function num(v)
	if v == math.huge then
		return "+Inf"
	elseif v == -math.huge then
		return "-Inf"
	elseif v ~= v then
		return "NaN"
	elseif math.type(v) == "integer" or (v == math.floor(v) and math.abs(v) < 2 ^ 53) then
		return ("%d"):format(v)
	end
	-- The shortest text that reads back as the same number.
	local t = ("%.15g"):format(v)
	if tonumber(t) ~= v then
		t = ("%.17g"):format(v)
	end
	return t
end

local function escape(s)
	return (tostring(s):gsub("[\\\"\n]", { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n" }))
end

-- The label text of one series, with extra pairs after the labels.
local function labeltext(names, values, extra)
	local parts = {}
	for i, n in ipairs(names) do
		parts[#parts + 1] = ('%s="%s"'):format(n, escape(values[i]))
	end
	for i = 1, #(extra or {}), 2 do
		parts[#parts + 1] = ('%s="%s"'):format(extra[i], escape(extra[i + 1]))
	end
	if #parts == 0 then
		return ""
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local Metric = {}
Metric.__index = Metric

-- Finds or makes the series for a label table.
function Metric:series(labels)
	local values = {}
	for i, n in ipairs(self.labels) do
		local v = labels and labels[n]
		values[i] = v == nil and "" or tostring(v)
	end
	local key = table.concat(values, "\0")
	local s = self.data[key]
	if not s then
		s = { values = values, v = 0 }
		if self.kind == "histogram" then
			s.counts, s.sum, s.count = {}, 0, 0
			for i = 1, #self.buckets do
				s.counts[i] = 0
			end
		end
		self.data[key] = s
	end
	return s
end

-- Lets inc(n) stand for inc(nil, n).
local function args(labels, n)
	if type(labels) == "number" then
		return nil, labels
	end
	return labels, n
end

--- Adds n (1) to a counter or a gauge.
function Metric:inc(labels, n)
	labels, n = args(labels, n)
	n = n or 1
	if self.kind == "counter" and n < 0 then
		error("a counter cannot go down", 2)
	end
	local s = self:series(labels)
	s.v = s.v + n
end

--- Takes n (1) from a gauge.
function Metric:dec(labels, n)
	labels, n = args(labels, n)
	local s = self:series(labels)
	s.v = s.v - (n or 1)
end

--- Sets a gauge.
function Metric:set(labels, v)
	labels, v = args(labels, v)
	self:series(labels).v = v
end

--- Adds an observation to a histogram.
function Metric:observe(labels, v)
	labels, v = args(labels, v)
	local s = self:series(labels)
	for i, b in ipairs(self.buckets) do
		if v <= b then
			s.counts[i] = s.counts[i] + 1
		end
	end
	s.sum, s.count = s.sum + v, s.count + 1
end

function Metric:render(out)
	out[#out + 1] = ("# HELP %s %s\n# TYPE %s %s\n"):format(self.name,
		self.help:gsub("\\", "\\\\"):gsub("\n", "\\n"), self.name, self.kind)
	if self.fn then
		local v = self.fn()
		if type(v) == "number" then
			out[#out + 1] = ("%s %s\n"):format(self.name, num(v))
			return
		end
		-- A list of {labels, value}.
		for _, e in ipairs(v or {}) do
			self:series(e[1]).v = e[2]
		end
	end
	local keys = {}
	for k in pairs(self.data) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local s = self.data[k]
		if self.kind == "histogram" then
			for i, b in ipairs(self.buckets) do
				out[#out + 1] = ("%s_bucket%s %s\n"):format(self.name,
					labeltext(self.labels, s.values, { "le", num(b) }), num(s.counts[i]))
			end
			out[#out + 1] = ("%s_bucket%s %s\n"):format(self.name,
				labeltext(self.labels, s.values, { "le", "+Inf" }), num(s.count))
			out[#out + 1] = ("%s_sum%s %s\n"):format(self.name, labeltext(self.labels, s.values), num(s.sum))
			out[#out + 1] = ("%s_count%s %s\n"):format(self.name, labeltext(self.labels, s.values), num(s.count))
		else
			out[#out + 1] = ("%s%s %s\n"):format(self.name, labeltext(self.labels, s.values), num(s.v))
		end
	end
	if self.fn then
		self.data = {}
	end
end

local Registry = {}
Registry.__index = Registry

--- Makes an empty registry.
function M.new()
	return setmetatable({ metrics = {}, order = {} }, Registry)
end

-- Registers a metric, or returns the one of the same name and shape.
function Registry:add(kind, name, help, labels, extra)
	check_name(name, "metric")
	labels = labels or {}
	for _, l in ipairs(labels) do
		check_name(l, "label")
	end
	local m = self.metrics[name]
	if m then
		if m.kind ~= kind or table.concat(m.labels, ",") ~= table.concat(labels, ",") then
			error(("metric %s exists with another type or labels"):format(name), 3)
		end
		return m
	end
	m = setmetatable({ kind = kind, name = name, help = help or name, labels = labels, data = {} },
		Metric)
	for k, v in pairs(extra or {}) do
		m[k] = v
	end
	self.metrics[name] = m
	self.order[#self.order + 1] = name
	return m
end

--- A counter: a number that only goes up.
-- @tparam string name such as "app_requests_total"
-- @tparam string help one line
-- @tparam[opt] {string,...} labels label names
function Registry:counter(name, help, labels)
	return self:add("counter", name, help, labels)
end

--[[- A gauge: a number that goes up and down.
@tparam string name
@tparam string help
@tparam[opt] {string,...} labels
@tparam[opt] function fn called at each render: it returns the value, or
a list of `{labels, value}`
]]
function Registry:gauge(name, help, labels, fn)
	return self:add("gauge", name, help, labels, { fn = fn })
end

--- A histogram of observations in buckets.
-- @tparam[opt] {number,...} buckets upper bounds, in order (`M.BUCKETS`)
function Registry:histogram(name, help, labels, buckets)
	return self:add("histogram", name, help, labels, { buckets = buckets or M.BUCKETS })
end

--- The metrics as Prometheus text.
function Registry:render()
	local out = {}
	for _, name in ipairs(self.order) do
		self.metrics[name]:render(out)
	end
	return table.concat(out)
end

--- A handler that serves `render`.
function Registry:handler()
	return function(_, res)
		return res:send(200, self:render(), { { "Content-Type", CONTENT_TYPE } })
	end
end

-- The status class, such as "2xx".
local function class(status)
	return status and ("%dxx"):format(status // 100) or "none"
end

--[[- Wraps a handler with request metrics.

It counts `<prefix>_requests_total` by status class, the body bytes in
`<prefix>_response_bytes_total`, requests in progress, and a histogram
of `<prefix>_request_duration_seconds`. Tunnels, such as WebSockets, are
counted but not timed.

@tparam Registry reg
@tparam function handler `handler(req, res)`
@tparam[opt] table opts `prefix` ("http"); `labels`, a table or
`fn(req)` that gives the labels; `names`, the label names
@treturn function the wrapped handler
]]
function M.instrument(reg, handler, opts)
	opts = opts or {}
	local prefix = opts.prefix or "http"
	local names = opts.names or {}
	local code = {}
	for i, n in ipairs(names) do
		code[i] = n
	end
	code[#code + 1] = "code"
	local requests = reg:counter(prefix .. "_requests_total", "requests answered", code)
	local bytes = reg:counter(prefix .. "_response_bytes_total", "response body bytes", names)
	local active = reg:gauge(prefix .. "_requests_active", "requests in progress", names)
	local duration = reg:histogram(prefix .. "_request_duration_seconds",
		"time to answer a request", names)
	local labels = opts.labels
	return function(req, res)
		local l = type(labels) == "function" and labels(req) or labels or {}
		local t0 = clock.now()
		active:inc(l)
		local r = table.pack(pcall(handler, req, res))
		active:dec(l)
		local status = res.started and res.status or (not r[1] and 500 or res.status)
		local lc = setmetatable({ code = class(status) }, { __index = l })
		requests:inc(lc)
		bytes:inc(l, res.bytes or 0)
		if status ~= 101 then
			duration:observe(l, clock.now() - t0)
		end
		if not r[1] then
			error(r[2], 0)
		end
		return table.unpack(r, 2, r.n)
	end
end

return M
