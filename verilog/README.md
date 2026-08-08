# Convex from Verilog

This directory is a work in progress toward a Convex client written as a
simulated hardware circuit in Verilog, run under Icarus Verilog (`iverilog`).

This is educational and unofficial. It is not a production Convex SDK, and
it is not published as a package.

## Status

The toolchain gate and a JSON codec exist so far. The gate proves, inside
Docker on the pinned toolchain, that a Verilog program can drive a real
TCP connection and a real certificate- and hostname-verified TLS
handshake through a small VPI (Verilog Procedural Interface) C module.
`client/convex_buffer.v` adds a hand-written JSON encoder and decoder,
covering AGENTS.md's integral-decimal-number rule (`0.0`/`1.0` decode as
integers; fractional, quoted, non-finite and overflowing values are
rejected), proven with a language-local unit suite. No HTTP, WebSocket or
Convex-protocol code has been written yet, so there is no canonical
example, no conformance adapter, and no capability is claimed.

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
| JSON codec (encode, parse, integral-decimal rule) | Proven in Docker (`json_test`), language-local unit suite |
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
- The pinned `iverilog` does not support passing an unpacked array, a
  `ref` port, or even a dynamic `byte queue[$]`, into a task or function -
  confirmed directly against the toolchain rather than assumed. Every
  buffer in this client is therefore module state reached only through a
  hierarchical name, and `client/convex_buffer.v` combines byte storage
  with JSON parsing of its own content in one module rather than two
  separate packages the way `vhdl/` splits them.
- The same toolchain also expands a `\"` or a lone `\\` inside a
  SystemVerilog `string` literal into that escape's own four-character
  spelling instead of the single byte it should produce (`"a\"b".len()`
  reports 6, not 3) - documented in `client/convex_chars.vh`. Every
  string literal in this client that needs a literal quote or backslash
  spells it as an explicit byte constant instead.
- JSON string decoding does not combine a `\uD800`-`\uDBFF` /
  `\uDC00`-`\uDFFF` surrogate pair into one astral codepoint; it rejects
  the lone surrogate half instead. A Basic Multilingual Plane character
  (the overwhelming majority of real text, and everything Convex's own
  protocol control fields ever contain) decodes correctly; an emoji or
  rare CJK extension character in user data would not.
