# Convex from Verilog

This directory is a work in progress toward a Convex client written as a
simulated hardware circuit in Verilog, run under Icarus Verilog (`iverilog`).

This is educational and unofficial. It is not a production Convex SDK, and
it is not published as a package.

## Status

Only the toolchain gate exists so far: proof, inside Docker on the pinned
toolchain, that a Verilog program can drive a real TCP connection and a
real certificate- and hostname-verified TLS handshake through a small VPI
(Verilog Procedural Interface) C module. No Convex protocol code has been
written yet, so there is no canonical example, no conformance adapter, and
no capability is claimed.

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
| JSON codec | Not started |
| HTTP/1.1 request/response framing | Not started |
| Canonical `examples/basics` | Not started |
| RFC 6455 WebSocket framing | Not started |
| `/api/sync` Live protocol | Not started |
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

No `runtime` or `example-runtime` stage exists yet; there is nothing to run
outside the `test` stage until the client above the transport layer exists.

## Limitations and deferred work

- No JSON, HTTP, WebSocket or `/api/sync` code exists yet - only the
  foreign-boundary primitives and the clocked bus that owns them.
- The gate's TCP proof uses a hermetic Docker-local fixture server; only
  the TLS proof reaches the real Convex deployment, matching this
  project's policy against pointing arbitrary build-time network access at
  a real backend for anything but the TLS proof itself.
- `client/native.c` implements a deliberately small opcode subset so far
  (host accumulation, connect, close, byte write/flush, byte read,
  stdout/stderr write) - enough for this gate. Random bytes, environment
  lookup, readiness polling, stdin, and the adapter's `ADAPTER_LISTEN`
  listen/accept pair are not implemented yet and will be added, mirroring
  `vhdl/client/native.c`'s equivalent set, as the layers that need them are
  built.
