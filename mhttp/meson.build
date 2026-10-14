shared_module('sys', 'sys.c',
              name_prefix : '',
              dependencies : [lua_dep],
              install : true,
              install_dir : cmoddir)

if libtls_dep.found()
  subdir('tls')
endif
