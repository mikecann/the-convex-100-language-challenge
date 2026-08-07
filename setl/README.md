# SETL

This language client is planned as roster entry 45.

No implementation exists and no capabilities have been earned.

- Selection tier: `ranked`
- Implementation status: `planned`
- Earned capabilities: none

A real TCP connect, TLS handshake, and HTTP round trip from SETL source were
already proven feasible: GNU SETL 8.13.22 builds unattended from source
(`./configure && make install-bin`, GPL), `open(f, "tcp-client")` opens a real
socket natively, and `callout` -- SETL2's fixed-signature C dispatcher, which
GNU SETL ships as an overridable stub in `src/run/callskel.c` -- reaches a
real OpenSSL TLS handshake once that stub is replaced with a small reviewed
dispatcher and the interpreter is relinked against `-lssl -lcrypto`.
