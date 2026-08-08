# Convex from Verilog

This directory is a work in progress toward a Convex client written as a
simulated hardware circuit in Verilog, run under Icarus Verilog (`iverilog`).

This is educational and unofficial. It is not a production Convex SDK, and
it is not published as a package.

## Status

The toolchain gate, a JSON codec, HTTP/1.1 framing and RFC 6455 WebSocket
framing exist so far. The gate proves, inside Docker on the pinned
toolchain, that a Verilog program can drive a real TCP connection and a
real certificate- and hostname-verified TLS handshake through a small VPI
(Verilog Procedural Interface) C module. `client/convex_buffer.v` adds a
hand-written JSON encoder and decoder, covering AGENTS.md's
integral-decimal-number rule (`0.0`/`1.0` decode as integers; fractional,
quoted, non-finite and overflowing values are rejected), proven with a
language-local unit suite. `client/convex_http.v` adds HTTP/1.1
request/response framing, proven with a real `POST /api/query` round trip
to the shared demo deployment. `client/convex_sha1.v` and
`client/convex_base64.v` add a pure-Verilog SHA-1 and base64 encoder
(no crypto library binding exists for this toolchain), proven against
RFC 6455's own worked handshake example. `client/convex_websocket.v`
builds RFC 6455 WebSocket framing on top of all of the above: masking,
fragmentation reassembly, interleaved control frames, one-shot (post-
reassembly) UTF-8 validation, and Sec-WebSocket-Accept verification,
proven against a fixture peer that independently checks the client's own
masked PONG and CLOSE frames. `client/convex_sync.v` adds the `/api/sync`
Live state machine (the pinned `convex-rs-0.10.4-unversioned-sync`
profile) on top of that: a subscription table, the initial value and
later external updates, five real reconnects through an adapter-facing
`debugDisconnect` hook with an unchanged rehydration correctly
suppressed and a genuine mutation still delivered every time,
`QueryFailed` followed by recovery on the same subscription,
`connectionCount`/`lastCloseReason`/`maxObservedTimestamp` carried
correctly, and exponential backoff that doubles on repeated failure and
resets after every successful handshake. The conformance adapter does
not exist yet, so there is still no canonical example and no capability
is claimed.

The design follows the same shape as this repository's `vhdl/` client
(also in progress): standard HDL has no sockets, no TLS and no clock
outside the simulator, so a small foreign-boundary module
(`client/native.c`) supplies exactly those primitives as two scalar
functions, and everything else - the request framing, the JSON, the
WebSocket handshake, the `/api/sync` state machine - is meant to live in
Verilog itself, driven through a clocked request/acknowledge circuit
(`client/convex_transport.v`) rather than through `iverilog` used as a
scripting language with `#delay` statements standing in for real
synchronization.

Where VHDL reaches its foreign boundary through GHDL's VHPIDIRECT (a
direct binding from a VHDL function declaration to a C symbol), this
client reaches it through Icarus's VPI: `client/native.c` registers two
Verilog system functions, `$cx_dispatch` and `$cx_now_ms`, and Icarus
calls back into this module's C code whenever simulated Verilog evaluates
either one. The effect at the call site is the same kind of "ordinary
looking call secretly leaves the simulator" boundary; the wiring
underneath is a callback table Icarus consults rather than a linked
symbol.

## What works

| Behaviour | Status |
| --- | --- |
| Real TCP connection driven from Verilog through the VPI boundary | Proven in Docker (`tcp_smoke`) |
| Real TLS handshake with certificate and hostname verification | Proven in Docker (`tls_smoke`), against `usable-reindeer-44.convex.cloud:443` |
| JSON codec (encode, parse, integral-decimal rule) | Proven in Docker (`json_test`), language-local unit suite |
| HTTP/1.1 request/response framing | Proven in Docker (`http_smoke`), real `POST /api/query` round trip |
| SHA-1 + base64 (Sec-WebSocket-Accept) | Proven in Docker (`sha1_test`), RFC 6455's own worked example |
| RFC 6455 WebSocket framing (mask, fragmentation, control frames, UTF-8) | Proven in Docker (`ws_smoke`), against a fixture peer |
| `/api/sync` Live protocol (subscribe, reconnect, rehydration, backoff) | Proven in Docker (`sync_smoke`), against a fixture peer |
| Canonical `examples/basics` | Not started |
| Conformance adapter | Not started |
| HTTP capability | Not earned |
| Live capability | Not earned |

## Docker verification

```sh
docker build --target test -t verilog-test .
```

This installs the pinned Icarus Verilog toolchain, builds `client/native.c`
as a VPI module against `vpi_user.h`, and proves:

- **`tcp_smoke`**: a real TCP round trip, driven entirely from Verilog
  through `client/convex_transport.v`'s clocked request/acknowledge bus and
  `$cx_dispatch`, against a one-shot fixture TCP server built in the same
  Docker stage.
