/*
 * convexrt.c - the only native code in the Simula 67 Convex client.
 *
 * Standard Simula has no sockets, no TLS, no monotonic clock, no entropy
 * source, no environment access and no formal parameter type that could
 * hold any of those. This file offers exactly those primitives and nothing
 * else: open a TCP or TLS stream, adopt an inherited descriptor, read,
 * write, poll for readiness, listen, accept, close, read a monotonic
 * millisecond clock, fill a buffer with random bytes, copy a text literal's
 * bytes, read an environment variable, report the last error text and exit
 * with a status code.
 *
 * Everything a reviewer would call "the client" -- HTTP/1.1 framing, JSON
 * encoding and decoding, RFC 6455 WebSocket framing, the /api/sync state
 * machine and the NDJSON adapter protocol -- is written in Simula in the
 * files under client/. There is no HTTP, no WebSocket framing, no JSON and
 * no Convex protocol knowledge below this comment.
 *
 * Calling convention
 * -------------------
 * GNU Cim compiles a Simula `external C procedure` declaration straight to
 * an ordinary C function prototype with the C calling convention -- no
 * thunk, no dope vector. Confirmed by running `cim -S` on a throwaway probe
 * program and reading the C it generated, rather than assumed from the
 * manual:
 *
 *   - A by-value scalar (`integer`) parameter, and an `integer procedure`'s
 *     return value, are both a plain 64-bit C `long` -- Simula's `integer`
 *     is 64 bits under Cim, not 32, confirmed the same way. The C side of
 *     this file uses `long` throughout for exactly that reason; an `int`
 *     boundary here would silently misalign every `integer array` element,
 *     which is 8 bytes wide.
 *   - An `integer array` parameter arrives as `long *`, pointing at the
 *     array's first element -- Cim never passes a dope vector to external C
 *     code the way MARST's ALGOL 60 does.
 *   - A by-value `text` parameter arrives as a malloc'd, NUL-terminated
 *     `char *` that the callee must not free; this client uses that only
 *     for `cxtextbytes`, to copy a Simula text literal's bytes into an
 *     `integer array` buffer once, the same role GNU MARST's `cxstrbytes`
 *     plays in the ALGOL 60 client.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

/* Sentinels shared with the Simula side (see client/convex-buffer.sim's
   documentation of the transport return codes). */
#define CVX_AGAIN (-1) /* the stream is open but not ready yet */
#define CVX_ERROR (-2) /* the stream is unusable and must be closed */

/* A conformance run needs at most a listening socket, one controller
   stream, one Convex WebSocket, one HTTP stream and the two adopted
   standard streams. The fixed table keeps handle lifetime auditable and
   keeps every allocation off the transport path, matching the bound every
   other native client in this repository uses for the same table. */
#define CVX_MAX_HANDLES 8

typedef struct {
  int used;
  int fd;
  int owns_fd;    /* adopted standard streams must not be closed twice */
  SSL *ssl;
  SSL_CTX *ctx;
  int want_write; /* the last TLS operation asked for writability */
} cvx_handle;

static cvx_handle cvx_handles[CVX_MAX_HANDLES];
static char cvx_last_error[256] = "";
static int cvx_tls_ready = 0;

static void cvx_set_error(const char *what) {
  snprintf(cvx_last_error, sizeof(cvx_last_error), "%s", what);
}

static void cvx_set_errno(const char *what) {
  snprintf(cvx_last_error, sizeof(cvx_last_error), "%s: %s", what,
           strerror(errno));
}

static void cvx_set_ssl_error(const char *what) {
  unsigned long code = ERR_peek_last_error();
  if (code == 0) {
    cvx_set_errno(what);
    return;
  }
  snprintf(cvx_last_error, sizeof(cvx_last_error), "%s: %s", what,
           ERR_reason_error_string(code));
}

