-- SPDX-License-Identifier: ISC

--- A monotonic clock in seconds, for deadlines.
-- It uses clock_gettime from luaposix when present. Some luaposix
-- builds lack it, such as the OpenBSD package. Then it uses
-- gettimeofday, which moves when the system clock is set. Without
-- luaposix it uses os.time, which has a resolution of one second.
-- @module mhttp.clock

local M = {}

local ok, ptime = pcall(require, "posix.time")
local tok, ptv = pcall(require, "posix.sys.time")
if ok and ptime.clock_gettime then
	local mono = ptime.CLOCK_MONOTONIC
	function M.now()
		local t = ptime.clock_gettime(mono)
		return t.tv_sec + t.tv_nsec / 1e9
	end
elseif tok and ptv.gettimeofday then
	function M.now()
		local t = ptv.gettimeofday()
		return t.tv_sec + t.tv_usec / 1e6
	end
else
	M.now = os.time
end

--- Returns the deadline sec seconds from now, or nil when sec is nil
-- or math.huge.
function M.after(sec)
	if sec == nil or sec == math.huge then
		return nil
	end
	return M.now() + sec
end

--- Returns the earlier of two deadlines. Either can be nil.
function M.min(a, b)
	if a and b then
		return math.min(a, b)
	end
	return a or b
end

return M
