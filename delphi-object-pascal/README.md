# Convex from Delphi/Object Pascal

A native Convex client written in Object Pascal, compiled by Free Pascal in
its `-Mdelphi` compatibility mode. It reads a shared counter over the
documented HTTP API, subscribes to the same query over a WebSocket, applies
one idempotent increment, and proves that the HTTP read, the mutation, and
the live subscription all agree.

This is educational and unofficial. It is not a production SDK, not a
sanctioned Convex client, and not published to any package registry.

## Start here

[examples/basics/ConvexExampleApp.pas](examples/basics/ConvexExampleApp.pas)
is the canonical source and is projected verbatim below. It reads a room's
current count over HTTP, opens a Live subscription before mutating so the
mutation cannot race past it, applies `demo:increment` with a room-derived
idempotency key, and waits for the same change to arrive over the open
WebSocket. It prints six lines and nothing else, and it fails rather than
printing an unexpected value.

## What works

| Area | Current state |
| --- | --- |
| HTTP query, mutation, action | Implemented, covered by deterministic local tests |
| Bearer token lifecycle | Implemented, covered by deterministic local tests |
| Live subscribe, update, failure, recovery | Implemented, covered by deterministic local tests |
| Live reconnect, replay, rehydration suppression | Implemented, covered by deterministic local tests |
| TLS transport (fpc `ssockets`/`sslsockets`/`opensslsockets`) | Implemented, not yet Docker-verified |
| NDJSON adapter over stdio and TCP | Implemented, not yet Docker-verified |
| Docker build, image hardening, runtime probes | Not yet run |
| Shared conformance, example verification, hosted drift | Not yet run |
| Capability badges | None earned |

No Docker build has ever been run against this source. Every claim above the
source and language-local-test level is unverified; see Limitations below.

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/ConvexExampleApp.pas -->
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

    ./run test delphi-object-pascal
    ./run verify-example delphi-object-pascal
    ./run verify delphi-object-pascal
    ./run verify-hosted delphi-object-pascal

`./run test delphi-object-pascal` builds a `linux/amd64` image that compiles
the client, the adapter, and the example with `fpc -Mdelphi -O2`, asserts the
resulting binaries are genuine x86-64 ELF images (not host-platform binaries
under an amd64 label), runs the deterministic unit-test suite, and probes the
adapter binary over stdio with malformed and well-formed input.
`./run verify-example delphi-object-pascal` runs the exact
`/usr/local/bin/convex-example` entrypoint from the minimal runtime image
against a unique room and compares its six stdout lines to the shared
transcript. `./run verify delphi-object-pascal` adds the shared black-box
conformance suite against the approved local backend, and
`./run verify-hosted delphi-object-pascal` repeats both against the hosted
drift target.

## Conformance and protocol notes

The Live transport implements the `convex-rs 0.10.4` unversioned `/api/sync`
profile pinned in `manifest.yaml`. That endpoint is not a documented,
versioned public API, so an unrecognised envelope fails the connection rather
than being skipped.

Design decisions worth knowing before reading the code:

- **fpc's bundled units, not hand-rolled sockets.** `TConvexSocket`
  (`client/ConvexSocket.pas`) is built on `ssockets`/`sslsockets`/`opensslsockets`.
  `TInetSocket` gives a blocking byte stream, optionally wrapped in TLS through
  `TOpenSSLSocketHandler`, with SNI (`SendHostAsSNI`) and certificate/hostname
  verification (`VerifyPeerCert`) through ordinary published properties. Every
  read carries an explicit millisecond deadline checked with a real `select(2)`
  call, so a stalled or malicious peer cannot block the client's single I/O
  path forever.
- **A documented fpc gap, fixed explicitly.** `TOpenSSLSocketHandler` never
  calls OpenSSL's own `SSL_CTX_set_default_verify_paths`; it only loads a CA
  bundle when one is set explicitly. With `VerifyPeerCert` on and no bundle
  configured, every handshake would fail "certificate verify failed" even
  against a perfectly valid certificate. `DefaultCaBundlePath` locates the
  distro's CA bundle (the runtime image is Debian-based and always installs
  `ca-certificates`) and sets it before every TLS connect.
- **Exact, range-checked numbers.** Convex JSON numbers may render an integral
  value as `0.0` rather than `0`. `ConvexJsonUtil.IsIntegralNumberInRange`
  checks a value is mathematically integral and in range before decoding it,
  so a fractional, quoted, non-finite, or overflowing count is a decoding
  failure rather than a number that silently changed.
- **`debugDisconnect` is adapter-only.** It is implemented in
  `client/tests/conformance/ConvexAdapterApp.pas`, declared in
  `manifest.yaml` under `adapter.adapterOnlyCommands`, and not exposed by
  `TConvexClient`, the unit an ordinary application imports.

## Limitations

Honest status, in the order it matters:

- **Nothing has been Docker-built or Docker-verified.** There is a complete
  2,700-line shape (client, adapter, example, unit tests) and language-local
  test coverage, but no Docker build has ever been run against it. Expect a
  first Docker pass to surface real compile and runtime issues.
- **The Live pending-event list is not yet a bounded queue.** `TConvexSync`
  appends to an ordinary `TObjectList` and the example drains it; there is no
  documented count or byte bound and no proven overflow behaviour for a slow
  or stopped consumer. This needs to pass the shared conformance byte-budget
  check with a stopped reader and near-maximum messages before Live evidence
  can be claimed.
- **The runtime version is stamped, not introspected.** Free Pascal has no API
  to report its own version at run time, so the adapter's `hello` response
  reports a hardcoded string (`Free Pascal 3.2.2 (Delphi mode)`) matching the
  pinned toolchain rather than an introspected value.
- **Deferred protocol behaviour.** Live authentication against an already-open
  subscription, WebSocket mutations and actions, and optimistic updates are
  not implemented and fail closed.
- **No capability is claimed.** `capabilities` in `manifest.yaml` is empty and
  stays empty until the shared evaluator says otherwise.
