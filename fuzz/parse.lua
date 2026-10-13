-- SPDX-License-Identifier: ISC
-- An lfuzz target (see lgml fuzz/lfuzz.c): a function of one input.
-- The first byte picks the parser and the feed size. An error that
-- escapes is a bug.
local parse = require("mhttp.parse")

return function(s)
	if #s < 1 then
		return
	end
	local b = s:byte(1)
	local p = parse.new(b % 2 == 0 and "request" or "response",
		{ max_body = 1 << 20 })
	if b % 4 >= 2 then
		p:expect("HEAD")
	end
	local step = b // 4 + 1
	s = s:sub(2)
	for i = 1, #s, step do
		p:feed(s:sub(i, i + step - 1))
		repeat
			local ev, err = p:next()
			if err then
				return
			end
		until not ev
	end
	p:eof()
	repeat
		local ev = p:next()
	until not ev
end
