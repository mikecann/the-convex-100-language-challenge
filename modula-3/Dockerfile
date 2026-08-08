# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG BUILD_IMAGE=ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea
# modula3/cm3 tag d5.12.0, pinned by commit rather than by the mutable tag.
ARG CM3_COMMIT=635568bf541f268dc06938f3ff90ae8167544190
ARG CM3_BOOT_URL=https://github.com/modula3/cm3/releases/download/d5.12.0/cm3-boot-AMD64_LINUX-d5.12.0.tar.xz
ARG CM3_BOOT_SHA256=a9c672958a29656856038b074addaa109c082f0bc2c7de3e3b98fd53d1bd636b

# ---------------------------------------------------------------------------
# toolchain: bootstrap CM3 (Critical Mass Modula-3), the actively maintained
# implementation, from source. CM3 does not ship prebuilt native binaries for
# every release; instead each release publishes a "boot" tarball containing
# the compiler's own sources already translated to C (by an earlier CM3),
# which any C++ compiler can build into a working bootstrap `cm3`. That
# bootstrap compiler is then used to compile the real CM3 front end, back
# end, and support libraries from Modula-3 source -- an ordinary, documented
# self-hosting step (scripts/concierge.py), not a hand-rolled workaround.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ${BUILD_IMAGE} AS toolchain
ARG CM3_COMMIT
ARG CM3_BOOT_URL
ARG CM3_BOOT_SHA256
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       git ca-certificates curl xz-utils cmake python3 build-essential \
       libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN git clone -q https://github.com/modula3/cm3.git /work/cm3 \
    && cd /work/cm3 && git checkout -q "${CM3_COMMIT}"
WORKDIR /work/cm3
RUN curl -fsSL -o /tmp/cm3-boot.tar.xz "${CM3_BOOT_URL}" \
    && echo "${CM3_BOOT_SHA256}  /tmp/cm3-boot.tar.xz" | sha256sum -c - \
    && tar -xf /tmp/cm3-boot.tar.xz \
    && rm /tmp/cm3-boot.tar.xz

# concierge.py's "install" command builds the C-translated bootstrap
# sources above with cmake, then uses that fresh compiler to self-host:
# rebuild cm3 itself, plus exactly the "core" package set (front end, back
# end, m3core/libm3 support libraries) and "tcp" (the stdlib TCP/IP socket
# interfaces this client's plain transport uses) from real Modula-3
# source. This is explicitly narrower than the "headless" default package
# set: that superset also pulls in m3tk-misc, an unrelated CM3 IDE-toolkit
# package whose 2016-era `qsort` C declaration conflicts with GCC 13's
# <stdlib.h> -- a broken build surface this headless network client never
# needs in the first place.
RUN python3 scripts/concierge.py install --prefix /opt/cm3 core tcp
ENV PATH=/opt/cm3/bin:$PATH

# ---------------------------------------------------------------------------
# toolchain-check: the roster feasibility gate for this slot, proved from
# inside the built container rather than merely asserted. Oz (this slot's
# predecessor) reached a real socket but its TLS path required rebuilding
# 2016-era vendored LLVM/AST-dump tooling that turned out to have a genuine,
# reproducible memory-safety bug (see INFEASIBLE.md). Modula-3's whole
# advantage here is that it needs none of that: plain sockets come from the
# standard library, and TLS is one narrow, stable EXTERNAL-procedure
# boundary to OpenSSL. This stage proves both halves against the real
# approved hosted deployment, plus a negative control proving hostname
# verification is not a no-op.
# ---------------------------------------------------------------------------
FROM toolchain AS toolchain-check
WORKDIR /work/gate
COPY <<'EOF' TlsShim.i3
(* TlsShim - the only native code in the Modula-3 Convex client's
   transport. Modula-3's standard TCP/IP interfaces (TCP.i3, IP.i3) supply
   the plain socket; this narrow EXTERNAL boundary supplies exactly and
   only what the standard library does not: a TLS handshake with
   certificate AND hostname verification, layered over the file
   descriptor TCP already opened. *)
UNSAFE INTERFACE TlsShim;
FROM Ctypes IMPORT int, char_star;

(* Perform a TLS client handshake over an already-connected POSIX file
   descriptor "fd", verifying the peer certificate chain against the
   system trust store and the presented hostname "host" (a NUL-terminated
   C string). Returns an opaque handle on success, or NIL if the
   handshake or verification failed. *)
<*EXTERNAL "TlsShim__connect"*>
PROCEDURE Connect(fd: int; host: char_star): ADDRESS;

