rockspec_format = '3.0'
package = 'mhttp-sys'
version = 'scm-1'

source = {
  url = 'git+https://github.com/mischief/mhttp.git',
  branch = 'main',
}

description = {
  summary = 'System calls for mhttp servers that start as root',
  detailed = [[
setgroups and chroot, and on OpenBSD pledge, unveil and setproctitle,
for mhttp servers that bind a low port as root and then drop to a user.
]],
  homepage = 'https://github.com/mischief/mhttp',
  license = 'ISC',
  labels = { 'http', 'unix', 'pledge' },
}

supported_platforms = { 'unix' }

dependencies = {
  'lua >= 5.4',
}

build = {
  type = 'builtin',
  modules = {
    ['mhttp.sys'] = 'mhttp/sys.c',
  },
}
