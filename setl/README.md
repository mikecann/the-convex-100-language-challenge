# SETL

This language client is planned as roster entry 45.

No capabilities have been earned yet and no shared conformance has run.
What exists so far, all proven inside the Dockerfile's `test` stage against
real network peers (a well-known public host and a public WebSocket echo
service, not the Convex backend yet): the from-source interpreter build
with its native TLS boundary, a JSON codec, an HTTP/1.1 client over both
the plain-TCP and TLS transports (including chunked response bodies), a
Convex query/mutation/action wrapper over the documented HTTP envelope,
and an RFC 6455 WebSocket client (masking, fragmentation reassembly,
transparent ping/pong, close handling, and UTF-8 validation).

- Selection tier: `ranked`
- Implementation status: `planned`
- Earned capabilities: none

## What works so far

| Piece | Status |
| --- | --- |
| GNU SETL interpreter + TLS boundary build | Proven in Docker |
| `client/json.setl` (JSON codec) | Tested, 26 checks |
| `client/tcp.setl` / `client/tls.setl` / `client/stream.setl` (transports) | Tested against real hosts |
| `client/http.setl` (HTTP/1.1 framing) | Tested against real hosts, both transports |
| `client/convex.setl` (query/mutation/action + envelope classification) | Unit-tested against synthetic responses |
| `client/websocket.setl` (RFC 6455 framing, masking, fragmentation, UTF-8) | Tested against a real echo service, real and synthetic frames |
| `/api/sync` Live state machine | Not started |
| NDJSON conformance adapter (`debugDisconnect`) | Not started |
| `examples/basics/main.setl` | Not started |

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

## RFC 6455 WebSocket framing

`client/websocket.setl` sits on top of `client/stream.setl`, so it works
unchanged over either transport: plain TCP for the local profile, and the
hex-encoded `callout()` boundary for the hosted (TLS) profile. It
implements the HTTP Upgrade handshake with a verified
`Sec-WebSocket-Accept` token (the SHA-1 half of that check runs through a
new `callout()` service rather than being hand-rolled in SETL, reusing the
OpenSSL already linked in for TLS -- see the service table in
`client/callskel.c`), one masked, unfragmented text frame per outbound
send, and inbound reassembly of fragmented messages with transparent
ping/pong replies, peer-close handling, and a single UTF-8 validation pass
over the fully reassembled message (never fragment-by-fragment, since a
multi-byte code point can legally split across a fragment boundary).

`client/tests/websocket_test.setl` proves this two ways in the same
`test` stage: a real connection to a public WebSocket echo service
round-trips a short frame, a frame past the 125-byte length encoding, and
a clean close; a second real connection then has its read buffer filled
by hand with hand-built frames to deterministically exercise fragmentation
reassembly, a ping interleaved between fragments, and rejection of a lone
UTF-8 continuation byte -- properties a public echo service cannot be
relied on to reproduce, since it only ever echoes back whatever this
client already sent it.

## Other GNU SETL lessons learned along the way

- A source unit's mainline (executable) statements must all precede its
  `proc` definitions, with no interleaving -- confirmed by hitting the
  syntax error directly, not from documentation. Every proc-only module in
  `client/` is therefore meant to be `#include`d (via `setl --cpp`) near
  the end of a file, after that file's own mainline code.
- Several plausible identifiers are reserved words: `wr`, `reads`, `ok`,
  `is_float`, `host`, `port`, `body`, `status`, `hostname`, `op`, among
  others hit while writing this client. There is no single documented list
  to check against; `src/lexicon` in the GNU SETL source tree is the
  ground truth.
- GNU SETL map assignment `m(k) := om` does not store an entry (`om` is
  also what a missing-key lookup returns), so this client's JSON decoder
  cannot tell an object's `{"k":null}` apart from `{}` -- see the module
  comments in `client/json.setl` and `client/convex.setl`.
- `len` is also a reserved word, hit while writing `client/tests/websocket_test.setl`'s
  synthetic frame builder; `payload_len` (already used elsewhere in this
  client) works fine.

## What's left

The `/api/sync` Live state machine, the NDJSON conformance adapter (with
`debugDisconnect`), the canonical example, and every test layer in
AGENTS.md are all still to be built. No `example-runtime` or `runtime`
Docker stage exists yet -- adding one before there is real client code to
run in it would ship a runtime image that does not actually run a Convex
client, which this repository's honesty rules forbid.