(* Read up to "len" bytes into "buf", waiting at most "timeoutMs"
   milliseconds for data to become available. Returns the number of
   bytes read (0 on a clean TLS close), -1 on timeout, -2 on error. *)
<*EXTERNAL "TlsShim__read"*>
PROCEDURE Read(h: ADDRESS; buf: ADDRESS; len: int; timeoutMs: int): int;

(* Write exactly "len" bytes from "buf". Returns the number of bytes
   written, or -2 on error. *)
<*EXTERNAL "TlsShim__write"*>
PROCEDURE Write(h: ADDRESS; buf: ADDRESS; len: int): int;

(* Close the TLS session and the underlying file descriptor. *)
<*EXTERNAL "TlsShim__close"*>
PROCEDURE Close(h: ADDRESS);

END TlsShim.
EOF
COPY <<'EOF' shim.c
/*
 * shim.c - the only native code in the Modula-3 Convex client's transport.
 *
 * Modula-3's standard library (TCP.i3, IP.i3, in the "tcp" package) opens
 * the plain TCP connection and hands back a POSIX file descriptor
 * (TCPPosix.Public.fd). This file supplies exactly the one thing the
 * standard library does not: TLS, via a real TLS 1.2+ handshake over
 * that same fd, using OpenSSL directly through CM3's EXTERNAL procedure
 * mechanism -- no code generator, no vendored FFI tooling, just C
 * functions named to match TlsShim.i3's EXTERNAL declarations.
 */

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>
#include <poll.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>

typedef struct {
  SSL_CTX *ctx;
  SSL *ssl;
  int fd;
} tls_handle;

void *TlsShim__connect(int fd, const char *host) {
  tls_handle *h = calloc(1, sizeof(tls_handle));
  if (!h) return NULL;

  h->fd = fd;
  h->ctx = SSL_CTX_new(TLS_client_method());
  if (!h->ctx) { free(h); return NULL; }

  SSL_CTX_set_min_proto_version(h->ctx, TLS1_2_VERSION);
  SSL_CTX_set_verify(h->ctx, SSL_VERIFY_PEER, NULL);
  if (!SSL_CTX_set_default_verify_paths(h->ctx)) {
    SSL_CTX_free(h->ctx);
    free(h);
    return NULL;
  }

  h->ssl = SSL_new(h->ctx);
  if (!h->ssl) { SSL_CTX_free(h->ctx); free(h); return NULL; }

  SSL_set_fd(h->ssl, fd);
  /* SNI: tell the server which hostname we want a certificate for. */
  SSL_set_tlsext_host_name(h->ssl, host);
  /* Hostname verification: X509_check_host against this name is folded
     into the standard chain verification once the target host is set. */
  SSL_set1_host(h->ssl, host);
  SSL_set_hostflags(h->ssl, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);

  /* CM3's own socket() calls leave the descriptor non-blocking (its
     runtime multiplexes M3 threads over a handful of OS threads), so
     SSL_connect must be retried across WANT_READ/WANT_WRITE exactly
     like the read/write paths below, not called once as if blocking. */
  for (;;) {
    int rc = SSL_connect(h->ssl);
    if (rc == 1) break;
    int err = SSL_get_error(h->ssl, rc);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
      struct pollfd pfd;
      pfd.fd = h->fd;
      pfd.events = (err == SSL_ERROR_WANT_WRITE) ? POLLOUT : POLLIN;
      pfd.revents = 0;
      int pr = poll(&pfd, 1, 15000);
      if (pr > 0) continue;
      fprintf(stderr, "tls: handshake timed out waiting for socket readiness\n");
    } else {
      fprintf(stderr, "tls: handshake failed (SSL error %d)\n", err);
      ERR_print_errors_fp(stderr);
    }
    SSL_free(h->ssl);
    SSL_CTX_free(h->ctx);
    free(h);
    return NULL;
  }

  long vr = SSL_get_verify_result(h->ssl);
  if (vr != X509_V_OK) {
    fprintf(stderr, "tls: certificate/hostname verification failed: %s\n",
            X509_verify_cert_error_string(vr));
    SSL_shutdown(h->ssl);
    SSL_free(h->ssl);
    SSL_CTX_free(h->ctx);
    free(h);
    return NULL;
  }

  return h;
}

