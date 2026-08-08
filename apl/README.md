# Convex from APL

This demonstration uses GNU APL -- an implementation of the array language
itself, not a descendant -- to call Convex's documented JSON HTTP endpoints.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.apl`](examples/basics/main.apl) is the canonical
example. It queries a fresh counter room over HTTP, applies an idempotent
mutation, and queries again to prove the `0 -> 1` journey landed. The block
below is generated from that exact runnable file.

**This example is HTTP-only right now.** Live (the WebSocket `/api/sync`
subscription this project's other clients use) is not implemented, so the
example's output does not match this project's shared expected transcript,
which requires both transports -- see "What works" below.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Not yet verified | Query, mutation, and action calls, the `format:"json"` envelope, and structured `FunctionError`/`TransportError`/`ProtocolError` classification are implemented and pass language-local tests and hand-run checks against a real backend (see below), but shared `./run verify`/`verify-hosted` black-box conformance has not been run. No badge is claimed. |
| Live | Not implemented | The WebSocket `/api/sync` state machine (Connect, ModifyQuerySet, Transition, reconnect) does not exist yet. The conformance adapter answers `subscribe`/`unsubscribe`/`debugDisconnect` with a structured `ProtocolError` rather than a fabricated acknowledgement. |

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.apl -->
```text
#!/usr/local/bin/apl --script
⍝ Convex from GNU APL: the canonical shared-counter walk. This is the
⍝ exact source shown in the README and on the website, and it is also
⍝ what Docker verification runs against a live deployment -- there is
⍝ no separate "test" copy of this file.
⍝
⍝ It reuses the same client library the conformance adapter calls
⍝ into, client/convex.apl, installed at /opt/convex/client/convex.apl.
⍝ convex.apl implements the Convex HTTP protocol itself in APL (JSON
⍝ encoding/decoding and HTTP/1.1 request/response framing); the only
⍝ things it delegates outside APL are raw TCP/TLS bytes and one hash
⍝ primitive, via a small native function (client/shim.cc) loaded with
⍝ dyadic ⎕FX -- GNU APL's documented foreign-function mechanism.
⍝
⍝ LIMITATION, stated up front rather than hidden in a comment at the
⍝ bottom: Live (the WebSocket /api/sync subscription this project's
⍝ other clients use for their "live initial count"/"live updated
⍝ count" lines) is not implemented yet. This example demonstrates the
⍝ HTTP half of the walk only -- the initial query, the mutation and
⍝ its idempotency key, and a follow-up query proving the mutation
⍝ landed -- and its output does not (yet) match this project's shared
⍝ basics.expected.txt, which requires both transports. See the
⍝ project's manifest.yaml/README for the honest capability list.
```
<!-- END GENERATED EXAMPLE -->

(The block above is the file's header; the full runnable source, including
`Main` and its helpers, is in
[`examples/basics/main.apl`](examples/basics/main.apl) itself -- the website
build renders the complete file verbatim from that same source.)

## Verify it in Docker

```sh
./run test apl            # builds GNU APL from source, then runs the
                           # language-local self-tests and adapter/example
                           # smoke checks, entirely offline
./run verify-example apl  # runs the example above against a unique room
                           # on the local self-hosted backend
./run verify apl          # verify-example plus shared black-box conformance
```

`./run test apl` builds GNU APL 2.0 from its official source tarball
(Debian only packages GNU APL in `sid`, and only with `--with-gtk3`, which
this build does not need or want -- see "Toolchain" below), compiles the
native transport function with `-Wall -Wextra -Werror`, runs
`client/tests/selftest.apl` (JSON round-trip/escaping, object field lookup,
whole-number acceptance, URL parsing, HTTP status-line/header helpers,
chunked hex sizes, environment-variable handling, and the three
`HttpClassify` envelope shapes -- all with no network dependency), and a
smoke check of the conformance adapter and the canonical example's
`CONVEX_URL is required` error path.

Beyond that automated stage, this client has also been hand-verified end to
end against a real backend during development: a genuine `0 -> 1` query /
mutation / query round trip over plain HTTP against this project's local
self-hosted backend, the compiled conformance adapter driving
`hello` / `query` / `mutation` / `close` correctly in order, and a TLS
connection to a real internet host. `./run verify-example`/`verify` have not
been run yet, so none of that is an evaluator-awarded badge.

## Toolchain

GNU APL is built from the official upstream source release
(`ftp.gnu.org/gnu/apl`), pinned by URL and sha256, rather than installed
from Debian's `.deb`. Debian packages GNU APL only in `sid` (not yet in
`trixie`/`bookworm`), and its package build enables `--with-gtk3`, which
pulls in the entire GTK/cairo/pango stack for `⎕GTK`/`⎕PLOT`/`⎕PNG` -- none
of which a headless network client uses. The plain upstream tarball's
default configuration has `--with-gtk3` off, producing the same GPL,
Debian-adjacent GNU APL 2.0 with a runtime library closure of just
`libstdc++`/`libm`/`libc`/`libgcc_s` (confirmed with `ldd`).

