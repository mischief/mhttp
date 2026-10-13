-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;./test/?.lua;" .. package.path

local tap = require("tap")
local url = require("mhttp.url")

local u = url.parse("HTTP://user:pw@Example.COM:8080/a/b?x=1#frag")
tap.is(u.scheme, "http", "parse: scheme lower case")
tap.is(u.userinfo, "user:pw", "parse: userinfo")
tap.is(u.host, "example.com", "parse: host lower case")
tap.is(u.port, 8080, "parse: port")
tap.is(u.path, "/a/b", "parse: path")
tap.is(u.query, "x=1", "parse: query")
tap.is(u.fragment, "frag", "parse: fragment")
tap.is(url.authority(u), "example.com:8080", "authority: port kept")
tap.is(url.target(u), "/a/b?x=1", "target")

u = url.parse("http://[::1]/")
tap.is(u.host, "::1", "ipv6: brackets removed")
tap.is(url.authority(u), "[::1]", "ipv6: brackets in authority, default port left out")
tap.is(url.authority(u, true), "[::1]:80", "ipv6: port when asked")
tap.is(url.target(url.parse("http://h")), "/", "empty path is /")

for _, bad in ipairs({ "http://h:99999/", "http://h:x/", "http://h/ a", "http://h/\n" }) do
	tap.ok(url.parse(bad) == nil, "parse refuses " .. bad:gsub("%c", "?"))
end

-- RFC 3986 section 5.4.1.
local base = "http://a/b/c/d;p?q"
local cases = {
	{ "g:h", "g:h" }, { "g", "http://a/b/c/g" }, { "./g", "http://a/b/c/g" },
	{ "g/", "http://a/b/c/g/" }, { "/g", "http://a/g" }, { "//g", "http://g" },
	{ "?y", "http://a/b/c/d;p?y" }, { "g?y", "http://a/b/c/g?y" },
	{ "#s", "http://a/b/c/d;p?q#s" }, { "g#s", "http://a/b/c/g#s" },
	{ ";x", "http://a/b/c/;x" }, { "", "http://a/b/c/d;p?q" },
	{ ".", "http://a/b/c/" }, { "./", "http://a/b/c/" }, { "..", "http://a/b/" },
	{ "../", "http://a/b/" }, { "../g", "http://a/b/g" }, { "../..", "http://a/" },
	{ "../../", "http://a/" }, { "../../g", "http://a/g" },
	{ "../../../g", "http://a/g" }, { "/./g", "http://a/g" }, { "/../g", "http://a/g" },
	{ "g.", "http://a/b/c/g." }, { ".g", "http://a/b/c/.g" },
	{ "./../g", "http://a/b/g" }, { "./g/.", "http://a/b/c/g/" },
	{ "g/./h", "http://a/b/c/g/h" }, { "g/../h", "http://a/b/c/h" },
}
for _, c in ipairs(cases) do
	tap.is(url.format(url.resolve(base, c[1])), c[2], "resolve " .. ("%q"):format(c[1]))
end

tap.is(url.decode("a%20b+c", true), "a b c", "decode with plus")
tap.is(url.decode("a%2"), nil, "decode refuses a short escape")
tap.is(url.decode("a%zz"), nil, "decode refuses a bad escape")
tap.is(url.encode("a b/c~"), "a%20b%2Fc~", "encode")
tap.is(url.encode("a b/c", "/"), "a%20b/c", "encode keeps safe bytes")
local q = url.query("a=1&b=x+y&a=2&c")
tap.is(q.a, "1", "query: first value")
tap.is(q.b, "x y", "query: decoded")
tap.is(q.c, "", "query: no value")
tap.is(#q, 4, "query: list of pairs")

tap.done()
