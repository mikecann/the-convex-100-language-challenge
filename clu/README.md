# Convex from CLU

This is an early, in-progress attempt at a Convex client written in CLU,
Barbara Liskov's 1975 language and the original home of the abstract data
type: every non-trivial piece of state here (a `_tls` connection, the JSON
scanner, later the WebSocket framer and sync state machine) is meant to be
built as a CLU `cluster` -- data plus the operations on it, with no other
code allowed to reach into its representation -- which is precisely the
idea CLU introduced and this whole repository is, in small part, a chance
to show working.

## This is educational, not a production SDK

This client is a demonstration for a video and a website, not an official
Convex SDK. It is unofficial, unsupported, and not intended for production
use. CLU itself has been unmaintained since the early 1990s; this uses
[Portable CLU (pclu)](https://hg.sr.ht/~nbuwe/pclu), a 2021+ community
fix-up that builds on modern 64-bit Linux.

## Status: HTTP/1.1 transport works, no Live and no client yet

**There is no canonical example and no conformance adapter yet.** This
section will link to `examples/basics/main.clu` once it exists. What exists
now: the Docker build that compiles pclu itself from source, a JSON codec,
arithmetic bitwise helpers, a transport layer unifying the plain and TLS
profiles, and full HTTP/1.1 request/response framing against Convex's
documented JSON API -- all with real unit and loopback-TCP coverage. See
`manifest.yaml`'s `limitations` for the exact, current, honest state. The
build recipe here, and two of its trickiest problems (the `_wordvec` 64-bit
bug and the new `_tls` builtin), were first proven in a standalone
feasibility spike before this client was started; that spike's evidence is
not part of this repository.

## What works

| Capability | Status |
| --- | --- |
| Builds pclu from source at a pinned commit, in Docker | Yes |
| JSON field extraction and a whole-number (incl. integral-decimal) decoder | Yes, unit tested |
| JSON request-body encoding (`qs`, `object1`/`2`/`3`) and string unescaping (`unqs`) | Yes, unit tested |
| Arithmetic bitwise helpers (`xor`/`and`/`or`/`not`/rotate) for WebSocket masking and its handshake SHA-1 | Yes, unit tested |
| Unified transport (`conn`: dial/send/recv/close over `_chan` or `_tls`, poll-gated bounded reads) | Yes, real loopback-TCP tested |
| HTTP/1.1 request/response framing (Content-Length, chunked, close-terminated) | Yes, real loopback-TCP tested |
| Convex `"format":"json"` envelope classification (result / FunctionError / TransportError / ProtocolError) | Yes, real loopback-TCP tested |
| RFC 6455 WebSocket framing (masking, fragmentation, control frames, UTF-8) | Not started |
| `/api/sync` state machine | Not started |
| Conformance adapter (NDJSON v1, TCP mode, `debugDisconnect`) | Not started |
| Canonical example (`examples/basics/main.clu`) | Not started |
| `http` capability | Not earned (no adapter/example to run shared conformance against yet) |
| `live` capability | Not earned |

## Docker verification

```sh
./run test clu
```

Builds pclu 1a8ad7603ea20b9744942182a52810441182f6a6 from source (Boehm GC
7.2f static, the `-fcommon` fix GCC 10+ needs, and
`client/wordvec-64bit-word-size.patch`, a real 64-bit addressing bug fixed
during development), adds the new `_tls` builtin cluster, boots a
hello-world smoke test, checks source style, and compiles and runs four
language-local unit suites: `client/tests/json_test.clu`,
`client/tests/bitops_test.clu`, and two real loopback-TCP suites,
`client/tests/transport_test.clu` and `client/tests/http_test.clu`, against
genuine peer processes (`client/tests/fixtures/{echo,http}_fixture.clu`),
not mocks. This proves the toolchain, the JSON codec, the transport layer,
and HTTP/1.1 framing; it does not build or prove a runtime image, because
there is no working client to ship in one yet.

`./run verify-example clu`, `./run verify clu`, `./run verify-hosted clu`,
and `./run verify-all clu` all require the conformance adapter and
canonical example, neither of which exist yet.

## Lower-level notes

- **pclu's C-boundary mechanism.** A `.spc` file declares a cluster's
  operation signatures with empty bodies (interface only, never compiled
  to a body); a separate hand-authored `.c` file supplies C functions
  named `<type>OP<opname>` that the linker resolves by that naming
  convention when `libpclu_opt.a` is linked. No dlopen, no FFI
  declarations, no glue-code generator. pclu's own builtins (`_chan`,
  `_wordvec`, ...) are written this way; `client/convexrt-tls.c` +
  `client/_tls.spc` add one more, the same way. `_tls$recv` takes an
  explicit `timeout_ms` and waits with `poll(2)` on the connection's own
  file descriptor before ever calling `SSL_read`, so a caller can tell a
  live-but-idle connection (signals `timeout`) apart from one the peer
  actually closed (signals `end_of_file`) -- an SSL-level read timeout
  alone cannot make that distinction.
- **The 64-bit `_wordvec` bug.** `client/wordvec-64bit-word-size.patch`
  fixes a real, previously unreported bug: on 64-bit builds `_wordvec`'s
  byte- and half-word-addressed operations could only ever address the
  first four bytes of every eight-byte storage slot. See the patch file's
  header comment for the full write-up; it is likely worth reporting to
  upstream pclu independently of this project.
- **Local vs. hosted transport.** `client/convex-transport.clu`'s `conn`
  type is a `oneof[chan: _chan, tls: _tls]`: the local profile dials a raw
  `_chan` socket by hand (DNS via pclu's own `_resolve` library, or a
  literal dotted-quad address via `inet_address`, whichever parses); the
  hosted profile calls `_tls$connect`, which does DNS, the TCP connect,
  and the TLS handshake (with real chain and hostname verification) all
  inside one C builtin. Both are exercised end to end by
  `client/tests/transport_test.clu` against a real loopback TCP peer; only
  the plain `_chan` path is covered by an automated test so far; the `_tls`
  path was proven separately in the feasibility spike and will get its own
  automated coverage once the hosted profile is exercised by verification.
- **Two real pclu quirks found along the way**, both documented at their
  call sites in `client/convex-http.clu`: a `return` statement's expression
  list is positional, one value per slot, so a single nested call that
  itself yields several values can never fill several of those slots at
  once; and an `except` clause binds only to the one statement immediately
  before it, so a fallible call followed by another unguarded statement
  before the `except` silently leaves that second statement's own signals
  uncaught unless both are wrapped in one `begin ... end` first.

## Known limitations

See `manifest.yaml`'s `limitations` list, which is the source of truth and
is kept current as this client progresses; this README will be rewritten
once there is a working canonical example to describe instead.
