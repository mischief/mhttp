# mhttp design

## Layers

| module | role | state |
|---|---|---|
| `mhttp.syntax` | character rules from RFC 9110 and RFC 9112 | done |
| `mhttp.headers` | ordered field list, case-insensitive names | done |
| `mhttp.parse` | incremental parser, events, no I/O | done |
| `mhttp.wire` | serializer, no I/O | done |
| `mhttp.url` | RFC 3986 parse, resolve, percent-coding | done |
| `mhttp.clock` | monotonic clock for deadlines | done |
| `mhttp.router` | method and path templates, 405, mount, middleware | done |
| `mhttp.server` | connection loop: parse, call handler, write | done |
| `mhttp.client` | requests, keep-alive pool, redirects, http proxy | done |
| `mhttp.coro` | coroutines that pass scheduler yields through | done |
| `mhttp.io.posix` | luaposix sockets, blocking or with a wait hook | done |
| `mhttp.io.event` | the `event` loop (libevent or event_pure) | done |
| `mhttp.io.luv`, `mhttp.io.los` | luv and lua-os streams | planned |
| `mhttp.client.curl` | libcurl transport, for TLS and HTTP/2 | planned |
| `mhttp.cookie` | RFC 6265bis parse, serialize, jar | planned |
| `mhttp.proxy` | forward and reverse proxy helpers | planned |

The parser and the serializer own all framing decisions. No other
module reads Content-Length or Transfer-Encoding.

## Parser rules

- Strict CRLF. Bare CR, bare LF and NUL are errors.
- No obs-fold. No whitespace before a field colon.
- Transfer-Encoding with Content-Length is an error. Transfer-Encoding
  in HTTP/1.0 is an error. A request whose final coding is not chunked
  is an error; codings other than chunked in a request get 501.
- Content-Length values must be identical digit strings.
- A request has exactly one valid Host field (HTTP/1.1).
- Chunk data must end with CRLF. Chunk extensions are checked and
  dropped.
- Every error is final. The connection must close after it.
- Limits: start line, head size, field count, body size, chunk line,
  trailer size. Errors carry the status a server sends.

## Stream contract

The server and the client use only this:

```lua
s:read(max, deadline)   -- string | nil, "eof" | nil, "timeout" | nil, err
s:write(buf, deadline)  -- true | nil, err
s:close()
s:info()                -- optional: { peer, local, tls = {...} }
```

A deadline is an absolute `mhttp.clock` time in seconds, or nil. A
backend that must wait yields whatever its scheduler understands, with
no tag. A blocking backend never yields.

## Coroutines

`mhttp.coro` tags its own yields. Its `resume` passes every untagged
yield to the outer resumer and sends the answer back down. So any
scheduler works unchanged, and generators nest around I/O at any
depth. A plain `coroutine.wrap` around code that does I/O takes the
scheduler's yields itself; use `mhttp.coro.wrap` there.

mhttp itself uses no coroutines. Handlers run in the task that called
`server:serve`.

Cancel scopes (`scope.lua`) fit above this: a scope deadline becomes
the deadline argument, and a cancel closes the stream.

## Large bodies

Bodies stream in both directions, so memory does not grow with their
size. The server reads from the socket only when the handler reads.

- `limits.max_body` in the parser is a hard cap, unlimited by default.
- The server has a soft limit, `max_body` (16 MiB). A handler raises or
  lowers it for one request with `req:set_max_body(n)` before the first
  read. A declared length over the limit fails at the first read, before
  100 Continue is sent.
- `req:spool{max, file, path}` writes the body to a file, by default
  `io.tmpfile()`, and returns the file and its size.
- When the server answers before the body is read, and the rest is
  larger than `drain`, it sends Connection: close.
- The client has no body limit unless a request sets `max_body`. `sink`
  and `stream` read large bodies a piece at a time. When a write fails
  because the server answered early, the client still reads that answer.

## Name lookup

`connect` takes `resolve(host, port, deadline)`, which returns address
strings or `{family, addr, port}` tables. The client passes its
`resolve` option through. A literal address skips the resolver.
`mhttp.io.event` has `ares(loop)`, which uses c-ares through the event
library. Without a resolver, `mhttp.io.posix` calls getaddrinfo, which
blocks.

## TLS hooks

TLS is part of the stream, not of mhttp. A connector creates streams:

```lua
connect{ host, port, tls = {
  sni = "example.com",
  alpn = { "http/1.1" },
  ca = "/etc/ssl/certs", verify = true,
  verify_cb = function(chain, host) return ok, why end,
  cert = "client.pem", key = "client.key",   -- mutual TLS
} }
```

The server side takes `cert`, `key`, `client_auth` ("none",
"optional", "require") and the same `verify_cb`. `s:info().tls` holds
the version, cipher, ALPN result and peer chain, so a handler can read
the client certificate. The curl transport maps these to curl options.

## Proxy plan

- The parser accepts absolute-form and authority-form (CONNECT).
- `headers:strip_hop_by_hop()` removes the fixed hop-by-hop set and
  every field that Connection names.
- Field names keep their case and order, so a proxy forwards them
  unchanged.
- `parse:rest()` hands over the bytes after a CONNECT or 101, for
  tunnels.
- The client sends http:// requests through an HTTP proxy in absolute
  form.
- Planned: CONNECT tunnels for https through a proxy, and Via,
  Forwarded (RFC 7239) and X-Forwarded-For helpers.

## Cookie plan

- `headers:get` never joins Set-Cookie fields.
- `mhttp.cookie` will follow RFC 6265bis: parse Set-Cookie, serialize
  Cookie, and a jar with domain and path matching, expiry, Secure,
  HttpOnly and SameSite.

## HTTP/2

Not planned now. Handler code must not see hop-by-hop fields, raw
sockets or framing, so an `mhttp.h2` could be added later. HTTP/3 is
out of scope.

## Known gaps

- The body timeout applies to each read, not to the whole body.
- The default resolver, getaddrinfo, blocks. Pass `resolve` under a
  loop.
- Spooling writes to disk with blocking io calls.
- A streamed client response keeps its connection until it is read to
  the end or closed.
