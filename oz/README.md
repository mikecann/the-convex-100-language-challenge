# Oz

This language client is planned as roster entry 52.

No implementation exists and no capabilities have been earned.

- Selection tier: `ranked`
- Implementation status: `planned`
- Earned capabilities: none

`Open.socket` is a native Oz class for real TCP sockets, documented since
Mozart 1.4. The prebuilt Mozart 2.0.1 `.deb` release (BSD licence) installs
unattended but ships no `oztool`/headers, so the C++ FFI needed for TLS
requires building Mozart 2 from source instead; a from-source build
(`cmake` + the bundled Boost 1.74 on Debian bookworm) completed successfully
in a Docker container during this session's feasibility pass, but the
socket-and-TLS proof itself was not completed inside the time budget. The
toolchain build succeeding is recorded here as a genuine, positive data
point for whoever picks this up next -- it is not a completed feasibility
gate.
