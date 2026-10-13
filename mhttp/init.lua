-- SPDX-License-Identifier: ISC

--- HTTP/1.1 for Lua 5.4. The I/O adapters load on demand.
-- @module mhttp

return {
	VERSION = "0.1.0",
	client = require("mhttp.client"),
	clock = require("mhttp.clock"),
	coro = require("mhttp.coro"),
	headers = require("mhttp.headers"),
	parse = require("mhttp.parse"),
	router = require("mhttp.router"),
	server = require("mhttp.server"),
	status = require("mhttp.status"),
	syntax = require("mhttp.syntax"),
	url = require("mhttp.url"),
	wire = require("mhttp.wire"),
}