- **`tls_smoke`**: a real TLS 1.x handshake to
  `usable-reindeer-44.convex.cloud:443`, with both certificate and hostname
  verification (`SSL_set1_host` plus `SSL_get_verify_result`), through the
  same VPI boundary, followed by a real HTTP/1.1 request sent over that
  handshake and a real status line read back - proof that application bytes
  travel through the verified channel, not only that a verification flag was
  set.
- **`http_smoke`**: a real `POST /api/query` round trip to the shared
  demo deployment over that same verified channel, driven through
  `client/convex_http.v`'s request/response framing and
  `client/convex_buffer.v`'s JSON codec, checking the real
  status/value/errorMessage/logLines envelope Convex's HTTP API returns.
- **`sha1_test`**: `client/convex_sha1.v` and `client/convex_base64.v`
  against two known-answer vectors, including RFC 6455's own worked
  handshake example (`Sec-WebSocket-Key` `dGhlIHNhbXBsZSBub25jZQ==` must
  produce `Sec-WebSocket-Accept` `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`) - no
  network involved.
- **`ws_smoke`**: a real RFC 6455 WebSocket handshake and message round
  trip against a fixture peer, proving masking (client-to-server frames),
  fragmentation reassembly across an interleaved PING control frame, and
  one-shot UTF-8 validation over the fully reassembled message rather
  than per fragment - the fixture independently checks the client's PONG
  and CLOSE frames arrived masked with the right content.
- **`sync_smoke`**: a real `/api/sync` session against a fixture peer
  through six sequential connections (one initial connect plus five
  `debugDisconnect`-triggered reconnects), proving the initial value, an
  external mutation, `QueryFailed` followed by recovery on the same
  subscription, and - on every one of the five reconnects - that an
  unchanged rehydration is suppressed while a genuine mutation is still
  delivered. The fixture independently checks each connection's own
  `connectionCount` and `lastCloseReason`, and a separate deterministic
  check proves exponential backoff actually doubles on repeated failure.

No `runtime` or `example-runtime` stage exists yet; there is nothing to run
outside the `test` stage until the client above the transport layer exists.

## Limitations and deferred work

- No conformance-adapter code exists yet, so there is still no canonical
  example driving these layers as a caller actually would.
- `client/convex_sync.v` does not validate Convex's `startVersion`/
  `endVersion` state-version continuity (a peer client,
  `mumps/client/convex.m`, does) - only `endVersion.ts` itself, for
  `maxObservedTimestamp`. See that file's own header comment for the
  reasoning; AGENTS.md's Live-acceptance section requires carrying
  `maxObservedTimestamp` correctly, not rejecting a state-version
  discontinuity, and the fixture peer never sends an invalid one.
- The bounded-under-a-stopped-reader pending-event queue AGENTS.md's
  Conformance-executable section describes is not part of
  `convex_sync.v`: that queue belongs to the NDJSON adapter (this
  module's future caller, which does not exist yet), which is what
  actually owns a slow or stopped consumer to buffer against.
  `convex_sync.v`'s own per-subscription state is a single latest-
  value slot with a version counter, not a growing queue.
- The gate's TCP, WebSocket and sync proofs all use a hermetic
  Docker-local fixture server; only the TLS and HTTP proofs reach the
  real Convex deployment, matching this project's policy against pointing
  arbitrary build-time network access at a real backend for anything but
  those proofs.
- `client/native.c` implements a deliberately small opcode subset so far
  (host accumulation, connect, close, byte write/flush, byte read, random
  byte, stdout/stderr write) - enough for the layers built so far.
  Environment lookup, readiness polling, stdin, exit, and the adapter's
  `ADAPTER_LISTEN` listen/accept pair are not implemented yet and will be
  added, mirroring `vhdl/client/native.c`'s equivalent set, as the layers
  that need them are built.
- The pinned `iverilog` does not support passing an unpacked array, a
  `ref` port, or even a dynamic `byte queue[$]`, into a task or function -
  confirmed directly against the toolchain rather than assumed. Every
  buffer in this client is therefore module state reached only through a
  hierarchical name, and `client/convex_buffer.v` combines byte storage
  with JSON parsing of its own content in one module rather than two
  separate packages the way `vhdl/` splits them.
- The same toolchain also expands a `\"` or a lone `\\` inside a
  SystemVerilog `string` literal into that escape's own four-character
  spelling instead of the single byte it should produce (`"a\"b".len()`
  reports 6, not 3) - documented in `client/convex_chars.vh`. Every
  string literal in this client that needs a literal quote or backslash
  spells it as an explicit byte constant instead.
- JSON string decoding does not combine a `\uD800`-`\uDBFF` /
  `\uDC00`-`\uDFFF` surrogate pair into one astral codepoint; it rejects
  the lone surrogate half instead. A Basic Multilingual Plane character
  (the overwhelming majority of real text, and everything Convex's own
  protocol control fields ever contain) decodes correctly; an emoji or
  rare CJK extension character in user data would not.