static cvx_handle *cvx_slot(long handle) {
  if (handle < 0 || handle >= CVX_MAX_HANDLES) return NULL;
  if (!cvx_handles[handle].used) return NULL;
  return &cvx_handles[handle];
}

static long cvx_alloc(void) {
  long index;
  for (index = 0; index < CVX_MAX_HANDLES; index++) {
    if (!cvx_handles[index].used) {
      memset(&cvx_handles[index], 0, sizeof(cvx_handle));
      cvx_handles[index].used = 1;
      cvx_handles[index].fd = -1;
      return index;
    }
  }
  cvx_set_error("no free transport handle");
  return CVX_ERROR;
}

static void cvx_release(cvx_handle *slot) {
  if (slot->ssl != NULL) SSL_free(slot->ssl);
  if (slot->ctx != NULL) SSL_CTX_free(slot->ctx);
  if (slot->fd >= 0 && slot->owns_fd) close(slot->fd);
  memset(slot, 0, sizeof(cvx_handle));
  slot->fd = -1;
}

static int cvx_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* CLOCK_MONOTONIC's epoch is unspecified (commonly boot time), so its raw
   value could already be close to a wraparound boundary on a long-uptime
   host. Rebasing to the value seen at this process's first call keeps every
   deadline this short-lived adapter or example process computes (now plus
   a budget) far from that boundary, matching every other native client in
   this repository. */
static long cvx_now_ms(void) {
  static long base = 0;
  static int have_base = 0;
  struct timespec now;
  long ms;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
  ms = (long)now.tv_sec * 1000L + (long)(now.tv_nsec / 1000000L);
  if (!have_base) {
    base = ms;
    have_base = 1;
  }
  return ms - base;
}

static int cvx_wait_fd(int fd, int for_write, long timeout_ms) {
  struct pollfd entry;
  entry.fd = fd;
  entry.events = (short)(for_write ? POLLOUT : POLLIN);
  entry.revents = 0;
  if (timeout_ms < 0) timeout_ms = 0;
  for (;;) {
    int ready = poll(&entry, 1, (int)timeout_ms);
    if (ready > 0) return 1;
    if (ready == 0) {
      cvx_set_error("transport timed out");
      return 0;
    }
    if (errno == EINTR) continue;
    cvx_set_errno("poll failed");
    return CVX_ERROR;
  }
}

static int cvx_connect_fd(const char *host, const char *port,
                           long deadline_ms) {
  struct addrinfo hints;
  struct addrinfo *list = NULL;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;

  int status = getaddrinfo(host, port, &hints, &list);
  if (status != 0) {
    cvx_set_error(gai_strerror(status));
    return CVX_ERROR;
  }

  int fd = -1;
  for (struct addrinfo *entry = list; entry != NULL; entry = entry->ai_next) {
    fd = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
    if (fd < 0) continue;
    if (cvx_nonblocking(fd) != 0) {
      close(fd);
      fd = -1;
      continue;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    if (connect(fd, entry->ai_addr, entry->ai_addrlen) == 0) break;
    if (errno == EINPROGRESS || errno == EINTR) {
      long remaining = deadline_ms - cvx_now_ms();
      if (cvx_wait_fd(fd, 1, remaining) == 1) {
        int error = 0;
        socklen_t size = sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 &&
            error == 0) {
          break;
        }
        errno = error;
      }
    }
    cvx_set_errno("connect failed");
    close(fd);
    fd = -1;
  }
  freeaddrinfo(list);
  if (fd < 0 && cvx_last_error[0] == '\0') cvx_set_error("connect failed");
  return fd < 0 ? CVX_ERROR : fd;
}

