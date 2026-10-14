rockspec_format = '3.0'
package = 'mhttp-libtls'
version = 'scm-1'

source = {
  url = 'git+https://github.com/mischief/mhttp.git',
  branch = 'main',
}

description = {
  summary = 'libtls backend for mhttp.tls',
  detailed = [[
The C core of the mhttp.tls.libtls backend. libtls is in OpenBSD base;
on Linux it comes from libretls (Debian: libtls-dev, Gentoo:
dev-libs/libretls).
]],
  homepage = 'https://github.com/mischief/mhttp',
  license = 'ISC',
  labels = { 'http', 'tls', 'libtls' },
}

supported_platforms = { 'unix' }

dependencies = {
  'lua >= 5.4',
  'mhttp',
}

external_dependencies = {
  LIBTLS = { header = 'tls.h', library = 'tls' },
}

build = {
  type = 'builtin',
  modules = {
    ['mhttp.tls.libtls_core'] = {
      sources = { 'mhttp/tls/libtls_core.c' },
      libraries = { 'tls' },
      incdirs = { '$(LIBTLS_INCDIR)' },
      libdirs = { '$(LIBTLS_LIBDIR)' },
    },
  },
}
