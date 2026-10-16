-- SPDX-License-Identifier: ISC
-- The rockspec lists every Lua module in the tree, and each path exists.
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")

local spec = {}
assert(load(assert(io.open("mhttp-scm-1.rockspec")):read("a"), "rockspec", "t", spec))()

local listed = {}
for name, src in pairs(spec.build.modules) do
	local path = type(src) == "table" and src.sources[1] or src
	listed[path] = name
	local f = io.open(path)
	tap.ok(f, name .. ": " .. path .. " exists")
	if f then
		f:close()
	end
end

local p = assert(io.popen("find mhttp mhttpx -name '*.lua'"))
for path in p:lines() do
	local want = path:gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
	tap.is(listed[path], want, path .. " is in the rockspec")
end
p:close()
tap.done()