static int cvx_start_tls(cvx_handle *slot, const char *host,
                          long deadline_ms) {
  if (!cvx_tls_ready) {
    SSL_library_init();
    SSL_load_error_strings();
    cvx_tls_ready = 1;
  }

  slot->ctx = SSL_CTX_new(TLS_client_method());
  if (slot->ctx == NULL) {
    cvx_set_ssl_error("TLS context");
    return CVX_ERROR;
  }
  SSL_CTX_set_min_proto_version(slot->ctx, TLS1_2_VERSION);
  SSL_CTX_set_verify(slot->ctx, SSL_VERIFY_PEER, NULL);

  const char *bundle = getenv("SSL_CERT_FILE");
  if (bundle != NULL && bundle[0] != '\0') {
    if (SSL_CTX_load_verify_locations(slot->ctx, bundle, NULL) != 1) {
      cvx_set_ssl_error("CA bundle");
      return CVX_ERROR;
    }
  } else if (SSL_CTX_set_default_verify_paths(slot->ctx) != 1) {
    cvx_set_ssl_error("default CA paths");
    return CVX_ERROR;
  }

  slot->ssl = SSL_new(slot->ctx);
  if (slot->ssl == NULL) {
    cvx_set_ssl_error("TLS session");
    return CVX_ERROR;
  }
  SSL_set_fd(slot->ssl, slot->fd);
  SSL_set_tlsext_host_name(slot->ssl, host);
  SSL_set_hostflags(slot->ssl, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
  if (SSL_set1_host(slot->ssl, host) != 1) {
    cvx_set_ssl_error("TLS hostname");
    return CVX_ERROR;
  }

  for (;;) {
    int result = SSL_connect(slot->ssl);
    if (result == 1) return 0;
    int reason = SSL_get_error(slot->ssl, result);
    if (reason != SSL_ERROR_WANT_READ && reason != SSL_ERROR_WANT_WRITE) {
      long verified = SSL_get_verify_result(slot->ssl);
      if (verified != X509_V_OK) {
        cvx_set_error(X509_verify_cert_error_string(verified));
      } else {
        cvx_set_ssl_error("TLS handshake");
      }
      return CVX_ERROR;
    }
    long remaining = deadline_ms - cvx_now_ms();
    if (remaining <= 0) {
      cvx_set_error("TLS handshake timed out");
      return CVX_ERROR;
    }
    if (cvx_wait_fd(slot->fd, reason == SSL_ERROR_WANT_WRITE, remaining) !=
        1) {
      return CVX_ERROR;
    }
  }
}

/* Copies `length` bytes out of a Simula `integer array` (arriving here as
   `long *`, one byte value 0..255 per element) into a fresh NUL-terminated
   C string. Returns 0 on success, -1 if it will not fit `cap` bytes
   including the terminator. */
static int cvx_bytes_to_cstr(const long *array, long length, char *out,
                              int cap) {
  long i;
  if (length < 0 || length + 1 > cap) return -1;
  for (i = 0; i < length; i++) out[i] = (char)(array[i] & 0xFF);
  out[length] = '\0';
  return 0;
}

/* ------------------------------------------------------------------------
 * Exported primitives, one per `external C procedure` declaration in
 * client/convex-native.sim.
 * ---------------------------------------------------------------------- */

/* cxopen(host, hostlen, port, portlen, tls, deadlinems) : integer */
long cxopen(const long *host, long hostlen, const long *port, long portlen,
            long tls, long deadlinems) {
  char host_c[256];
  char port_c[32];
  long handle;
  cvx_handle *slot;
  int fd;

  if (cvx_bytes_to_cstr(host, hostlen, host_c, sizeof(host_c)) != 0) {
    cvx_set_error("host name too long");
    return CVX_ERROR;
  }
  if (cvx_bytes_to_cstr(port, portlen, port_c, sizeof(port_c)) != 0) {
    cvx_set_error("port too long");
    return CVX_ERROR;
  }

  handle = cvx_alloc();
  if (handle < 0) return handle;
  slot = &cvx_handles[handle];

  fd = cvx_connect_fd(host_c, port_c, deadlinems);
  if (fd < 0) {
    cvx_release(slot);
    return CVX_ERROR;
  }
  slot->fd = fd;
  slot->owns_fd = 1;

  if (tls != 0 && cvx_start_tls(slot, host_c, deadlinems) != 0) {
    cvx_release(slot);
    return CVX_ERROR;
  }
  return handle;
}

/* cxadopt(fd) : integer */
long cxadopt(long fd) {
  long handle = cvx_alloc();
  cvx_handle *slot;
  if (handle < 0) return handle;
  slot = &cvx_handles[handle];
  if (cvx_nonblocking((int)fd) != 0) {
    cvx_set_errno("non-blocking mode");
    cvx_release(slot);
    return CVX_ERROR;
  }
  slot->fd = (int)fd;
  slot->owns_fd = 0;
  return handle;
}

/* cxlisten(host, hostlen, port, portlen) : integer */
long cxlisten(const long *host, long hostlen, const long *port,
              long portlen) {
  char host_c[256];
  char port_c[32];
  struct addrinfo hints;
  struct addrinfo *list = NULL;
  int fd = -1;
  long handle;
  int status;

  if (cvx_bytes_to_cstr(host, hostlen, host_c, sizeof(host_c)) != 0) {
    cvx_set_error("host name too long");
    return CVX_ERROR;
  }
  if (cvx_bytes_to_cstr(port, portlen, port_c, sizeof(port_c)) != 0) {
    cvx_set_error("port too long");
    return CVX_ERROR;
  }

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_PASSIVE;

  status = getaddrinfo(host_c, port_c, &hints, &list);
  if (status != 0) {
    cvx_set_error(gai_strerror(status));
    return CVX_ERROR;
  }

  for (struct addrinfo *entry = list; entry != NULL; entry = entry->ai_next) {
    fd = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
    if (fd < 0) continue;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(fd, entry->ai_addr, entry->ai_addrlen) == 0 &&
        listen(fd, 4) == 0 && cvx_nonblocking(fd) == 0) {
      break;
    }
    cvx_set_errno("listen failed");
    close(fd);
    fd = -1;
  }
  freeaddrinfo(list);
  if (fd < 0) return CVX_ERROR;

  handle = cvx_alloc();
  if (handle < 0) {
    close(fd);
    return handle;
  }
  cvx_handles[handle].fd = fd;
  cvx_handles[handle].owns_fd = 1;
  return handle;
}

