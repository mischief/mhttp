-- SPDX-License-Identifier: ISC
-- Runs every test with the interpreter that runs this script.
local lua = arg[-1] or "lua"
local failed = 0
for _, t in ipairs({ "request", "response", "smuggle", "wire", "split", "coro", "url", "router", "http",
	"event", "poll" }) do
	local ok = os.execute(("%s test/%s.lua"):format(lua, t))
	if not ok then
		failed = failed + 1
		io.stderr:write("FAIL ", t, "\n")
	end
end
os.exit(failed == 0 and 0 or 1)
