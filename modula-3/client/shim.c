/*
 * shim.c - the only native code in the Modula-3 Convex client's transport.
 *
 * Modula-3's standard library (TCP.i3, IP.i3, in the "tcp" package) opens
 * the plain TCP connection and hands back a POSIX file descriptor
 * (TCPPosix.Public.fd). This file supplies exactly the one thing the
 * standard library does not: TLS, via a real TLS 1.2+ handshake over
 * that same fd, using OpenSSL directly through CM3's EXTERNAL procedure
 * mechanism -- no code generator, no vendored FFI tooling, just C
 * functions named to match TlsShim.i3's <*EXTERNAL*> declarations.
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