int TlsShim__read(void *handle, void *buf, int len, int timeoutMs) {
  tls_handle *h = (tls_handle *)handle;
  for (;;) {
    int n = SSL_read(h->ssl, buf, len);
    if (n > 0) return n;

    int err = SSL_get_error(h->ssl, n);
    if (err == SSL_ERROR_ZERO_RETURN) return 0;
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
      struct pollfd pfd;
      pfd.fd = h->fd;
      pfd.events = (err == SSL_ERROR_WANT_WRITE) ? POLLOUT : POLLIN;
      pfd.revents = 0;
      int pr = poll(&pfd, 1, timeoutMs);
      if (pr == 0) return -1;   /* timeout */
      if (pr < 0) return -2;    /* poll error */
      continue;                 /* readiness changed, retry SSL_read */
    }
    return -2;
  }
}

int TlsShim__write(void *handle, const void *buf, int len) {
  tls_handle *h = (tls_handle *)handle;
  int written = 0;
  const char *p = (const char *)buf;
  while (written < len) {
    int n = SSL_write(h->ssl, p + written, len - written);
    if (n > 0) { written += n; continue; }

    int err = SSL_get_error(h->ssl, n);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
      struct pollfd pfd;
      pfd.fd = h->fd;
      pfd.events = (err == SSL_ERROR_WANT_READ) ? POLLIN : POLLOUT;
      pfd.revents = 0;
      if (poll(&pfd, 1, -1) < 0) return -2;
      continue;
    }
    return -2;
  }
  return written;
}

void TlsShim__close(void *handle) {
  tls_handle *h = (tls_handle *)handle;
  if (!h) return;
  if (h->ssl) {
    SSL_shutdown(h->ssl);
    SSL_free(h->ssl);
  }
  if (h->ctx) SSL_CTX_free(h->ctx);
  if (h->fd >= 0) close(h->fd);
  free(h);
}
EOF
COPY <<'EOF' GateCheck.m3
(* GateCheck - build-time proof that this toolchain can reach a real
   network peer two ways: a plain TCP connection through Modula-3's own
   standard-library TCP/IP interfaces (the "tcp" package: TCP.i3, IP.i3,
   DEC SRC heritage), and a TLS 1.2+ handshake with full certificate AND
   hostname verification through the narrow OpenSSL EXTERNAL-procedure
   shim in TlsShim.i3/shim.c. It also proves the hostname check is real
   by connecting to a host whose certificate does not match and
   confirming that handshake is rejected, not silently accepted.

   This is scaffolding for the roster's feasibility gate, not part of
   the client library -- the real client (under client/Convex) is built
   on top of the same two primitives afterward. *)
UNSAFE MODULE GateCheck EXPORTS Main;
IMPORT IO, IP, TCP, TCPPosix, TlsShim, Thread, M3toC, Process;

VAR failures: INTEGER := 0;

PROCEDURE Fail(msg: TEXT) =
  BEGIN
    IO.Put("FAIL: " & msg & "\n");
    INC(failures);
  END Fail;

