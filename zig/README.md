# Convex from Zig

This educational client calls Convex functions over HTTP and follows one
reactive query through the pinned `/api/sync` WebSocket profile. The canonical
example checks the counter's `0 -> 1` journey.

This is unofficial teaching material, not a production SDK.

## Start here

Read [`examples/basics/main.zig`](examples/basics/main.zig). It configures the
deployment, performs an HTTP query, starts Live before the mutation, applies an
idempotent mutation, and checks the resulting Live value.

## What works

| Capability | Status |
| --- | --- |
| Native implementation | Implemented, pending root-owned evidence |
| HTTP query, mutation, and action | Implemented, pending root-owned evidence |
| Bearer-token lifecycle | Implemented, pending root-owned evidence |
| Live initial values, updates, recovery, and reconnect hook | Implemented locally, pending root-owned evidence |
| Convex tagged values | Deferred, JSON-safe values only |

The README example block is generated from the canonical source by the shared
site tooling. The expected stdout transcript is:

```text
current count: 0
live initial count: 0
mutation applied: true
mutation count: 1
live updated count: 1
verified count: 0 -> 1
```

## Docker verification

```sh
./run test zig
./run build zig
```

The first command formats, unit-tests, and compiles the adapter and canonical
example inside a pinned `linux/amd64` Zig 0.14.1 image. The second produces the
minimal non-root example and adapter images. The root integration owner must
run `verify-example`, local conformance, and hosted conformance before any
capability badge is earned.

## Protocol notes

The adapter speaks NDJSON protocol v1 over stdin/stdout or one
`ADAPTER_LISTEN` TCP connection. A single Live owner handles WebSocket
connection state, query-set versions, reconnects, and writes. WebSocket frames
are masked on client writes, control frames are answered, timestamps are
compared as little-endian `uint64` values, and rehydration suppresses an
unchanged value.

The Live profile is the unversioned `convex-rs` 0.10.4 sync shape at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. It is a protocol experiment, not
an official compatibility promise.

## Limitations

Live authentication, optimistic updates, WebSocket mutations/actions, and
`TransitionChunk` assembly remain deferred. Fragmented WebSocket data and
partial-frame deadline recovery still need deterministic language-local
coverage, so Live remains an attempted profile rather than an earned badge.
Only the JSON-safe subset is decoded. Capability badges stay empty until the
shared evaluator records clean local and hosted evidence from the reviewed
commit.