/* cxaccept(handle, timeoutms) : integer */
long cxaccept(long handle, long timeoutms) {
  cvx_handle *slot = cvx_slot(handle);
  int ready, fd;
  long accepted;
  if (slot == NULL) {
    cvx_set_error("accept on a closed handle");
    return CVX_ERROR;
  }
  ready = cvx_wait_fd(slot->fd, 0, timeoutms);
  if (ready != 1) return ready == 0 ? CVX_AGAIN : CVX_ERROR;

  fd = accept(slot->fd, NULL, NULL);
  if (fd < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return CVX_AGAIN;
    cvx_set_errno("accept failed");
    return CVX_ERROR;
  }
  if (cvx_nonblocking(fd) != 0) {
    cvx_set_errno("non-blocking mode");
    close(fd);
    return CVX_ERROR;
  }
  accepted = cvx_alloc();
  if (accepted < 0) {
    close(fd);
    return accepted;
  }
  cvx_handles[accepted].fd = fd;
  cvx_handles[accepted].owns_fd = 1;
  return accepted;
}

/* cxread(handle, buf, cap) : integer -- writes up to cap bytes into buf(0..) */
long cxread(long handle, long *buf, long cap) {
  cvx_handle *slot = cvx_slot(handle);
  unsigned char scratch[65536];
  long want, i, result;
  if (slot == NULL) {
    cvx_set_error("read on a closed handle");
    return CVX_ERROR;
  }
  if (cap <= 0) return 0;

  want = cap > (long)sizeof(scratch) ? (long)sizeof(scratch) : cap;

  if (slot->ssl != NULL) {
    int r = SSL_read(slot->ssl, scratch, (int)want);
    if (r > 0) {
      slot->want_write = 0;
      result = r;
    } else {
      int reason = SSL_get_error(slot->ssl, r);
      if (reason == SSL_ERROR_ZERO_RETURN) {
        result = 0;
      } else if (reason == SSL_ERROR_WANT_READ) {
        slot->want_write = 0;
        return CVX_AGAIN;
      } else if (reason == SSL_ERROR_WANT_WRITE) {
        slot->want_write = 1;
        return CVX_AGAIN;
      } else if (reason == SSL_ERROR_SYSCALL && ERR_peek_error() == 0 &&
                 errno == 0) {
        result = 0; /* peer closed without a TLS shutdown alert */
      } else {
        cvx_set_ssl_error("TLS read");
        return CVX_ERROR;
      }
    }
  } else {
    for (;;) {
      ssize_t r = read(slot->fd, scratch, (size_t)want);
      if (r >= 0) {
        result = r;
        break;
      }
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) return CVX_AGAIN;
      cvx_set_errno("read failed");
      return CVX_ERROR;
    }
  }
  for (i = 0; i < result; i++) buf[i] = scratch[i];
  return result;
}

