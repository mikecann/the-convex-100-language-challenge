# Convex from Modula-3

This demonstration is in progress. It will use CM3 (Critical Mass Modula-3)
to call Convex's documented JSON HTTP endpoints and to keep a reactive query
current through a native WebSocket connection.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

- Selection tier: `ranked`
- Implementation status: `attempting`
- Earned capabilities: none yet

This is roster entry 52, replacing `oz`. Oz reached a real socket and
completed an HTTP round trip natively, but its TLS path required rebuilding
Mozart 2's own unmaintained 2016-era AST-dump code generator, which crashed
on the same file 208 consecutive times -- a genuine, reproducible
memory-safety bug in vendored tooling, not bad luck. See `INFEASIBLE.md` for
the full account.

Modula-3 is chosen for this slot specifically because it needs none of that:
a real, long-stable standard-library TCP/IP socket interface (the `tcp`
package: `TCP.i3`/`IP.i3`, DEC SRC/Olivetti heritage) for the plain
transport, and genuine C interop through `EXTERNAL` procedures for TLS -- one
narrow, stable procedure boundary to OpenSSL, not a code generator or a
vendored FFI toolchain.

Toolchain bootstrap and this transport boundary are proven from inside a real
Docker build in `Dockerfile`'s `toolchain-check` stage: a real TCP connection
through Modula-3's own standard library, and a real TLS 1.2+ handshake with
both certificate and hostname verification against the approved hosted
deployment, plus a negative control proving a mismatched hostname is
correctly rejected.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Not yet earned | Client implementation in progress. |
| Live | Not yet earned | Client implementation in progress. |

## Docker verification so far

```sh
docker build --platform linux/amd64 --target toolchain-check -f modula-3/Dockerfile -t modula3-gate-check modula-3
```

Bootstraps CM3 from the pinned `d5.12.0` release (commit
`635568bf541f268dc06938f3ff90ae8167544190`), verifies the bootstrap
tarball's checksum, self-hosts the compiler and the `core`+`tcp` package
set, then builds and runs a small build-time program proving the toolchain
can reach a real TCP peer through the standard library and a real,
certificate-and-hostname-verified TLS peer through the `EXTERNAL`-procedure
shim -- both against the approved hosted deployment.
