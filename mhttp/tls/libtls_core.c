/* SPDX-License-Identifier: ISC */

/*
 * libtls for mhttp.tls.libtls. Every call is non-blocking: it returns
 * nil and "wantread" or "wantwrite" when the fd is not ready, and the
 * Lua side waits on the fd.
 */

#include <errno.h>
#include <string.h>
#include <unistd.h>

#include <tls.h>

#include <lua.h>
#include <lauxlib.h>

#define CONFIG "mhttp.tls.config"
#define CTX "mhttp.tls.ctx"

struct ctx {
	struct tls *tls;
	int fd;		/* -1 when this ctx does not own an fd */
};

static int
fail(lua_State *L, const char *msg)
{
	lua_pushnil(L);
	lua_pushstring(L, msg ? msg : "unknown error");
	return 2;
}

/* Turns a libtls return value into Lua results. */
static int
want(lua_State *L, struct ctx *c, ssize_t rv)
{
	if (rv == TLS_WANT_POLLIN)
		return fail(L, "wantread");
	if (rv == TLS_WANT_POLLOUT)
		return fail(L, "wantwrite");
	return fail(L, tls_error(c->tls));
}

static const char *
optstring(lua_State *L, int idx, const char *key)
{
	const char *s = NULL;

	lua_getfield(L, idx, key);
	if (!lua_isnil(L, -1))
		s = luaL_checkstring(L, -1);
	lua_pop(L, 1);
	return s;
}

static int
optbool(lua_State *L, int idx, const char *key, int def)
{
	int b;

	lua_getfield(L, idx, key);
	b = lua_isnil(L, -1) ? def : lua_toboolean(L, -1);
	lua_pop(L, 1);
	return b;
}

/*
 * config{ca, ca_dir, cert, key, alpn, verify, verify_name, client_auth}
 * returns a config, or nil and the reason.
 */
static int
l_config(lua_State *L)
{
	struct tls_config **u;
	struct tls_config *cfg;
	const char *s, *cert, *key;

	luaL_checktype(L, 1, LUA_TTABLE);
	u = lua_newuserdatauv(L, sizeof(*u), 0);
	*u = NULL;
	luaL_setmetatable(L, CONFIG);
	if ((cfg = tls_config_new()) == NULL)
		return fail(L, "tls_config_new failed");
	*u = cfg;

	if (tls_config_set_protocols(cfg, TLS_PROTOCOLS_DEFAULT) == -1)
		return fail(L, tls_config_error(cfg));
	if ((s = optstring(L, 1, "ca")) && tls_config_set_ca_file(cfg, s) == -1)
		return fail(L, tls_config_error(cfg));
	if ((s = optstring(L, 1, "ca_dir")) && tls_config_set_ca_path(cfg, s) == -1)
		return fail(L, tls_config_error(cfg));
	cert = optstring(L, 1, "cert");
	key = optstring(L, 1, "key");
	if (cert && tls_config_set_cert_file(cfg, cert) == -1)
		return fail(L, tls_config_error(cfg));
	if (key && tls_config_set_key_file(cfg, key) == -1)
		return fail(L, tls_config_error(cfg));
	if ((s = optstring(L, 1, "alpn")) && tls_config_set_alpn(cfg, s) == -1)
		return fail(L, tls_config_error(cfg));
	if (!optbool(L, 1, "verify", 1)) {
		tls_config_insecure_noverifycert(cfg);
		tls_config_insecure_noverifyname(cfg);
	} else if (!optbool(L, 1, "verify_name", 1)) {
		tls_config_insecure_noverifyname(cfg);
	}
	s = optstring(L, 1, "client_auth");
	if (s && strcmp(s, "require") == 0)
		tls_config_verify_client(cfg);
	else if (s && strcmp(s, "optional") == 0)
		tls_config_verify_client_optional(cfg);
	else if (s && strcmp(s, "none") != 0)
		return fail(L, "client_auth must be none, optional or require");
	return 1;
}

static int
config_gc(lua_State *L)
{
	struct tls_config **u = luaL_checkudata(L, 1, CONFIG);

	if (*u) {
		tls_config_free(*u);
		*u = NULL;
	}
	return 0;
}

/* Makes a ctx userdata. Its user value keeps the config or server alive. */
static struct ctx *
newctx(lua_State *L, int keep)
{
	struct ctx *c = lua_newuserdatauv(L, sizeof(*c), 1);

	c->tls = NULL;
	c->fd = -1;
	luaL_setmetatable(L, CTX);
	lua_pushvalue(L, keep);
	lua_setiuservalue(L, -2, 1);
	return c;
}

static struct ctx *
checkctx(lua_State *L)
{
	struct ctx *c = luaL_checkudata(L, 1, CTX);

	if (c->tls == NULL)
		luaL_error(L, "TLS context is closed");
	return c;
}

static int
setup(lua_State *L, struct ctx *c, struct tls *t)
{
	struct tls_config **cfg = luaL_checkudata(L, 1, CONFIG);

	if (t == NULL)
		return fail(L, "cannot make a TLS context");
	c->tls = t;
	if (tls_configure(t, *cfg) == -1)
		return fail(L, tls_error(t));
	return 1;
}

/* client(config) and server(config) */
static int
l_client(lua_State *L)
{
	struct ctx *c = newctx(L, 1);

	return setup(L, c, tls_client());
}

static int
l_server(lua_State *L)
{
	struct ctx *c = newctx(L, 1);

	return setup(L, c, tls_server());
}