/* cxwrite(handle, buf, offset, length) : integer */
long cxwrite(long handle, const long *buf, long offset, long length) {
  cvx_handle *slot = cvx_slot(handle);
  unsigned char scratch[65536];
  long want, i;
  if (slot == NULL) {
    cvx_set_error("write on a closed handle");
    return CVX_ERROR;
  }
  if (length <= 0) return 0;

  want = length > (long)sizeof(scratch) ? (long)sizeof(scratch) : length;
  for (i = 0; i < want; i++) scratch[i] = (unsigned char)(buf[offset + i] & 0xFF);

  if (slot->ssl != NULL) {
    int r = SSL_write(slot->ssl, scratch, (int)want);
    int reason;
    if (r > 0) {
      slot->want_write = 0;
      return r;
    }
    reason = SSL_get_error(slot->ssl, r);
    if (reason == SSL_ERROR_WANT_READ) {
      slot->want_write = 0;
      return CVX_AGAIN;
    }
    if (reason == SSL_ERROR_WANT_WRITE) {
      slot->want_write = 1;
      return CVX_AGAIN;
    }
    cvx_set_ssl_error("TLS write");
    return CVX_ERROR;
  }

  for (;;) {
    ssize_t r = write(slot->fd, scratch, (size_t)want);
    if (r >= 0) return (long)r;
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return CVX_AGAIN;
    cvx_set_errno("write failed");
    return CVX_ERROR;
  }
}

/* cxpoll(h0, w0, h1, w1, h2, w2, timeoutms) : integer -- bit mask */
long cxpoll(long h0, long w0, long h1, long w1, long h2, long w2,
            long timeout_ms) {
  long handles[3];
  long wants[3];
  struct pollfd entries[3];
  int slots[3];
  int count = 0, buffered = 0, index;

  handles[0] = h0; wants[0] = w0;
  handles[1] = h1; wants[1] = w1;
  handles[2] = h2; wants[2] = w2;

  for (index = 0; index < 3; index++) {
    cvx_handle *slot;
    int for_write;
    if (handles[index] < 0) continue;
    slot = cvx_slot(handles[index]);
    if (slot == NULL) {
      cvx_set_error("wait on a closed handle");
      return CVX_ERROR;
    }
    if (slot->ssl != NULL && wants[index] == 0 && SSL_pending(slot->ssl) > 0) {
      buffered |= 1 << index;
      continue;
    }
    for_write = wants[index] != 0 || slot->want_write;
    entries[count].fd = slot->fd;
    entries[count].events = (short)(for_write ? POLLOUT : POLLIN);
    entries[count].revents = 0;
    slots[count] = index;
    count++;
  }

  if (buffered != 0) return buffered;
  if (timeout_ms < 0) timeout_ms = 0;
  if (count == 0) {
    if (timeout_ms > 0) poll(NULL, 0, (int)timeout_ms);
    return 0;
  }

  for (;;) {
    int ready = poll(entries, (nfds_t)count, (int)timeout_ms);
    int mask, i;
    if (ready == 0) return 0;
    if (ready < 0) {
      if (errno == EINTR) continue;
      cvx_set_errno("wait failed");
      return CVX_ERROR;
    }
    mask = 0;
    for (i = 0; i < count; i++) {
      if (entries[i].revents != 0) mask |= 1 << slots[i];
    }
    return mask;
  }
}

