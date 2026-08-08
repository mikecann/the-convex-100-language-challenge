# Convex from CLU

This is a Convex client written in CLU, Barbara Liskov's 1975 language and
the original home of the abstract data type: every non-trivial piece of
state in this client (a `_tls` connection, the JSON scanner, the WebSocket
frame reader, the `/api/sync` state machine) is built as a CLU `cluster` --
data plus the operations on it, with no other code allowed to reach into its
representation -- which is precisely the idea CLU introduced.

## This is educational, not a production SDK

This client is a demonstration for a video and a website, not an official
Convex SDK. It is unofficial, unsupported, and not intended for production
use. CLU itself has been unmaintained since the early 1990s; this uses
[Portable CLU (pclu)](https://hg.sr.ht/~nbuwe/pclu), a 2021+ community
fix-up that builds on modern 64-bit Linux.

## Start here

The [canonical basic example](examples/basics/main.clu) queries a shared
counter over HTTP, starts a Live subscription before mutating it, applies the
mutation with an idempotency key, and proves the Live update agrees with the
mutation's own result -- the same `0 -> 1` journey every language in this
repository demonstrates.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions against Convex's documented `"format":"json"` API | Verified by shared local and hosted conformance |
| RFC 6455 WebSocket framing (masking, fragmentation, interleaved control frames, UTF-8 validated once after reassembly) | Verified by shared local and hosted conformance |
| `/api/sync` Live: Add/Remove, initial and external `QueryUpdated`, `QueryFailed` and recovery, five real `debugDisconnect` reconnects with unchanged rehydration suppressed | Verified by shared local and hosted conformance |
| Conformance adapter (NDJSON v1, stdin/stdout and `ADAPTER_LISTEN` TCP) | Verified by shared local and hosted conformance |

`./run verify-all clu` passed 31/31 checks on both the local and hosted
profiles from a clean, exact-head commit; see `manifest.yaml`'s
`capabilities` list for the shared evaluator's own award.

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.clu -->
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test clu
```

Builds pclu 1a8ad7603ea20b9744942182a52810441182f6a6 from source (Boehm GC
7.2f static, the `-fcommon` fix GCC 10+ needs, and
`client/wordvec-64bit-word-size.patch`, a real 64-bit addressing bug fixed
during development), adds the `_tls` builtin cluster, boots a hello-world
smoke test, checks source style, compiles and runs the full language-local
unit suite (JSON codec, arithmetic bitwise helpers, base64, this client's own
DNS resolver, HTTP/1.1 framing, RFC 6455 WebSocket framing, and the
`/api/sync` state machine -- the last four against real loopback-TCP peers,
not mocks), compiles and links the canonical example and the conformance
adapter, and proves the adapter's own hello/close NDJSON lifecycle.

```sh
./run verify-example clu
./run verify clu
./run verify-hosted clu
./run verify-all clu
```

Run the canonical example and the shared black-box conformance suite against
the local backend, the hosted drift target, and both together, respectively.

## Lower-level notes

- **pclu's C-boundary mechanism.** A `.spc` file declares a cluster's
  operation signatures with empty bodies (interface only, never compiled to a
  body); a separate hand-authored `.c` file supplies C functions named
  `<type>OP<opname>` that the linker resolves by that naming convention when
  `libpclu_opt.a` is linked. No dlopen, no FFI declarations, no glue-code
  generator. pclu's own builtins (`_chan`, `_wordvec`, ...) are written this
  way; `client/convexrt-tls.c` + `client/_tls.spc` add one more, the same
  way. `_tls$recv` takes an explicit `timeout_ms` and waits with `poll(2)` on
  the connection's own file descriptor before ever calling `SSL_read`, so a
  caller can tell a live-but-idle connection (signals `timeout`) apart from
  one the peer actually closed (signals `end_of_file`).
- **The 64-bit `_wordvec` bug.** `client/wordvec-64bit-word-size.patch`
  fixes a real, previously unreported bug: on 64-bit builds `_wordvec`'s
  byte- and half-word-addressed operations could only ever address the first
  four bytes of every eight-byte storage slot. See the patch file's own
  header comment for the full write-up; it is likely worth reporting to
  upstream pclu independently of this project.
- **pclu's own bundled DNS client silently fails against Docker's
  resolv.conf.** `lib/clu/_resolve.clu` only recognises `;` as a comment
  character (an Ultrix/BSD convention from its 1985/1989 MIT copyright
  header); every modern Linux resolv.conf, including the one Docker
  generates, uses `#` instead. `_resolve` mistakes the first comment line
  for the domain/nameserver line it expects, fails to parse it as an
  address, silently swallows that failure, and is left querying the
  untouched default of `127.0.0.1` until every real hostname lookup times
  out. Rather than patch unfamiliar 1980s DNS wire-format C, this client
  ships its own small resolver, `client/convex-dns.clu`: it reads the real
  nameserver out of `/etc/resolv.conf` correctly, sends one A-record query
  over UDP, and parses the answer (including DNS name compression
  pointers). `convex-transport.clu`'s `dial()` calls it exactly where it
  used to call `_resolve$n2a`, with the same three signals.
- **Local vs. hosted transport.** `client/convex-transport.clu`'s `conn`
  type is a `oneof[chan: _chan, tls: _tls]`: the local profile dials a raw
  `_chan` socket by hand (a literal dotted-quad address via `inet_address`,
  or `client/convex-dns.clu` if that fails); the hosted profile calls
  `_tls$connect`, which does DNS (via OpenSSL/glibc, not this client's own
  resolver), the TCP connect, and the TLS handshake (with real chain and
  hostname verification) all inside one C builtin.
- **`convex-sync.clu` has no owner thread, because pclu has no threads.**
  Instead the whole `/api/sync` state machine lives behind one `poll()`
  operation that does at most one bounded WebSocket read per call and
  returns at most one delivery; a caller (the conformance adapter, or the
  canonical example) drives it by calling `poll()` repeatedly. See
  `convex-sync.clu`'s own header comment for the full reasoning, including
  why this client's delivery buffering is deliberately one slot per
  subscription rather than a queue.
- **The conformance adapter is the same kind of loop.** It reads one
  buffered NDJSON command line if one is ready; otherwise it waits briefly
  for more input; if nothing arrived, it gives `sync$poll()` one chance to
  check the Live socket and deliver at most one subscription event. Every
  event is written the moment it is produced, never batched, which is this
  client's whole answer to a stopped reader: ordinary pipe backpressure
  stalls this same loop rather than it ever accumulating a backlog of its
  own.
- **Several real pclu quirks were found and are documented at their call
  sites** (`convex-http.clu`, `convex-websocket.clu`, `convex-sync.clu`,
  `convex-dns.clu`, the conformance adapter): a `return` statement's
  expression list is positional, one value per slot; an `except` clause
  binds only to the single statement immediately before it; identifiers are
  resolved case-insensitively, so words like `any` and `has` that appear
  inside pclu's own generic-type/where-clause syntax collide with an
  ordinary local variable of the same name; a `cvt`-typed operation
  parameter is already treated as `rep` inside its own operation, so
  passing it on as another `cvt`-taking operation's own argument needs an
  explicit `up()` conversion; and `_chan$recv`/`$send` only work on an
  actual socket (`_chan$getb`/`$putb`, plain `read(2)`/`write(2)`, work on
  a pipe, a character device, or a socket alike).

## Known limitations

See `manifest.yaml`'s `limitations` list, which is the source of truth and
is kept current as this client progresses.