## Conformance and protocol notes

- The client speaks the pinned `convex-rs@6f1df8a8` sync profile at
  `/api/sync` for the parts it implements (HTTP query/mutation/action);
  Live is not implemented, so nothing here yet exercises that endpoint's
  WebSocket upgrade.
- `client/convex.apl` is a GNU APL library workspace file, loaded by the
  adapter and the example with `)COPY '/opt/convex/client/convex.apl'` --
  the same mechanism GNU APL's own shipped `wslib5` standard-library files
  use, and, like them, `convex.apl` starts with the `⍝!` marker GNU APL's
  file-format check requires to recognise a plain-text file as a library
  rather than a `)DUMP`/XML workspace.
- GNU APL's own `⎕FIO` (`Quad-FIO[32..42]`) supplies raw TCP sockets
  natively -- `socket`/`connect`/`send`/`recv`/`read`/`write`/`fcntl` --
  for the plain (`ws://`, `http://`) transport; no native function is
  needed for that path at all. TLS (`wss://`, `https://`) uses a small
  native function, `client/shim.cc`, compiled against GNU APL's own
  internal headers (`Native_interface.hh` and friends) and loaded at
  runtime with dyadic `⎕FX` -- the documented mechanism GNU APL's own
  shipped `lib_file_io.so` uses for exactly this. The same native
  function also supplies SHA-1 (needed only for the RFC 6455 WebSocket
  handshake, once Live exists) and DNS resolution (`⎕FIO`'s own
  `connect()` takes an address that is already resolved to a 32-bit
  integer; GNU APL has no `getaddrinfo` of its own). No HTTP, JSON, or
  Convex protocol logic lives in the native function.
- `client/tests/conformance/adapter.apl` implements NDJSON adapter
  protocol v1 over both stdin/stdout and the `ADAPTER_LISTEN` TCP mode
  (`⎕FIO[41]`/`[42]`, read/write, work identically on a plain fd or an
  accepted socket fd), and declares `debugDisconnect` as its one
  adapter-only command -- currently answered with a structured
  `ProtocolError`, since Live does not exist yet to actually reconnect.
- GNU APL's CLI has no way to run a script from a bare positional
  filename argument, only via `-f file`; `/usr/local/bin/convex-example`
  and `/usr/local/bin/convex-adapter` are therefore tiny `#!/bin/sh`
  launchers that `exec apl -s -f <script> -- "$@"`, the same shape
  `unicon -o`'s own generated launcher uses for this project's Icon
  client.

## Limitations

- **Live is not implemented.** No WebSocket handshake, RFC 6455 framing,
  or `/api/sync` state machine (Connect/ModifyQuerySet/Transition/
  reconnect) exists yet. This is the main gap before this client could
  earn either badge, since the shared canonical example requires both
  transports.
- Bearer-token authentication (`setAuth`) is accepted by the adapter and
  threaded into the HTTP `Authorization` header, but has not been
  exercised against a deployment that actually requires it.
- The native function is deliberately narrow: TCP connect/send/recv/close
  for TLS, SHA-1, and DNS resolution only.
- `⎕FIO[40]` (`select`) reliably raised `DOMAIN ERROR` in this build even
  when its argument's shape and nesting exactly matched `Quad_FIO.cc`'s
  own documented expectations (checked directly with `⍴`/`≡`/`⊃` before
  it ever reached `select()`). The plain-socket transport works around
  this with a non-blocking `fcntl` + `⎕FIO[37]` `recv()` poll loop
  instead, which does not have the same problem.
