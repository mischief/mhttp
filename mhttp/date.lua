-- SPDX-License-Identifier: ISC

--- HTTP dates (RFC 9110 section 5.6.7).
-- @module mhttp.date

local M = {}

local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
	Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

--- Formats seconds since the epoch as an IMF-fixdate.
-- @tparam[opt] number t default now
function M.format(t)
	return os.date("!%a, %d %b %Y %H:%M:%S GMT", t and math.floor(t))
end

-- Days from 1970-01-01 to a civil date, for any year.
local function days(y, m, d)
	y = m <= 2 and y - 1 or y
	local era = (y >= 0 and y or y - 399) // 400
	local yoe = y - era * 400
	local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function epoch(y, mon, d, hh, mm, ss)
	local m = MONTHS[mon]
	y, d, hh, mm, ss = tonumber(y), tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss)
	if not m or d < 1 or d > 31 or hh > 23 or mm > 59 or ss > 60 then
		return nil
	end
	return days(y, m, d) * 86400 + hh * 3600 + mm * 60 + ss
end

--[[- Parses an HTTP date: IMF-fixdate, or the obsolete RFC 850 and
asctime forms. A two-digit RFC 850 year is taken as 19xx or 20xx,
whichever is nearer to now.
@tparam string s
@return seconds since the epoch, or nil
]]
function M.parse(s)
	if type(s) ~= "string" then
		return nil
	end
	local d, mon, y, hh, mm, ss = s:match(
		"^%a%a%a, (%d%d) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d) GMT$")
	if d then
		return epoch(y, mon, d, hh, mm, ss)
	end
	d, mon, y, hh, mm, ss = s:match(
		"^%a+, (%d%d)%-(%a%a%a)%-(%d%d) (%d%d):(%d%d):(%d%d) GMT$")
	if d then
		local now = tonumber(os.date("!%Y"))
		local yy = 2000 + tonumber(y)
		if yy > now + 50 then
			yy = yy - 100
		end
		return epoch(yy, mon, d, hh, mm, ss)
	end
	mon, d, hh, mm, ss, y = s:match(
		"^%a%a%a (%a%a%a) ([ %d]%d) (%d%d):(%d%d):(%d%d) (%d%d%d%d)$")
	if mon then
		return epoch(y, mon, d:gsub(" ", ""), hh, mm, ss)
	end
	return nil
end

return M
