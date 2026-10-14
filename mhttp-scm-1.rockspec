rockspec_format = '3.0'
package = 'mhttp'
version = 'scm-1'

source = {
  url = 'git+https://github.com/mischief/mhttp.git',
  branch = 'main',
}

description = {
  summary = 'HTTP/1.1 server and client over any event loop',
  detailed = [[
mhttp is an HTTP/1.1 server and client for Lua 5.4. The parser and the
serializer do no I/O; the server and the client use a small stream
interface, so any event loop or coroutine scheduler can drive them.
Framing is strict against request smuggling and response splitting.
]],
  homepage = 'https://github.com/mischief/mhttp',
  license = 'ISC',
  labels = { 'http', 'parser', 'sans-io' },
}

supported_platforms = { 'unix' }

dependencies = {
  'lua >= 5.4',
}

-- luaposix is needed only by mhttp.io.posix, mhttp.io.event and the
-- tests.
test_dependencies = {
  'luaposix',
}

build = {
  type = 'builtin',
  modules = {
    ['mhttp'] = 'mhttp/init.lua',
    ['mhttp.client'] = 'mhttp/client.lua',
    ['mhttp.clock'] = 'mhttp/clock.lua',
    ['mhttp.coro'] = 'mhttp/coro.lua',
    ['mhttp.io.event'] = 'mhttp/io/event.lua',
    ['mhttp.io.poll'] = 'mhttp/io/poll.lua',
    ['mhttp.io.posix'] = 'mhttp/io/posix.lua',
    ['mhttp.router'] = 'mhttp/router.lua',
    ['mhttp.server'] = 'mhttp/server.lua',
    ['mhttp.url'] = 'mhttp/url.lua',
    ['mhttp.headers'] = 'mhttp/headers.lua',
    ['mhttp.parse'] = 'mhttp/parse.lua',
    ['mhttp.status'] = 'mhttp/status.lua',
    ['mhttp.syntax'] = 'mhttp/syntax.lua',
    ['mhttp.date'] = 'mhttp/date.lua',
    ['mhttp.static'] = 'mhttp/static.lua',
    ['mhttp.proxy'] = 'mhttp/proxy.lua',
    ['mhttp.cgi'] = 'mhttp/cgi.lua',
    ['mhttpx.rules'] = 'mhttpx/rules.lua',
    ['mhttpx.daemon'] = 'mhttpx/daemon.lua',
    ['mhttp.tls'] = 'mhttp/tls.lua',
    ['mhttp.tls.libtls'] = 'mhttp/tls/libtls.lua',
    ['mhttp.tls.luasec'] = 'mhttp/tls/luasec.lua',
    ['mhttp.wire'] = 'mhttp/wire.lua',
  },
  install = {
    bin = {
      mhttpx = 'bin/mhttpx',
      mhttpd = 'bin/mhttpd',
    },
  },
}

test = {
  type = 'command',
  script = 'test/run.lua',
}
