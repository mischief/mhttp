# Pure Lua, plus the optional C core of the libtls backend.
project('mhttp', 'c', version : '0.1.0', meson_version : '>= 0.64.0',
        license : 'ISC', default_options : ['c_std=c11', 'warning_level=2'])

lua_version = get_option('lua_version')
lua = find_program('lua' + lua_version, 'lua', required : true)
luadir = get_option('datadir') / 'lua' / lua_version

install_subdir('mhttp', install_dir : luadir, exclude_files : ['tls/libtls_core.c'])

# The libtls core lands in build/mhttp/tls, so the build directory works
# as a cpath root for the tests.
lua_dep = dependency('lua' + lua_version, 'lua-' + lua_version, 'lua', required : false)
libtls_dep = dependency('libtls', required : get_option('libtls'))
if lua_dep.found() and libtls_dep.found()
  subdir('mhttp/tls')
endif

src = meson.current_source_dir()

foreach t : ['request', 'response', 'smuggle', 'wire', 'split', 'coro', 'url', 'router',
            'http', 'event', 'poll', 'tls']
  test(t, lua, args : [files('test' / t + '.lua')],
       protocol : 'tap', workdir : src, timeout : 120,
       env : ['MHTTP_CPATH=' + meson.project_build_root()])
endforeach

# meson test --benchmark -v
benchmark('parse', lua, args : [files('bench/parse.lua')],
          workdir : src, timeout : 300)
foreach m : ['fork', 'event', 'poll']
  foreach c : ['1', '4', '16']
    benchmark('rps-' + m + '-' + c, lua,
              args : [files('bench/rps.lua'), m, c, get_option('bench_seconds')],
              workdir : src, timeout : 300)
  endforeach
endforeach
foreach w : ['4', '8']
  benchmark('rps-reuseport-' + w, lua,
            args : [files('bench/rps.lua'), 'reuseport', '16',
                    get_option('bench_seconds'), '13', w],
            workdir : src, timeout : 300)
endforeach