/* cxnowms() : integer -- monotonic milliseconds since this process's first
   call to cxnowms, so the result stays small for the life of a short-lived
   adapter or example run and every deadline computed from it fits an
   integer with room to spare */
long cxnowms(void) { return cvx_now_ms(); }

/* cxerrtext(buf, cap) : integer -- writes the last error message as bytes */
long cxerrtext(long *buf, long cap) {
  long len = (long)strlen(cvx_last_error);
  long i;
  if (len > cap) len = cap;
  for (i = 0; i < len; i++) buf[i] = (unsigned char)cvx_last_error[i];
  return len;
}

/* cxclose(handle) : integer */
long cxclose(long handle) {
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) return 0;
  if (slot->ssl != NULL) SSL_set_quiet_shutdown(slot->ssl, 1);
  cvx_release(slot);
  return 0;
}

/* cxexit(code) -- flushes stdio and exits with the given status. The Simula
   caller flushes its own output objects (OutFile.Close / SYSOUT) before
   calling this. */
void cxexit(long code) {
  fflush(NULL);
  _exit((int)code);
}

/* cxrandom(buf, n) : integer -- fills n bytes of cryptographic entropy */
long cxrandom(long *buf, long n) {
  unsigned char scratch[256];
  long i;
  if (n < 0) n = 0;
  if (n > (long)sizeof(scratch)) n = (long)sizeof(scratch);
  if (RAND_bytes(scratch, (int)n) != 1) {
    /* RAND_bytes should not fail on a Linux host with a seeded kernel
       CSPRNG; fall back to a low-quality clock-derived stream only so the
       client degrades instead of aborting a session id. */
    unsigned int seed = (unsigned int)cvx_now_ms() ^ (unsigned int)getpid();
    for (i = 0; i < n; i++) {
      seed = seed * 1103515245u + 12345u;
      scratch[i] = (unsigned char)(seed >> 16);
    }
  }
  for (i = 0; i < n; i++) buf[i] = scratch[i];
  return n;
}

/* cxtextbytes(s, buf, cap) : integer -- copies a Simula text's bytes.
   `s` arrives already as a malloc'd NUL-terminated C string (Cim's by-value
   `text` parameter convention); this file must not free it. */
long cxtextbytes(const char *s, long *buf, long cap) {
  long len = (long)strlen(s);
  long i;
  if (len > cap) len = cap;
  for (i = 0; i < len; i++) buf[i] = (unsigned char)s[i];
  return len;
}

/* cxgetenv(name, namelen, buf, cap) : integer -- -1 if unset, else the
   length written to buf (0 for a variable set to the empty string). */
long cxgetenv(const long *name, long namelen, long *buf, long cap) {
  char name_c[256];
  const char *value;
  long len, i;
  if (cvx_bytes_to_cstr(name, namelen, name_c, sizeof(name_c)) != 0) {
    return -1;
  }
  value = getenv(name_c);
  if (value == NULL) return -1;
  len = (long)strlen(value);
  if (len > cap) len = cap;
  for (i = 0; i < len; i++) buf[i] = (unsigned char)value[i];
  return len;
}
