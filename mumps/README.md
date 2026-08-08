# Convex from MUMPS

This demonstration uses YottaDB's implementation of M (MUMPS) to call
Convex's documented JSON HTTP endpoints and to keep a reactive query current
through a native M WebSocket connection.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.m`](examples/basics/main.m) is the canonical example.
It reads a new counter room over HTTP, starts Live before changing it,
applies an idempotent mutation, and proves the same `0 -> 1` journey arrived
through the subscription. The block below is generated from that exact
runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Not yet verified | Query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented and pass real loopback tests in Docker, but shared local and hosted black-box conformance have not run yet. |
| Live | Not yet verified | Subscribe/unsubscribe, reconnect-on-drop with exponential backoff, unchanged-rehydration suppression, reactive error recovery, and clean close are implemented and pass real loopback tests in Docker, but shared local and hosted black-box conformance (including the five-reconnect proof) have not run yet. |

No capability badge is claimed until the shared evaluator runs local and
hosted conformance from a clean exact-head build.

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.m -->
<!-- projected by ./run sync-examples -->
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

```sh
./run test mumps            # installs YottaDB r2.06 (with its OpenSSL TLS
                             # plugin) from the pinned installer, compiles
                             # the client, and runs the real loopback
                             # HTTP/Live fixtures and unit tests, entirely
                             # offline
./run verify-example mumps  # runs the exact block above against a unique
                             # room on the local self-hosted backend
./run verify mumps          # verify-example plus shared black-box conformance
```

`./run test mumps` installs YottaDB r2.06 from its pinned installer script
(Debian does not package it), building the OpenSSL-backed TLS plugin from
source as part of the same install, compiles every checked-in `.m` source to
a native object with `mumps -object`, runs `client/tests/jsontest.m` and
`client/tests/cryptotest.m` (the JSON codec and the SHA-1/base64 digest
primitives the WebSocket handshake depends on) with no network at all, and
runs `client/tests/httptest.m` and `client/tests/livetest.m` against real
`127.0.0.1` sockets served by `client/tests/fixture.m` -- not mocks -- so a
bug in the client's own request framing or WebSocket codec cannot pass by
construction.

## Conformance and protocol notes

- The client speaks the pinned `convex-rs@6f1df8a8` sync profile at
  `/api/sync`, matching every other client in this project.
- Every socket is opened with M's own `OPEN`/`USE`/`READ`/`WRITE` device
  syntax (device type `"SOCKET"`); TLS is a `WRITE /TLS(...)` on that same
  device, backed by YottaDB's OpenSSL plugin (`libgtmtls.so`, built from
  source with the installer's `--encplugin` option) -- there is no foreign
  process or shim involved for either plain or encrypted transport.
- `sockOpen` deliberately opens an empty `SOCKET` device first and `USE`s it
  with `CONNECT`, then reads `$KEY` while it is the current device, rather
  than trusting `$DEVICE` on a single combined `OPEN`/`CONNECT`: `$DEVICE`
  was observed reporting success for both a live connection and a genuinely
  refused one, which YottaDB's own documentation attributes to `$DEVICE`/
  `$KEY` only being meaningful for the device actually `USE`d. `$KEY`
  reliably reports `"ESTABLISHED|handle|address"` on success and `""` on
  failure.
- `sockRead` uses the uncounted form of `READ`, not `READ var#count:timeout`:
  direct experiment against a peer that writes a few bytes and then holds
  the connection open confirmed the counted form blocks for the whole
  timeout (or EOF) instead of returning as soon as any data is ready, which
  would make every read on a live connection cost its entire budget.
- Live delivery buffering is deliberate and bounded in two layers. The
  client itself keeps only the latest value per subscription (a Transition
  overwrites the prior one in place -- no unbounded queue). The test-only
  conformance adapter (`client/tests/conformance/adapter.m`) adds a bounded
  output queue on top of that for backpressure toward the controller: 8
  slots, a 4 MiB byte budget, subscription events droppable oldest-first,
  and `hello`/`result`/`error`/`ack`/`closed` responses never dropped.
- Reconnect-on-drop uses exponential backoff (250ms base, doubling, capped
  at 30s), reset to the base the moment a handshake next succeeds so a
  healthy connection never inherits a stale, grown delay from an earlier,
  unrelated run of failures. `liveMaybeReconnect` is polled once per
  adapter main-loop pass rather than run on its own thread -- M here is
  single-threaded, so the Live socket, the controller connection, and
  reconnect scheduling are all driven from that one loop, never touched
  concurrently.
- A reconnect resends every active subscription's `Add` and arms a
  one-shot rehydration guard per subscription. If the very next
  `QueryUpdated` for that subscription is byte-identical to the value it
  had before the drop, it is suppressed rather than delivered a second
  time; a changed value, or a `QueryFailed`, clears the guard and is
  delivered normally. This keeps a debugDisconnect-triggered reconnect's
  observable sequence exactly initial value, disconnect acknowledgement,
  external change, updated value -- not an extra unchanged rehydration in
  between.
- `client/tests/conformance/adapter.m` implements NDJSON adapter protocol
  v1 over both stdin/stdout and the `ADAPTER_LISTEN` TCP mode, and declares
  `debugDisconnect` as its one adapter-only command.
- Fragmented WebSocket messages are reassembled correctly: continuation
  frames are concatenated as raw payload bytes into the message in
  progress, control frames (ping/pong/close) are handled between the
  fragments of a data message per RFC 6455 without disturbing that
  assembly, and UTF-8 is never separately validated by this client (Convex
  JSON payloads are decoded byte-for-byte in M mode; the JSON parser itself
  rejects malformed encoding while parsing string literals).
- YottaDB always attaches a database region at process startup, even though
  this client never references a `^global`; a region is created once at
  build time (`mupip create`) and shipped read-only inside the runtime
  images, never written again.

## Limitations

- Shared local and hosted black-box conformance have not run yet. Every
  claim above is language-local Docker evidence only; no capability badge
  is claimed until the shared evaluator runs from a clean exact-head build.
- Live authentication, WebSocket-issued mutations/actions, journals, and
  `TransitionChunk` assembly are deferred; a `TransitionChunk` is reported
  as protocol drift and the connection reconnects.
- A YottaDB process always runs in byte-oriented M mode here (`ydb_chset=M`
  for every stage), not UTF-8 mode. `--utf8` is deliberately never passed to
  the installer: it would only add a second, ICU-linked engine variant this
  client never selects, at the cost of an extra dependency.
