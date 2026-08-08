# Convex from VHDL

This is an attempt at a Convex client written in VHDL, expressed as a
*simulated circuit* -- processes, signals and a clock -- rather than VHDL
used procedurally with `wait` statements sprinkled through it.

This is an educational, unofficial demonstration. It is not a production
Convex SDK, and it does not run against real hardware; GHDL compiles the
design to a standalone native executable that simulates the circuit.

## Status: under construction, no capabilities earned yet

This roster entry is still marked `planned` in `manifest.yaml`: this
project's own validator treats any other status as a claim that the full
client skeleton (`examples/basics`, `client/tests/conformance`, an
adapter) exists, which it does not yet.

- Selection tier: `ranked`
- Implementation status: `planned`
- Earned capabilities: none

Nothing here is a canonical example or a client library yet. What exists,
and what is proven inside Docker on the pinned toolchain rather than merely
asserted:

- `client/native.c` -- the entire foreign side. Standard VHDL has no
  sockets, no TLS, no monotonic clock, no entropy source, no environment
  access and no process exit status; this file supplies exactly those, as
  two VHPIDIRECT-callable C functions and nothing else. Every byte of
  protocol text, and every deadline and retry, stays in VHDL.
- `client/convex_native.vhdl` -- the clocked request/acknowledge bus that
  connects VHDL to `native.c`, and the two VHPIDIRECT function
  declarations themselves.
- `client/convex_transport.vhdl` -- the circuit's two always-running
  processes: a free-running clock, and the transport process that is the
  sole owner of the foreign boundary.
- `client/convex_buffer.vhdl` -- fixed-capacity byte buffers, decimal,
  base64 and hex helpers, since VHDL has no heap and no dynamically
  growing array.
- `client/tests/buffer_test.vhdl` and `client/tests/transport_smoke.vhdl`
  -- unit coverage for the buffer helpers, and an end-to-end proof that the
  request/acknowledge bus really elaborates and really drives a
  certificate- and hostname-verified TLS handshake through `native.c` and
  OpenSSL.

Missing, in build order: `convex_json`, `convex_http`, `convex_ws`,
`convex_sync`, the conformance adapter, and `examples/basics`. Until those
exist there is no canonical example to show here and no conformance
executable to verify.

## The GHDL driver-rule finding

GHDL requires an unresolved signal's complete set of drivers to come from
one process, or one procedure-call chain rooted in one process. Two
different processes may each drive a *different* field of the same record
signal, including fields of an unresolved type such as `integer` -- that
elaborates and runs fine. What GHDL forbids is two different processes
driving the *same* unresolved scalar; GHDL does not reject that at analysis
or elaboration-bind time, but the resulting executable fails at simulation
elaboration with `error: several sources for unresolved signal ... error
during elaboration` (exit 1). `client/convex_native.vhdl` splits the
request and acknowledge halves of the bus into two separate records for
exactly this reason: `xport_req` is driven only by the driver-side
`xport_call` procedure chain, and `xport_ack` is driven only by
`convex_transport`'s own process. `client/tests/transport_smoke.vhdl` is
the empirical proof that this split satisfies the rule end to end,
including a real TLS handshake.

## Docker verification

```sh
./run test vhdl
```

Builds `client/native.c` and every VHDL unit that exists so far with GHDL
2.0.0's LLVM code generator (`ghdl-llvm`, pinned Debian bookworm-slim),
checks the source style gate, and runs `buffer_test` and
`transport_smoke`. `transport_smoke` connects to a local `openssl
s_server` behind a private CA on `localhost:44300` rather than reaching
the live internet from inside a Docker build stage, so the certificate-
and hostname-verified TLS handshake it proves is hermetic and
reproducible.

There is no `runtime` or `example-runtime` stage yet, so `./run build`,
`./run verify-example`, `./run verify`, `./run verify-hosted` and `./run
verify-all` do not apply to this checkpoint.

## Limitations

- `convex_json`, `convex_http`, `convex_ws`, `convex_sync`, the
  conformance adapter, and `examples/basics` are not implemented. No HTTP
  or Live behaviour exists yet.
- Only the foundation described above has run in Docker. No shared or
  hosted black-box conformance has been attempted, so no capability is
  claimed and no badge is earned.
