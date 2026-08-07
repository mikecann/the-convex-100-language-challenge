# Convex from PL/I

A native Convex client written in PL/I and compiled by Iron Spring PL/I 1.4.1. It calls Convex functions over HTTP and keeps a query current over the pinned Live WebSocket profile — JSON, HTTP/1.1, RFC 6455 framing and the Convex sync state machine are all written in PL/I.

This is educational and unofficial, not a production Convex SDK.

## Start here

[`examples/basics/main.pli`](examples/basics/main.pli) follows one shared counter from 0 to 1. It reads the room with an ordinary HTTP query, opens a Live subscription to the same query *before* changing anything, applies one idempotent mutation, and then shows the Live subscription reporting the new value on its own. The final line is printed only after every step agrees.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations and actions | Working against the local backend; shared conformance evidence not yet run |
| Bearer-token replacement and structured function errors | Working against the local backend; shared conformance evidence not yet run |
| Live initial values and external updates | Working against the local backend; shared conformance evidence not yet run |
| Remove, reconnect, query-error recovery and bounded delivery | Covered by deterministic language-local tests; shared conformance evidence not yet run |
| Live authentication, WebSocket mutations and actions, optimistic updates | Deferred |

No capability badge has been earned. The table above says what has actually been observed, not what is intended.

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.pli -->
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test pli` builds the compiler from its pinned tarball, runs the style gate, the client unit tests and the deterministic Live tests, and exercises the adapter's real stdin/stdout behaviour. `./run verify-example pli` runs the exact example above against the approved local backend in its minimal image. `./run verify-all pli` is the shared HTTP and Live conformance gate on both the local and hosted deployments.

## How it is put together

Iron Spring PL/I produces 32-bit ELF objects and its runtime library is 32-bit, so the client binaries are i386 executables running on an amd64 image through the kernel's ia32 compatibility layer. They are linked against Debian's i386 multiarch C library and OpenSSL. Sockets, DNS, TLS, and the SHA-1, base64 and random bytes the RFC 6455 handshake needs are reached through PL/I's `OPTIONS( BYVALUE LINKAGE(SYSTEM) )` foreign-call convention; no Convex behaviour is delegated.

Two details of this compiler shaped the design more than anything else:

- **A CHAR string is capped at about 32000 characters.** An HTTP body or a Live message cannot live in one, so every payload larger than a short field is held in libc-allocated storage addressed by a pointer and a length, and PL/I reads it a byte at a time through a `BASED` overlay. A Convex value is carried as the exact JSON text it arrived as, which is also why values survive byte for byte with no PL/I value tree in the middle.
- **The runtime's start-up routine installs signal handlers with the legacy i386 `sigaction` syscall**, which Docker's default seccomp profile refuses. Every stock PL/I binary therefore dies with `SIGACTION 1 returned -1` before reaching `main` inside a container. [`client/plisig.pli`](client/plisig.pli) replaces that one routine with an `rt_sigaction` version that the profile does allow, and it is linked ahead of the vendor archive so the original is never pulled in. The compiler itself cannot be relinked, so it — and only it — runs under `qemu-i386-static` during the build.

## Protocol notes and limits

The adapter speaks NDJSON protocol v1 on stdin and stdout, or over one `ADAPTER_LISTEN` TCP connection. A single thread owns everything: the same poll loop that reads controller commands also reads the WebSocket, so reads, writes, reconnects and query-set version changes cannot interleave. Reconnection backs off from 100 ms to 15 s and resets after a successful handshake. Each reconnection resends the active `Add` operations, and an unchanged value replayed by the new connection is suppressed so a caller waiting for the next change does not see the old one.

Delivery is bounded twice: each subscription retains the newest 16 updates and drops the oldest, and the client refuses any single HTTP body or Live message above 2 MiB and holds at most 8 MiB of undelivered updates in total.

Deferred: Live authentication, WebSocket mutations and actions, optimistic updates, tagged Convex value types, and `TransitionChunk` assembly — which is treated as protocol drift that reconnects. Rehydration suppression compares values as JSON text rather than semantically, so a value the backend re-serialised differently would be republished rather than suppressed.
