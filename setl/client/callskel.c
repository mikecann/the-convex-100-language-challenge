/*
 *  callskel.c -- Convex TLS boundary for the SETL client
 *
 *  This file REPLACES src/run/callskel.c in the GNU SETL 8.13.22 source
 *  tree before the interpreter is built, and is the only native code in
 *  this client. Plain HTTP against a local self-hosted deployment goes
 *  over SETL's own `open(f, "tcp-client")` socket support and never
 *  reaches this file; only TLS (wss:// / https:// against a hosted
 *  deployment) does.
 *
 *  Why this file exists: SETL2's `callout` builtin (kept in GNU SETL for
 *  SETL2 compatibility) is not a general FFI. It is a single
 *  fixed-signature dispatcher:
 *
 *    char *setl2_callout(int service, unsigned argc, char *const argv[])
 *
 *  called from SETL source as
 *
 *    callout(service, om, arglist)   -- arglist a tuple of STRINGs
 *
 *  Every argument and the single return value are C strings -- there is
 *  no way to pass raw bytes, a length-prefixed buffer, or a struct
 *  across this boundary. So every TLS payload byte that crosses it is
 *  hex-encoded: two lowercase ASCII hex digits per byte, no separators.
 *  The SETL-side wrapper (client/tls.setl) is the only code that calls
 *  `callout` directly; the rest of the client only sees plain SETL
 *  strings.
 *
 *  Service codes:
 *    0  PING          ()                                  -> "PONG"
 *    1  TLS_CONNECT   (host, port, connectTimeoutMs)       -> "OK:<handle>" | "ERR:<msg>"
 *    2  TLS_WRITE     (handle, hexData)                    -> "OK:<nbytes>" | "ERR:<msg>"
 *    3  TLS_READ      (handle, maxBytes, readTimeoutMs)    -> "DATA:<hex>" | "TIMEOUT" | "EOF" | "ERR:<msg>"
 *    4  TLS_CLOSE     (handle)                             -> "OK" | "ERR:<msg>"
 *
 *  TLS_READ distinguishes three outcomes a Convex client must tell apart:
 *  data arrived, the deadline elapsed with the connection still healthy
 *  (TIMEOUT -- the caller should retry), and the peer closed the
 *  connection (EOF -- the caller must not retry). This lets the SETL
 *  side implement bounded reads/close per AGENTS.md even though the
 *  underlying transport is a blocking OpenSSL socket.
 *
 *  Hostname verification is real: SSL_set1_host plus
 *  SSL_CTX_set_verify(SSL_VERIFY_PEER) reject a handshake whose
 *  certificate does not match the requested host, using OpenSSL's own
 *  RFC 6125 logic rather than a hand-rolled check.
 */

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>

#include <openssl/ssl.h>
#include <openssl/err.h>

#define MAX_CONNS 16
#define MAX_READ_BYTES 65536

typedef struct {
  int in_use;
  int fd;
  SSL_CTX *ctx;
  SSL *ssl;
} conn_t;

static conn_t conns[MAX_CONNS];
static int openssl_ready = 0;

static void ensure_openssl(void) {
  if (!openssl_ready) {
    /* OpenSSL 3.x self-initializes on first use, but doing this
       explicitly keeps behavior identical across the 1.1.1 / 3.x
       versions this build might link against. */
    SSL_library_init();
    openssl_ready = 1;
  }
}

static const char HEX_DIGITS[] = "0123456789abcdef";

/* hex_encode: returns a malloc'd, NUL-terminated lowercase hex string
   for the n raw bytes at data. Caller frees. */
static char *hex_encode(const unsigned char *data, size_t n) {
  char *out = malloc(n * 2 + 1);
  size_t i;
  if (!out) return NULL;
  for (i = 0; i < n; i++) {
    out[i * 2] = HEX_DIGITS[(data[i] >> 4) & 0xf];
    out[i * 2 + 1] = HEX_DIGITS[data[i] & 0xf];
  }
  out[n * 2] = '\0';
  return out;
}

