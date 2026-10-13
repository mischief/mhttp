-- SPDX-License-Identifier: ISC

--- A monotonic clock in seconds, for deadlines.
-- It uses luaposix when present, else os.time, which has a resolution
-- of one second and moves when the system clock is set.
-- @module mhttp.clock

local M = {}

local ok, ptime = pcall(require, "posix.time")
if ok and ptime.clock_gettime then
	local mono = ptime.CLOCK_MONOTONIC
	function M.now()
		local t = ptime.clock_gettime(mono)
		return t.tv_sec + t.tv_nsec / 1e9
	end
else
	M.now = os.time
end

--- Returns the deadline sec seconds from now, or nil when sec is nil.
function M.after(sec)
	return sec and M.now() + sec
end

--- Returns the earlier of two deadlines. Either can be nil.
function M.min(a, b)
	if a and b then
		return math.min(a, b)
	end
	return a or b
end

return M
