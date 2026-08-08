# VHDL

This language client is planned as roster entry 41.

No implementation exists and no capabilities have been earned.

- Selection tier: `ranked`
- Implementation status: `planned`
- Earned capabilities: none

A real TCP connect, TLS handshake, and HTTP round trip from VHDL source were
already proven feasible: GHDL 2.0.0's LLVM backend (`apt install ghdl-llvm`,
GPL) compiles a VHDL design straight to a standalone native executable, and
VHPIDIRECT lets a `process` call a small foreign C boundary (POSIX sockets,
OpenSSL) exactly the way this project's other compile-to-C native clients do.
The interesting part still to build: a Convex client expressed as a
*simulated circuit* -- processes, signals and a clock -- rather than VHDL used
procedurally with `wait` statements sprinkled in.
