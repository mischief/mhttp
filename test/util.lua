-- SPDX-License-Identifier: ISC

-- Helpers shared by the tests.

local parse = require("mhttp.parse")

local M = {}

-- Feeds input in pieces of size step (all at once when nil) and
-- collects events. Returns the events and the error, if any. The end
-- states eof, closed and tunnel are not errors.
function M.run(kind, input, opts)
	opts = opts or {}
	local p = parse.new(kind, opts.limits)
	for _, m in ipairs(opts.methods or {}) do
		p:expect(m)
	end
	local evs = {}
	local step = opts.step or #input
	if step == 0 then
		step = 1
	end
	local function drain()
		while true do
			local ev, err = p:next()
			if not ev then
				if err and (err.code == "eof" or err.code == "closed" or err.code == "tunnel") then
					return nil
				end
				return err
			end
			evs[#evs + 1] = ev
		end
	end
	local i = 1
	while i <= #input do
		p:feed(input:sub(i, i + step - 1))
		i = i + step
		local err = drain()
		if err then
			return evs, err, p
		end
	end
	if opts.eof ~= false then
		p:eof()
	end
	return evs, drain(), p
end

-- A short text form of events, for comparing runs.
function M.summary(evs)
	local out = {}
	for _, ev in ipairs(evs) do
		if ev.type == "head" then
			out[#out + 1] = ("head %s %s %s"):format(
				ev.method or ev.status, ev.framing, tostring(ev.keep_alive))
		elseif ev.type == "data" then
			-- Pieces depend on how input was split; merge them.
			if out[#out] and out[#out]:sub(1, 5) == "data " then
				out[#out] = out[#out] .. ev.data
			else
				out[#out + 1] = "data " .. ev.data
			end
		elseif ev.type == "trailers" then
			out[#out + 1] = "trailers " .. ev.headers.n
		else
			out[#out + 1] = ev.type .. (ev.tunnel and " tunnel" or "")
		end
	end
	return table.concat(out, "|")
end

-- The body bytes from the data events.
function M.body(evs)
	local t = {}
	for _, ev in ipairs(evs) do
		if ev.type == "data" then
			t[#t + 1] = ev.data
		end
	end
	return table.concat(t)
end

-- The first event of a type.
function M.first(evs, ty)
	for _, ev in ipairs(evs) do
		if ev.type == ty then
			return ev
		end
	end
end

return M
