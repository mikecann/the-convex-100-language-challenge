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

## Status: build infrastructure only, no working client yet

**There is no canonical example and no conformance adapter yet.** This
section will link to `examples/basics/main.clu` once it exists; for now,
what exists is the Docker build that compiles pclu itself from source and
a JSON codec with real unit coverage. See `manifest.yaml`'s `limitations`
for the exact, current, honest state. The build recipe here, and two of
its trickiest problems (the `_wordvec` 64-bit bug and the new `_tls`
builtin), were first proven in a standalone feasibility spike before this
client was started; that spike's evidence is not part of this repository.

## What works

| Capability | Status |
| --- | --- |
| Builds pclu from source at a pinned commit, in Docker | Yes |
| JSON field extraction and a whole-number (incl. integral-decimal) decoder | Yes, unit tested |
| JSON request-body encoding (`qs`, `object1`/`2`/`3`) | Yes, unit tested |
| HTTP/1.1 request/response framing | Not started |
| TCP transport for the local profile (`_chan`, already in pclu) | Proven in the feasibility spike; not yet wired into this client |
| TLS transport for the hosted profile (new `_tls` builtin) | Proven in the feasibility spike, including real certificate verification; not yet wired into this client |
| RFC 6455 WebSocket framing (masking, fragmentation, control frames, UTF-8) | Not started |
| `/api/sync` state machine | Not started |
| Conformance adapter (NDJSON v1, TCP mode, `debugDisconnect`) | Not started |
| Canonical example (`examples/basics/main.clu`) | Not started |
| `http` capability | Not earned |
| `live` capability | Not earned |

## Docker verification

```sh
./run test clu
```

Builds pclu 1a8ad7603ea20b9744942182a52810441182f6a6 from source (Boehm GC
7.2f static, the `-fcommon` fix GCC 10+ needs, and
`client/wordvec-64bit-word-size.patch`, a real 64-bit addressing bug fixed
during development), adds the new `_tls` builtin cluster, boots a
hello-world smoke test, checks source style, and compiles and runs
`client/tests/json_test.clu`. This proves the toolchain and the JSON
codec; it does not build or prove a runtime image, because there is no
working client to ship in one yet.

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
  `client/_tls.spc` add one more, the same way.
- **The 64-bit `_wordvec` bug.** `client/wordvec-64bit-word-size.patch`
  fixes a real, previously unreported bug: on 64-bit builds `_wordvec`'s
  byte- and half-word-addressed operations could only ever address the
  first four bytes of every eight-byte storage slot. See the patch file's
  header comment for the full write-up; it is likely worth reporting to
  upstream pclu independently of this project.
- **Local vs. hosted transport.** The local profile is intended to use
  pclu's existing `_chan` builtin (real BSD sockets, already proven end
  to end with a raw HTTP round trip in the feasibility spike); the hosted
  profile is intended to use the new `_tls` builtin (OpenSSL underneath,
  real certificate verification, already proven end to end with a real
  TLS handshake and HTTPS GET against the project's hosted test
  deployment in the feasibility spike). Neither is wired into a Convex
  client yet -- both spikes exercised raw HTTP, not `/api/sync`.

## Known limitations

See `manifest.yaml`'s `limitations` list, which is the source of truth and
is kept current as this client progresses; this README will be rewritten
once there is a working canonical example to describe instead.