(* Resolve "host" and open a plain TCP connection to it on "port" using
   only Modula-3's standard TCP/IP interfaces -- no C shim involved. *)
PROCEDURE PlainConnect(host: TEXT; port: IP.Port): TCP.T RAISES {IP.Error, Thread.Alerted} =
  VAR addr: IP.Address;
  BEGIN
    IF NOT IP.GetHostByName(host, addr) THEN
      Fail("DNS lookup failed for " & host);
      RETURN NIL;
    END;
    RETURN TCP.Connect(IP.Endpoint{addr := addr, port := port});
  END PlainConnect;

(* Step 1: a real TCP connection via the stdlib Net/socket interface. *)
PROCEDURE CheckPlainTcp() =
  VAR conn: TCP.T;
  BEGIN
    TRY
      conn := PlainConnect("usable-reindeer-44.convex.cloud", 443);
      IF conn # NIL THEN
        IO.Put("PASS: stdlib TCP.Connect reached usable-reindeer-44.convex.cloud:443\n");
        TCP.Close(conn);
      END;
    EXCEPT
    | IP.Error(ec) => Fail("IP.Error during plain TCP connect");
    | Thread.Alerted => Fail("alerted during plain TCP connect");
    END;
  END CheckPlainTcp;

(* Step 2: layer a real TLS handshake (cert + hostname verified) over a
   plain connection's file descriptor, through the EXTERNAL shim. *)
PROCEDURE CheckTls(host: TEXT; expectSuccess: BOOLEAN) =
  VAR
    conn: TCP.T;
    pub: TCPPosix.Public;
    h: ADDRESS;
    hostC := M3toC.CopyTtoS(host);
  BEGIN
    TRY
      conn := PlainConnect(host, 443);
      IF conn = NIL THEN RETURN; END;
      pub := conn;
      h := TlsShim.Connect(pub.fd, hostC);
      IF h = NIL THEN
        IF expectSuccess THEN
          Fail("TLS handshake/verification failed for " & host);
        ELSE
          IO.Put("PASS: TLS correctly rejected " & host & " (hostname mismatch)\n");
        END;
      ELSE
        IF expectSuccess THEN
          IO.Put("PASS: TLS handshake + cert/hostname verification succeeded for " & host & "\n");
        ELSE
          Fail("TLS incorrectly ACCEPTED " & host & " -- hostname verification is not real");
        END;
        TlsShim.Close(h);
      END;
    EXCEPT
    | IP.Error(ec) => Fail("IP.Error during TLS connect to " & host);
    | Thread.Alerted => Fail("alerted during TLS connect to " & host);
    END;
    M3toC.FreeCopiedS(hostC);
  END CheckTls;

BEGIN
  CheckPlainTcp();
  CheckTls("usable-reindeer-44.convex.cloud", TRUE);
  (* wrong.host.badssl.com serves a certificate for a different name, so
     hostname verification must reject it, proving the check is real. *)
  CheckTls("wrong.host.badssl.com", FALSE);

  IF failures = 0 THEN
    IO.Put("GATE: all checks passed\n");
    Process.Exit(0);
  ELSE
    IO.Put("GATE: one or more checks failed\n");
    Process.Exit(1);
  END;
END GateCheck.
EOF
COPY <<'EOF' m3makefile
import("libm3")
import("tcp")
interface("TlsShim")
c_source("shim")
import_lib("ssl", "/usr/lib/x86_64-linux-gnu")
import_lib("crypto", "/usr/lib/x86_64-linux-gnu")
implementation("GateCheck")
program("gatecheck")
EOF
RUN cm3 -build && ./AMD64_LINUX/gatecheck

# ---------------------------------------------------------------------------
# test: compile the whole client library on its own, then compile and run
# every language-local unit test against it. WebsocketTest exercises
# ConvexWebSocket's pure framing logic directly (masking, the RFC 6455
# worked Sec-WebSocket-Accept example, every length encoding TryParseFrame
# understands, rejection of a masked "server" frame) with no network at
# all. LiveTest exercises the behaviour that only shows up once frames
# travel through a real socket and ConvexLive's own frame-draining loop --
# fragmentation reassembly, a Ping answered correctly while a message is
# only half-reassembled, UTF-8 validated once a message is fully
# reassembled (both a valid codepoint split across the frame boundary and
# an invalid one), and a deliberately wrong Sec-WebSocket-Accept being
# rejected before any application data is trusted -- against WsFixture, a
# scripted, one-shot loopback WebSocket server that exists only to hold
# each scenario's wire still long enough to observe the client's reaction.
# ---------------------------------------------------------------------------
FROM toolchain AS test
WORKDIR /work
COPY client ./client

# The whole-client compilation gate: cm3 -build here type-checks and
# compiles every interface and implementation across all 15 modules on
# its own, independent of any one test or example program's narrower
# reachability graph.
RUN cd client && cm3 -build

# Every language-local test binary below links the same client modules,
# copied flat into its own build directory (cm3's non-package "-build"
# mode resolves units from the current directory) alongside its own
# Main-exporting test module.
RUN set -eu; \
    for d in websockettest wsfixture livetest; do \
      mkdir -p "/work/bin/$d"; \
      cp client/*.i3 client/*.m3 client/*.c "/work/bin/$d/"; \
    done; \
    cp client/tests/WebsocketTest.m3 /work/bin/websockettest/; \
    cp client/tests/WsFixture.m3 /work/bin/wsfixture/; \
    cp client/tests/LiveTest.m3 /work/bin/livetest/

COPY <<'EOF' /work/bin/websockettest/m3makefile
import("libm3")
import("tcp")
interface("TlsShim")
c_source("shim")
import_lib("ssl", "/usr/lib/x86_64-linux-gnu")
import_lib("crypto", "/usr/lib/x86_64-linux-gnu")
interface("ConvexJson") implementation("ConvexJson")
interface("ConvexUrl") implementation("ConvexUrl")
interface("ConvexTransport") implementation("ConvexTransport")
interface("ConvexWire") implementation("ConvexWire")
interface("ConvexHttp") implementation("ConvexHttp")
interface("ConvexBase64") implementation("ConvexBase64")
interface("ConvexSha1") implementation("ConvexSha1")
interface("ConvexRandom") implementation("ConvexRandom")
interface("ConvexUtf8") implementation("ConvexUtf8")
interface("ConvexWebSocket") implementation("ConvexWebSocket")
interface("ConvexLive") implementation("ConvexLive")
implementation("WebsocketTest")
program("websockettest")
EOF

COPY <<'EOF' /work/bin/wsfixture/m3makefile
import("libm3")
import("tcp")
interface("TlsShim")
c_source("shim")
import_lib("ssl", "/usr/lib/x86_64-linux-gnu")
import_lib("crypto", "/usr/lib/x86_64-linux-gnu")
interface("ConvexJson") implementation("ConvexJson")
interface("ConvexUrl") implementation("ConvexUrl")
interface("ConvexTransport") implementation("ConvexTransport")
interface("ConvexWire") implementation("ConvexWire")
interface("ConvexHttp") implementation("ConvexHttp")
interface("ConvexBase64") implementation("ConvexBase64")
interface("ConvexSha1") implementation("ConvexSha1")
interface("ConvexRandom") implementation("ConvexRandom")
interface("ConvexUtf8") implementation("ConvexUtf8")
interface("ConvexWebSocket") implementation("ConvexWebSocket")
interface("ConvexLive") implementation("ConvexLive")
implementation("WsFixture")
program("wsfixture")
EOF

COPY <<'EOF' /work/bin/livetest/m3makefile
import("libm3")
import("tcp")
interface("TlsShim")
c_source("shim")
import_lib("ssl", "/usr/lib/x86_64-linux-gnu")
import_lib("crypto", "/usr/lib/x86_64-linux-gnu")
interface("ConvexJson") implementation("ConvexJson")
interface("ConvexUrl") implementation("ConvexUrl")
interface("ConvexTransport") implementation("ConvexTransport")
interface("ConvexWire") implementation("ConvexWire")
interface("ConvexHttp") implementation("ConvexHttp")
interface("ConvexBase64") implementation("ConvexBase64")
interface("ConvexSha1") implementation("ConvexSha1")
interface("ConvexRandom") implementation("ConvexRandom")
interface("ConvexUtf8") implementation("ConvexUtf8")
interface("ConvexWebSocket") implementation("ConvexWebSocket")
interface("ConvexLive") implementation("ConvexLive")
implementation("LiveTest")
program("livetest")
EOF

RUN cd /work/bin/websockettest && cm3 -build \
    && ./AMD64_LINUX/websockettest | tee /tmp/websockettest.out \
    && grep -Fq 'PASS WebsocketTest' /tmp/websockettest.out \
    && ! grep -Fq 'FAIL:' /tmp/websockettest.out

RUN cd /work/bin/wsfixture && cm3 -build
RUN cd /work/bin/livetest && cm3 -build

RUN <<'EOF'
set -u
overall=0
for entry in happy:44321 wrongaccept:44322 invalidutf8:44323; do
  s="${entry%%:*}"
  p="${entry##*:}"
  echo "=== LiveTest/WsFixture scenario: $s (port $p) ==="
  /work/bin/wsfixture/AMD64_LINUX/wsfixture "$s" "$p" > "/tmp/fixture-$s.log" 2>&1 &
  fpid=$!
  sleep 1
  /work/bin/livetest/AMD64_LINUX/livetest "$s" "$p" > "/tmp/livetest-$s.log" 2>&1
  lstatus=$?
  wait "$fpid"
  fstatus=$?
  echo "--- fixture ($s) output ---"
  cat "/tmp/fixture-$s.log"
  echo "--- livetest ($s) output ---"
  cat "/tmp/livetest-$s.log"
  if [ "$lstatus" -ne 0 ]; then echo "livetest $s exited $lstatus" >&2; overall=1; fi
  if [ "$fstatus" -ne 0 ]; then echo "wsfixture $s exited $fstatus" >&2; overall=1; fi
  if ! grep -Fq "PASS LiveTest $s" "/tmp/livetest-$s.log"; then echo "livetest $s missing its PASS line" >&2; overall=1; fi
  if grep -Fq "FAIL:" "/tmp/livetest-$s.log"; then echo "livetest $s reported at least one FAIL line" >&2; overall=1; fi
done
if [ "$overall" -ne 0 ]; then
  echo "one or more LiveTest/WsFixture scenarios failed" >&2
  exit 1
fi
echo "PASS all LiveTest/WsFixture scenarios"
EOF
