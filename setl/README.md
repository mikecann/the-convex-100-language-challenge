# SETL

This language client is planned as roster entry 45.

No client library exists yet and no capabilities have been earned. What
exists so far is the from-source interpreter build this client depends on,
with its native TLS boundary proven against a real host from inside Docker.

- Selection tier: `ranked`
- Implementation status: `planned`
- Earned capabilities: none

## Build recipe (proven)

`Dockerfile`'s `test` stage builds GNU SETL 8.13.22 from source
(`https://setl.org/setl/setl-8.13.22.tgz`, pinned by sha256) entirely inside
Docker, with `src/run/callskel.c` replaced by `client/callskel.c` before the
interpreter is compiled, then relinked against `-lssl -lcrypto`. Two things
had to be worked out and are now captured directly in the Dockerfile's
comments:

- GNU SETL's own top-level `make` interactively prompts for a build
  directory and configure options on a clean checkout. The unattended path
  is to pre-seed `config.parms` (the file that prompt would otherwise
  write) with the desired `configure` arguments and touch its witness
  timestamp file, so `make` treats configuration as already done.
- `setl` resolves its `setltran` (compiler) and `setlcpp` (preprocessor)
  helpers relative to its own install location, not via `PATH`; without
  `make install`, the build stages symlinks next to the built `setl`
  binary instead.

`client/tests/tls_smoke.setl`, run as part of the same `test` stage, proves
the point end to end: it calls the replaced `callskel.c` dispatcher through
SETL's `callout()` builtin to open a real TLS connection to a well-known
public host, writes a plain HTTP/1.1 request, reads back a real response,
and checks it starts with `HTTP/`.

## The `callout()` boundary

SETL2's `callout` (kept in GNU SETL for SETL2 compatibility) is not a
general FFI. It is a single fixed-signature C dispatcher:

```c
char *setl2_callout(int service, unsigned argc, char *const argv[]);
```

invoked from SETL source as `callout(service, om, arglist)`, where
`arglist` is a tuple of strings. Every argument and the single return value
are C strings, so this is the only native extension point GNU SETL exposes,
and every raw byte that crosses it -- both directions of TLS traffic --
must be encoded as a string. `client/callskel.c` uses GNU SETL's own
built-in `hex`/`unhex` operators for that encoding (not a hand-rolled
scheme), so the SETL-side wrapper never needs anything beyond what the
standard library already provides. See the block comment at the top of
`client/callskel.c` for the service codes (`PING`, `TLS_CONNECT`,
`TLS_WRITE`, `TLS_READ`, `TLS_CLOSE`) and exactly what each returns.

Plain HTTP against a local self-hosted deployment does not need any of
this: GNU SETL's native `open(f, "tcp-client")` opens a real socket
directly, so the local profile never touches `callout()` or OpenSSL at
all. Only the hosted (TLS) profile does.

## What's left

The client library itself (`client/`), the JSON codec, HTTP/1.1 framing,
RFC 6455 WebSocket framing over the hex-encoded TLS boundary, the
`/api/sync` Live state machine, the NDJSON conformance adapter (with
`debugDisconnect`), the canonical example, and every test layer in
AGENTS.md are all still to be built. No `example-runtime` or `runtime`
Docker stage exists yet -- adding one before there is real client code to
run in it would ship a runtime image that does not actually run a Convex
client, which this repository's honesty rules forbid.