/* client:connect(fd, servername): the ctx owns fd from now on. */
static int
ctx_connect(lua_State *L)
{
	struct ctx *c = checkctx(L);
	int fd = (int)luaL_checkinteger(L, 2);
	const char *name = luaL_optstring(L, 3, NULL);

	if (tls_connect_socket(c->tls, fd, name) == -1)
		return fail(L, tls_error(c->tls));
	c->fd = fd;
	lua_settop(L, 1);
	return 1;
}

/* server:accept(fd) returns a connection that owns fd. */
static int
ctx_accept(lua_State *L)
{
	struct ctx *s = checkctx(L);
	int fd = (int)luaL_checkinteger(L, 2);
	struct ctx *c = newctx(L, 1);

	if (tls_accept_socket(s->tls, &c->tls, fd) == -1)
		return fail(L, tls_error(s->tls));
	c->fd = fd;
	return 1;
}

static int
ctx_handshake(lua_State *L)
{
	struct ctx *c = checkctx(L);
	int rv = tls_handshake(c->tls);

	if (rv == 0) {
		lua_pushboolean(L, 1);
		return 1;
	}
	return want(L, c, rv);
}

static int
ctx_read(lua_State *L)
{
	struct ctx *c = checkctx(L);
	lua_Integer max = luaL_optinteger(L, 2, 65536);
	luaL_Buffer b;
	ssize_t n;
	char *p;

	if (max <= 0)
		max = 65536;
	p = luaL_buffinitsize(L, &b, (size_t)max);
	n = tls_read(c->tls, p, (size_t)max);
	if (n > 0) {
		luaL_pushresultsize(&b, (size_t)n);
		return 1;
	}
	if (n == 0)
		return fail(L, "eof");
	return want(L, c, n);
}

static int
ctx_write(lua_State *L)
{
	struct ctx *c = checkctx(L);
	size_t len;
	const char *s = luaL_checklstring(L, 2, &len);
	ssize_t n = tls_write(c->tls, s, len);

	if (n >= 0) {
		lua_pushinteger(L, n);
		return 1;
	}
	return want(L, c, n);
}

/*
 * Sends close_notify once without waiting, then frees the context and
 * closes the fd. A second close does nothing.
 */
static int
ctx_close(lua_State *L)
{
	struct ctx *c = luaL_checkudata(L, 1, CTX);

	if (c->tls) {
		if (c->fd != -1)
			(void)tls_close(c->tls);
		tls_free(c->tls);
		c->tls = NULL;
	}
	if (c->fd != -1) {
		close(c->fd);
		c->fd = -1;
	}
	return 0;
}

static void
setstr(lua_State *L, const char *key, const char *val)
{
	if (val) {
		lua_pushstring(L, val);
		lua_setfield(L, -2, key);
	}
}

/* Returns version, cipher, alpn, sni and peer, after the handshake. */
static int
ctx_info(lua_State *L)
{
	struct ctx *c = checkctx(L);
	const uint8_t *pem;
	size_t len;

	lua_newtable(L);
	setstr(L, "version", tls_conn_version(c->tls));
	setstr(L, "cipher", tls_conn_cipher(c->tls));
	setstr(L, "alpn", tls_conn_alpn_selected(c->tls));
	setstr(L, "sni", tls_conn_servername(c->tls));
	if (tls_peer_cert_provided(c->tls)) {
		lua_newtable(L);
		setstr(L, "subject", tls_peer_cert_subject(c->tls));
		setstr(L, "issuer", tls_peer_cert_issuer(c->tls));
		setstr(L, "hash", tls_peer_cert_hash(c->tls));
		lua_pushinteger(L, (lua_Integer)tls_peer_cert_notbefore(c->tls));
		lua_setfield(L, -2, "not_before");
		lua_pushinteger(L, (lua_Integer)tls_peer_cert_notafter(c->tls));
		lua_setfield(L, -2, "not_after");
		if ((pem = tls_peer_cert_chain_pem(c->tls, &len)) != NULL) {
			lua_pushlstring(L, (const char *)pem, len);
			lua_setfield(L, -2, "pem");
		}
		lua_setfield(L, -2, "peer");
	}
	return 1;
}

/* Tells whether the peer certificate is valid for name. */
static int
ctx_contains_name(lua_State *L)
{
	struct ctx *c = checkctx(L);

	lua_pushboolean(L, tls_peer_cert_contains_name(c->tls,
	    luaL_checkstring(L, 2)) == 1);
	return 1;
}

static const luaL_Reg ctx_methods[] = {
	{"connect", ctx_connect},
	{"accept", ctx_accept},
	{"handshake", ctx_handshake},
	{"read", ctx_read},
	{"write", ctx_write},
	{"close", ctx_close},
	{"info", ctx_info},
	{"contains_name", ctx_contains_name},
	{NULL, NULL},
};

static const luaL_Reg funcs[] = {
	{"config", l_config},
	{"client", l_client},
	{"server", l_server},
	{NULL, NULL},
};

int
luaopen_mhttp_tls_libtls_core(lua_State *L)
{
	if (tls_init() == -1)
		return luaL_error(L, "tls_init failed");

	luaL_newmetatable(L, CONFIG);
	lua_pushcfunction(L, config_gc);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);

	luaL_newmetatable(L, CTX);
	luaL_newlib(L, ctx_methods);
	lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, ctx_close);
	lua_setfield(L, -2, "__gc");
	lua_pushcfunction(L, ctx_close);
	lua_setfield(L, -2, "__close");
	lua_pop(L, 1);

	luaL_newlib(L, funcs);
	return 1;
}