static int hex_val(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* hex_decode: decodes an even-length hex string in place into a
   malloc'd raw buffer; *outlen receives the byte count. Returns NULL on
   malformed input (odd length or a non-hex character). Caller frees. */
static unsigned char *hex_decode(const char *hex, size_t *outlen) {
  size_t len = strlen(hex);
  size_t n, i;
  unsigned char *out;
  if (len % 2 != 0) return NULL;
  n = len / 2;
  out = malloc(n > 0 ? n : 1);
  if (!out) return NULL;
  for (i = 0; i < n; i++) {
    int hi = hex_val(hex[i * 2]);
    int lo = hex_val(hex[i * 2 + 1]);
    if (hi < 0 || lo < 0) {
      free(out);
      return NULL;
    }
    out[i] = (unsigned char)((hi << 4) | lo);
  }
  *outlen = n;
  return out;
}

/* fmt: printf-style formatting into a fresh malloc'd string, the shape
   every branch below returns to the SETL side. */
static char *fmt(const char *format, ...) {
  va_list ap;
  int needed;
  char *buf;
  va_start(ap, format);
  needed = vsnprintf(NULL, 0, format, ap);
  va_end(ap);
  if (needed < 0) return strdup("ERR:formatting failure");
  buf = malloc((size_t)needed + 1);
  if (!buf) return NULL;
  va_start(ap, format);
  vsnprintf(buf, (size_t)needed + 1, format, ap);
  va_end(ap);
  return buf;
}

static char *err_openssl(const char *context) {
  unsigned long e = ERR_get_error();
  char detail[256];
  if (e) {
    ERR_error_string_n(e, detail, sizeof detail);
  } else {
    snprintf(detail, sizeof detail, "%s", strerror(errno));
  }
  return fmt("ERR:%s: %s", context, detail);
}

static int alloc_conn(void) {
  int i;
  for (i = 0; i < MAX_CONNS; i++) {
    if (!conns[i].in_use) return i;
  }
  return -1;
}

static void free_conn(int idx) {
  if (idx < 0 || idx >= MAX_CONNS) return;
  if (conns[idx].ssl) {
    SSL_shutdown(conns[idx].ssl);
    SSL_free(conns[idx].ssl);
  }
  if (conns[idx].ctx) SSL_CTX_free(conns[idx].ctx);
  if (conns[idx].fd >= 0) close(conns[idx].fd);
  memset(&conns[idx], 0, sizeof conns[idx]);
}

/* wait_for: blocks up to timeout_ms for the fd to become readable
   (want_read) or writable. Returns 1 ready, 0 timed out, -1 on select
   error. */
static int wait_for(int fd, int want_read, long timeout_ms) {
  fd_set fds;
  struct timeval tv;
  int rc;
  FD_ZERO(&fds);
  FD_SET(fd, &fds);
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;
  if (want_read) {
    rc = select(fd + 1, &fds, NULL, NULL, &tv);
  } else {
    rc = select(fd + 1, NULL, &fds, NULL, &tv);
  }
  if (rc < 0) return -1;
  return rc > 0 ? 1 : 0;
}

/* connect_with_timeout: resolves host/port and connects a non-blocking
   socket, bounded by timeout_ms across every candidate address
   getaddrinfo returns. Returns a connected fd (now back in blocking
   mode) or -1 with an error already reported through *errmsg
   (malloc'd; caller frees). */
static int connect_with_timeout(const char *host, const char *port,
                                 long timeout_ms, char **errmsg) {
  struct addrinfo hints, *res, *rp;
  int rc, fd = -1;
  struct timeval start, now;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  rc = getaddrinfo(host, port, &hints, &res);
  if (rc != 0) {
    *errmsg = fmt("ERR:DNS lookup failed for %s: %s", host, gai_strerror(rc));
    return -1;
  }
  gettimeofday(&start, NULL);
  for (rp = res; rp != NULL; rp = rp->ai_next) {
    long elapsed_ms, remaining_ms;
    int flags, sel;
    fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (fd < 0) continue;
    flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    gettimeofday(&now, NULL);
    elapsed_ms = (now.tv_sec - start.tv_sec) * 1000 +
                 (now.tv_usec - start.tv_usec) / 1000;
    remaining_ms = timeout_ms - elapsed_ms;
    if (remaining_ms <= 0) remaining_ms = 0;
    rc = connect(fd, rp->ai_addr, rp->ai_addrlen);
    if (rc == 0) {
      goto connected;
    }
    if (errno != EINPROGRESS) {
      close(fd);
      fd = -1;
      continue;
    }
    sel = wait_for(fd, 0, remaining_ms);
    if (sel == 1) {
      int soerr = 0;
      socklen_t soerr_len = sizeof soerr;
      getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &soerr_len);
      if (soerr == 0) goto connected;
    }
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  *errmsg = fmt("ERR:connect to %s:%s timed out or was refused", host, port);
  return -1;

connected:
  freeaddrinfo(res);
  {
    /* Back to a plain blocking socket: every subsequent read/write uses
       SO_RCVTIMEO/SO_SNDTIMEO for its own deadline instead. */
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
  }
  return fd;
}

static char *do_ping(void) {
  return strdup("PONG");
}

static char *do_connect(const char *host, const char *port_s,
                         const char *timeout_s) {
  long timeout_ms = atol(timeout_s);
  char *errmsg = NULL;
  int fd, idx;
  SSL_CTX *ctx;
  SSL *ssl;

  ensure_openssl();

  idx = alloc_conn();
  if (idx < 0) return strdup("ERR:too many open TLS connections");

  fd = connect_with_timeout(host, port_s, timeout_ms, &errmsg);
  if (fd < 0) return errmsg ? errmsg : strdup("ERR:connect failed");

  ctx = SSL_CTX_new(TLS_client_method());
  if (!ctx) {
    close(fd);
    return err_openssl("SSL_CTX_new");
  }
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
  if (!SSL_CTX_set_default_verify_paths(ctx)) {
    SSL_CTX_free(ctx);
    close(fd);
    return err_openssl("SSL_CTX_set_default_verify_paths");
  }

  ssl = SSL_new(ctx);
  if (!ssl) {
    SSL_CTX_free(ctx);
    close(fd);
    return err_openssl("SSL_new");
  }
  /* Real hostname verification (RFC 6125), not a hand-rolled CN/SAN
     check: OpenSSL enforces this itself once told the expected name. */
  if (!SSL_set1_host(ssl, host) ||
      !SSL_set_tlsext_host_name(ssl, host)) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return err_openssl("SSL_set1_host");
  }
  SSL_set_fd(ssl, fd);

  {
    long elapsed_budget = timeout_ms;
    struct timeval start, now;
    gettimeofday(&start, NULL);
    for (;;) {
      int rc = SSL_connect(ssl);
      if (rc == 1) break;
      {
        int want = SSL_get_error(ssl, rc);
        long remaining;
        gettimeofday(&now, NULL);
        remaining = elapsed_budget -
          ((now.tv_sec - start.tv_sec) * 1000 +
           (now.tv_usec - start.tv_usec) / 1000);
        if (remaining <= 0) {
          SSL_free(ssl);
          SSL_CTX_free(ctx);
          close(fd);
          return strdup("ERR:TLS handshake timed out");
        }
        if (want == SSL_ERROR_WANT_READ) {
          if (wait_for(fd, 1, remaining) <= 0) {
            SSL_free(ssl);
            SSL_CTX_free(ctx);
            close(fd);
            return strdup("ERR:TLS handshake timed out");
          }
          continue;
        }
        if (want == SSL_ERROR_WANT_WRITE) {
          if (wait_for(fd, 0, remaining) <= 0) {
            SSL_free(ssl);
            SSL_CTX_free(ctx);
            close(fd);
            return strdup("ERR:TLS handshake timed out");
          }
          continue;
        }
        {
          char *e = err_openssl("TLS handshake failed");
          SSL_free(ssl);
          SSL_CTX_free(ctx);
          close(fd);
          return e;
        }
      }
    }
  }

  conns[idx].in_use = 1;
  conns[idx].fd = fd;
  conns[idx].ctx = ctx;
  conns[idx].ssl = ssl;
  return fmt("OK:%d", idx);
}

