/* SPDX-License-Identifier: ISC */

/*
 * System calls that luaposix lacks, for servers that start as root:
 * setgroups, chroot, and on OpenBSD pledge, unveil and setproctitle.
 * Each returns true, or nil and the error. A call the system lacks
 * returns nil and "unsupported".
 */

#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include <sys/types.h>

#include <errno.h>
#include <grp.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <lua.h>
#include <lauxlib.h>

static int
result(lua_State *L, int rv)
{
	if (rv == 0) {
		lua_pushboolean(L, 1);
		return 1;
	}
	lua_pushnil(L);
	lua_pushstring(L, strerror(errno));
	return 2;
}

#if !defined(__OpenBSD__)
static int
unsupported(lua_State *L)
{
	lua_pushnil(L);
	lua_pushliteral(L, "unsupported");
	return 2;
}
#endif

/* setgroups({gid, ...}) */
static int
l_setgroups(lua_State *L)
{
	lua_Integer i, n;
	gid_t *gids;
	int rv, saved;

	luaL_checktype(L, 1, LUA_TTABLE);
	n = luaL_len(L, 1);
	if (n < 0 || n > 65536)
		return luaL_argerror(L, 1, "too many groups");
	gids = calloc(n > 0 ? (size_t)n : 1, sizeof(*gids));
	if (gids == NULL)
		return result(L, -1);
	for (i = 0; i < n; i++) {
		lua_geti(L, 1, i + 1);
		gids[i] = (gid_t)luaL_checkinteger(L, -1);
		lua_pop(L, 1);
	}
	rv = setgroups((size_t)n, gids);
	saved = errno;
	free(gids);
	errno = saved;
	return result(L, rv);
}

static int
l_chroot(lua_State *L)
{
	return result(L, chroot(luaL_checkstring(L, 1)));
}

/* pledge(promises[, execpromises]) */
static int
l_pledge(lua_State *L)
{
#if defined(__OpenBSD__)
	return result(L, pledge(luaL_optstring(L, 1, NULL),
	    luaL_optstring(L, 2, NULL)));
#else
	return unsupported(L);
#endif
}

/* unveil(path, permissions), or unveil() to lock */
static int
l_unveil(lua_State *L)
{
#if defined(__OpenBSD__)
	return result(L, unveil(luaL_optstring(L, 1, NULL),
	    luaL_optstring(L, 2, NULL)));
#else
	return unsupported(L);
#endif
}

/* setproctitle(title): the whole title, without the program name */
static int
l_setproctitle(lua_State *L)
{
#if defined(__OpenBSD__) || defined(__FreeBSD__) || defined(__NetBSD__)
	setproctitle("-%s", luaL_checkstring(L, 1));
	lua_pushboolean(L, 1);
	return 1;
#else
	return unsupported(L);
#endif
}

static const luaL_Reg funcs[] = {
	{"setgroups", l_setgroups},
	{"chroot", l_chroot},
	{"pledge", l_pledge},
	{"unveil", l_unveil},
	{"setproctitle", l_setproctitle},
	{NULL, NULL},
};

int
luaopen_mhttp_sys(lua_State *L)
{
	luaL_newlib(L, funcs);
	return 1;
}
