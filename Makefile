# Builds the C modules for luarocks. meson.build does the same for a
# meson build. The libtls backend is built only where libtls links.

CC ?= cc
CFLAGS ?= -O2 -fPIC
LIBFLAG ?= -shared
LUA_INCDIR ?= /usr/local/include
TLS_INCDIR ?= /usr/include
TLS_LIBDIR ?= /usr/lib
LUADIR ?= /usr/local/share/lua/5.4
LIBDIR ?= /usr/local/lib/lua/5.4

all: mhttp/sys.so tls

mhttp/sys.so: mhttp/sys.c
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) $(LIBFLAG) -o mhttp/sys.so mhttp/sys.c

tls:
	@printf '#include <tls.h>\nint main(void) { return tls_init(); }\n' > tlsprobe.c
	@if $(CC) -I$(TLS_INCDIR) tlsprobe.c -o tlsprobe -L$(TLS_LIBDIR) -ltls >/dev/null 2>&1; then \
		echo "libtls found: building mhttp.tls.libtls_core"; \
		echo "$(CC) $(CFLAGS) -I$(LUA_INCDIR) -I$(TLS_INCDIR) $(LIBFLAG) -o mhttp/tls/libtls_core.so mhttp/tls/libtls_core.c -L$(TLS_LIBDIR) -ltls"; \
		$(CC) $(CFLAGS) -I$(LUA_INCDIR) -I$(TLS_INCDIR) $(LIBFLAG) -o mhttp/tls/libtls_core.so \
			mhttp/tls/libtls_core.c -L$(TLS_LIBDIR) -ltls || exit 1; \
	else \
		echo "libtls not found: mhttp will have no TLS"; \
	fi
	@rm -f tlsprobe tlsprobe.c

install:
	for f in `find mhttp mhttpx -name '*.lua'`; do \
		mkdir -p $(LUADIR)/`dirname $$f` && cp $$f $(LUADIR)/`dirname $$f`/ || exit 1; \
	done
	mkdir -p $(LIBDIR)/mhttp/tls
	cp mhttp/sys.so $(LIBDIR)/mhttp/
	if [ -f mhttp/tls/libtls_core.so ]; then cp mhttp/tls/libtls_core.so $(LIBDIR)/mhttp/tls/; fi

clean:
	rm -f mhttp/sys.so mhttp/tls/libtls_core.so tlsprobe tlsprobe.c

.PHONY: all tls install clean