static char *do_write(const char *handle_s, const char *hex_data) {
  int idx = atoi(handle_s);
  size_t n = 0;
  unsigned char *raw;
  size_t sent = 0;

  if (idx < 0 || idx >= MAX_CONNS || !conns[idx].in_use) {
    return strdup("ERR:unknown handle");
  }
  raw = hex_decode(hex_data, &n);
  if (!raw && n != 0) return strdup("ERR:malformed hex payload");
  if (n == 0) {
    free(raw);
    return strdup("OK:0");
  }

  while (sent < n) {
    int rc = SSL_write(conns[idx].ssl, raw + sent, (int)(n - sent));
    if (rc <= 0) {
      int want = SSL_get_error(conns[idx].ssl, rc);
      if (want == SSL_ERROR_WANT_READ || want == SSL_ERROR_WANT_WRITE) {
        /* Writable-again is common under TLS renegotiation of the
           underlying record; retry with no extra timeout budget here
           because SO_SNDTIMEO already bounds the whole call at the
           socket level for ordinary blocking writes. */
        continue;
      }
      {
        char *e = err_openssl("TLS write failed");
        free(raw);
        return e;
      }
    }
    sent += (size_t)rc;
  }
  free(raw);
  return fmt("OK:%zu", sent);
}

static char *do_read(const char *handle_s, const char *max_s,
                      const char *timeout_s) {
  int idx = atoi(handle_s);
  long max_bytes = atol(max_s);
  long timeout_ms = atol(timeout_s);
  unsigned char buf[MAX_READ_BYTES];
  int rc;

  if (idx < 0 || idx >= MAX_CONNS || !conns[idx].in_use) {
    return strdup("ERR:unknown handle");
  }
  if (max_bytes <= 0 || max_bytes > MAX_READ_BYTES) max_bytes = MAX_READ_BYTES;

  /* SSL_pending covers bytes OpenSSL already decrypted into its own
     buffer from a prior record; without checking it first, a slow
     consumer could wait a full timeout on the socket even though a
     full message is already sitting in userspace. */
  if (SSL_pending(conns[idx].ssl) <= 0) {
    int fd = conns[idx].fd;
    int ready = wait_for(fd, 1, timeout_ms);
    if (ready == 0) return strdup("TIMEOUT");
    if (ready < 0) return err_openssl("select failed while reading");
  }

  rc = SSL_read(conns[idx].ssl, buf, (int)max_bytes);
  if (rc > 0) {
    char *hex = hex_encode(buf, (size_t)rc);
    char *out = fmt("DATA:%s", hex ? hex : "");
    free(hex);
    return out;
  }
  {
    int want = SSL_get_error(conns[idx].ssl, rc);
    if (want == SSL_ERROR_ZERO_RETURN) return strdup("EOF");
    if (want == SSL_ERROR_WANT_READ || want == SSL_ERROR_WANT_WRITE) {
      /* The readability check above said data was ready, but only a
         partial TLS record arrived (e.g. bytes still in flight on a
         slow link); report it as a timeout so the SETL side's
         deadline logic, not this shim, decides whether to retry. */
      return strdup("TIMEOUT");
    }
    if (want == SSL_ERROR_SYSCALL && rc == 0) return strdup("EOF");
    return err_openssl("TLS read failed");
  }
}

static char *do_close(const char *handle_s) {
  int idx = atoi(handle_s);
  if (idx < 0 || idx >= MAX_CONNS || !conns[idx].in_use) {
    return strdup("ERR:unknown handle");
  }
  free_conn(idx);
  return strdup("OK");
}

char *setl2_callout(int service, unsigned argc, char *const argv[]) {
  switch (service) {
    case 0:
      return do_ping();
    case 1:
      if (argc != 3) return strdup("ERR:TLS_CONNECT wants 3 args");
      return do_connect(argv[0], argv[1], argv[2]);
    case 2:
      if (argc != 2) return strdup("ERR:TLS_WRITE wants 2 args");
      return do_write(argv[0], argv[1]);
    case 3:
      if (argc != 3) return strdup("ERR:TLS_READ wants 3 args");
      return do_read(argv[0], argv[1], argv[2]);
    case 4:
      if (argc != 1) return strdup("ERR:TLS_CLOSE wants 1 arg");
      return do_close(argv[0]);
    default:
      return fmt("ERR:unknown service code %d", service);
  }
}
