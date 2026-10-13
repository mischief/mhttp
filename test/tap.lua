-- SPDX-License-Identifier: ISC

-- A small TAP producer. The plan comes last, so a test need not count
-- its checks first.

local tap = { n = 0, failed = 0 }

local function emit(s)
	io.write(s, "\n")
	io.flush()
end

function tap.ok(cond, name)
	tap.n = tap.n + 1
	if cond then
		emit(("ok %d - %s"):format(tap.n, name))
	else
		tap.failed = tap.failed + 1
		emit(("not ok %d - %s"):format(tap.n, name))
	end
	return cond
end

function tap.is(got, want, name)
	if got ~= want then
		tap.diag(("got %s, want %s"):format(tostring(got), tostring(want)))
	end
	return tap.ok(got == want, name)
end

function tap.diag(s)
	for line in (tostring(s) .. "\n"):gmatch("([^\n]*)\n") do
		emit("# " .. line)
	end
end

function tap.skip(name, why)
	tap.n = tap.n + 1
	emit(("ok %d - %s # SKIP %s"):format(tap.n, name, why))
end

-- Runs one named check. An error in it is a failure, not a lost plan.
function tap.try(name, f, ...)
	local ok, err = pcall(f, ...)
	if ok then
		return err
	end
	tap.ok(false, name)
	tap.diag(err)
	return nil
end

function tap.done()
	emit(("1..%d"):format(tap.n))
	os.exit(tap.failed == 0 and 0 or 1, true)
end

return tap
