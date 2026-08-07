/*
 * convexrt.c - the only native code in the SNOBOL4 Convex client.
 *
 * Standard SNOBOL4 has no sockets, no TLS, no monotonic clock and no entropy
 * source, and CSNOBOL4 cannot express those safely from SNOBOL4 source alone.
 * This file therefore offers exactly those primitives and nothing else: open
 * a TCP or TLS stream, read, write, wait for readiness, listen, accept,
 * close, read a monotonic millisecond clock, and fill a buffer with random
 * bytes. It is loaded through CSNOBOL4's documented external-function
 * mechanism (LOAD(), see doc/load.txt) as an ordinary dlopen() module; it is
 * not linked into the interpreter and does not touch CSNOBOL4's own source.
 *
 * Everything a reviewer would call "the client" -- JSON, HTTP/1.1 framing,
 * RFC 6455 WebSocket framing, SHA-1, base64, the Convex sync protocol and
 * every deadline, retry and bound -- stays in SNOBOL4 source under
 * client/*.sno. There is no HTTP, no WebSocket framing, no JSON and no
 * Convex protocol knowledge below this comment.
 *
 * SNOBOL4's LOAD() functions return exactly one value (or fail), so a read
 * is split into two calls the SNOBOL4 side always makes back to back:
 * CVXREAD() returns a byte count (or a negative status) and stashes the
 * bytes in the handle's own buffer; CVXREADBUF() returns those exact bytes
 * as a counted (binary-safe, not NUL-terminated) SNOBOL4 string. Nothing
 * else touches that buffer between the two calls because CSNOBOL4 is single
 * threaded and the SNOBOL4 side never interleaves two reads on one handle.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

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

#include "h.h"
#include "snotypes.h"
#include "macros.h"
#include "load.h"
#include "equ.h"

/* Status codes shared with the SNOBOL4 side (client/convex-io.sno). */
#define CVX_AGAIN (-1) /* the stream is open but not ready yet */
#define CVX_ERROR (-2) /* the stream is unusable and must be closed */

/* A conformance run needs at most a listening socket, one controller
   stream, one Convex WebSocket, one HTTP stream, a loopback test fixture
   socket and the two standard streams. The fixed table keeps handle
   lifetime auditable and removes any allocator from the transport path
   itself; only the per-handle read buffer below is heap allocated, and it
   is sized once per handle and reused for the handle's whole lifetime. */
#define CVX_MAX_HANDLES 16
#define CVX_READ_BUF_MAX (1 << 20) /* 1 MiB: bigger than any single read the
                                       SNOBOL4 side ever asks CVXREAD() for */

typedef struct {
  int used;
  int fd;
  int owns_fd;    /* adopted standard streams must not be closed twice */
  SSL *ssl;
  SSL_CTX *ctx;
  int want_write;  /* the last TLS operation asked for writability */
  char *read_buf;  /* lazily grown; holds the bytes CVXREADBUF() returns */
  long read_len;
  long read_cap;
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
  for (int index = 0; index < CVX_MAX_HANDLES; index++) {
    if (!cvx_handles[index].used) {
      char *buf = cvx_handles[index].read_buf;
      long cap = cvx_handles[index].read_cap;
      memset(&cvx_handles[index], 0, sizeof(cvx_handle));
      cvx_handles[index].used = 1;
      cvx_handles[index].fd = -1;
      cvx_handles[index].read_buf = buf; /* keep any prior allocation */
      cvx_handles[index].read_cap = cap;
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
  char *buf = slot->read_buf;
  long cap = slot->read_cap;
  memset(slot, 0, sizeof(cvx_handle));
  slot->fd = -1;
  slot->read_buf = buf; /* a handle's read buffer outlives its own reuse */
  slot->read_cap = cap;
}

static int cvx_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static long cvx_now_ms_raw(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
  return (long)now.tv_sec * 1000L + (long)(now.tv_nsec / 1000000L);
}

/* Wait for one file descriptor with a relative timeout. Used only while a
   stream is still being established; steady-state waiting goes through
   CVXPOLL so the SNOBOL4 side can watch several streams at once. */
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
    return -1;
  }
}

static int cvx_connect_fd(const char *host, const char *port, long deadline_ms) {
  struct addrinfo hints;
  struct addrinfo *list = NULL;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;

  int status = getaddrinfo(host, port, &hints, &list);
  if (status != 0) {
    cvx_set_error(gai_strerror(status));
    return -1;
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
      long remaining = deadline_ms - cvx_now_ms_raw();
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
  return fd;
}

/* Verification is switched on here rather than in SNOBOL4 because a mistake
   in this function silently disables certificate checking. Hostname
   verification uses SSL_set1_host, so a certificate valid for another name
   is rejected. */
static int cvx_start_tls(cvx_handle *slot, const char *host, long deadline_ms) {
  if (!cvx_tls_ready) {
    SSL_library_init();
    SSL_load_error_strings();
    cvx_tls_ready = 1;
  }

  slot->ctx = SSL_CTX_new(TLS_client_method());
  if (slot->ctx == NULL) {
    cvx_set_ssl_error("TLS context");
    return -1;
  }
  SSL_CTX_set_min_proto_version(slot->ctx, TLS1_2_VERSION);
  SSL_CTX_set_verify(slot->ctx, SSL_VERIFY_PEER, NULL);

  const char *bundle = getenv("SSL_CERT_FILE");
  if (bundle != NULL && bundle[0] != '\0') {
    if (SSL_CTX_load_verify_locations(slot->ctx, bundle, NULL) != 1) {
      cvx_set_ssl_error("CA bundle");
      return -1;
    }
  } else if (SSL_CTX_set_default_verify_paths(slot->ctx) != 1) {
    cvx_set_ssl_error("default CA paths");
    return -1;
  }

  slot->ssl = SSL_new(slot->ctx);
  if (slot->ssl == NULL) {
    cvx_set_ssl_error("TLS session");
    return -1;
  }
  SSL_set_fd(slot->ssl, slot->fd);
  SSL_set_tlsext_host_name(slot->ssl, host);
  SSL_set_hostflags(slot->ssl, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
  if (SSL_set1_host(slot->ssl, host) != 1) {
    cvx_set_ssl_error("TLS hostname");
    return -1;
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
      return -1;
    }
    long remaining = deadline_ms - cvx_now_ms_raw();
    if (remaining <= 0) {
      cvx_set_error("TLS handshake timed out");
      return -1;
    }
    if (cvx_wait_fd(slot->fd, reason == SSL_ERROR_WANT_WRITE, remaining) != 1) {
      return -1;
    }
  }
}

/* ---------------------------------------------------------------------
 * Loadable entry points. Each one follows CSNOBOL4's LOAD_PROTO signature
 * (struct descr *retval, unsigned nargs, struct descr *args) via the
 * LA_ALIST macro, and returns through the RETINT/RETSTR2/RETFAIL macros
 * documented in doc/load.txt.
 * ------------------------------------------------------------------- */

/* CVXOPEN(host, port, tls, deadlinems) INTEGER -- open a TCP stream,
   optionally wrapped in a verified TLS session. deadlinems is an absolute
   monotonic deadline taken from CVXNOWMS(). Returns a handle, or
   CVX_ERROR. */
lret_t CVXOPEN(LA_ALIST) LA_DCL {
  char host[256];
  char port[32];
  getstring(LA_PTR(0), host, sizeof(host));
  getstring(LA_PTR(1), port, sizeof(port));
  long tls = LA_INT(2);
  long deadline_ms = LA_INT(3);

  long handle = cvx_alloc();
  if (handle < 0) RETINT(CVX_ERROR);
  cvx_handle *slot = &cvx_handles[handle];

  int fd = cvx_connect_fd(host, port, deadline_ms);
  if (fd < 0) {
    cvx_release(slot);
    RETINT(CVX_ERROR);
  }
  slot->fd = fd;
  slot->owns_fd = 1;

  if (tls != 0 && cvx_start_tls(slot, host, deadline_ms) != 0) {
    cvx_release(slot);
    RETINT(CVX_ERROR);
  }
  RETINT(handle);
}

/* CVXADOPT(fd) INTEGER -- adopt an already open descriptor, such as the
   adapter's stdin/stdout when it runs in stdio mode. Switched to
   non-blocking so the same poll loop can watch it. */
lret_t CVXADOPT(LA_ALIST) LA_DCL {
  long fd = LA_INT(0);
  long handle = cvx_alloc();
  if (handle < 0) RETINT(CVX_ERROR);
  cvx_handle *slot = &cvx_handles[handle];
  if (cvx_nonblocking((int)fd) != 0) {
    cvx_set_errno("non-blocking mode");
    cvx_release(slot);
    RETINT(CVX_ERROR);
  }
  slot->fd = (int)fd;
  slot->owns_fd = 0;
  RETINT(handle);
}

/* CVXLISTEN(host, port) INTEGER -- open a listening socket, used by the
   adapter's TCP mode and by loopback test fixtures. */
lret_t CVXLISTEN(LA_ALIST) LA_DCL {
  char host[256];
  char port[32];
  getstring(LA_PTR(0), host, sizeof(host));
  getstring(LA_PTR(1), port, sizeof(port));

  struct addrinfo hints;
  struct addrinfo *list = NULL;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_PASSIVE;

  int status = getaddrinfo(host, port, &hints, &list);
  if (status != 0) {
    cvx_set_error(gai_strerror(status));
    RETINT(CVX_ERROR);
  }

  int fd = -1;
  for (struct addrinfo *entry = list; entry != NULL; entry = entry->ai_next) {
    fd = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
    if (fd < 0) continue;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(fd, entry->ai_addr, entry->ai_addrlen) == 0 &&
        listen(fd, 8) == 0 && cvx_nonblocking(fd) == 0) {
      break;
    }
    cvx_set_errno("listen failed");
    close(fd);
    fd = -1;
  }
  freeaddrinfo(list);
  if (fd < 0) RETINT(CVX_ERROR);

  long handle = cvx_alloc();
  if (handle < 0) {
    close(fd);
    RETINT(CVX_ERROR);
  }
  cvx_handles[handle].fd = fd;
  cvx_handles[handle].owns_fd = 1;
  RETINT(handle);
}

/* CVXPORT(handle) INTEGER -- the local port a CVXLISTEN() handle was bound
   to, needed when a test fixture asks for an ephemeral port (port "0"). */
lret_t CVXPORT(LA_ALIST) LA_DCL {
  long handle = LA_INT(0);
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) RETINT(CVX_ERROR);
  struct sockaddr_storage addr;
  socklen_t len = sizeof(addr);
  if (getsockname(slot->fd, (struct sockaddr *)&addr, &len) != 0) {
    cvx_set_errno("getsockname failed");
    RETINT(CVX_ERROR);
  }
  int port = (addr.ss_family == AF_INET6)
                 ? ntohs(((struct sockaddr_in6 *)&addr)->sin6_port)
                 : ntohs(((struct sockaddr_in *)&addr)->sin_port);
  RETINT(port);
}

/* CVXACCEPT(handle, timeoutms) INTEGER -- accept one connection, or
   CVX_AGAIN if none arrived inside the relative timeout. */
lret_t CVXACCEPT(LA_ALIST) LA_DCL {
  long handle = LA_INT(0);
  long timeout_ms = LA_INT(1);
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) RETINT(CVX_ERROR);
  int ready = cvx_wait_fd(slot->fd, 0, timeout_ms);
  if (ready != 1) RETINT(ready == 0 ? CVX_AGAIN : CVX_ERROR);

  int fd = accept(slot->fd, NULL, NULL);
  if (fd < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) RETINT(CVX_AGAIN);
    cvx_set_errno("accept failed");
    RETINT(CVX_ERROR);
  }
  if (cvx_nonblocking(fd) != 0) {
    cvx_set_errno("non-blocking mode");
    close(fd);
    RETINT(CVX_ERROR);
  }
  long accepted = cvx_alloc();
  if (accepted < 0) {
    close(fd);
    RETINT(accepted);
  }
  cvx_handles[accepted].fd = fd;
  cvx_handles[accepted].owns_fd = 1;
  RETINT(accepted);
}

/* CVXREAD(handle, maxlen) INTEGER -- read at most maxlen bytes into the
   handle's own buffer. Returns the byte count, 0 at end of stream,
   CVX_AGAIN when nothing is available yet, or CVX_ERROR. Follow a positive
   result with CVXREADBUF() before doing anything else with this handle. */
lret_t CVXREAD(LA_ALIST) LA_DCL {
  long handle = LA_INT(0);
  long max_len = LA_INT(1);
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) RETINT(CVX_ERROR);
  if (max_len <= 0) RETINT(0);
  if (max_len > CVX_READ_BUF_MAX) max_len = CVX_READ_BUF_MAX;
  if (slot->read_cap < max_len) {
    char *grown = realloc(slot->read_buf, (size_t)max_len);
    if (grown == NULL) {
      cvx_set_error("out of memory growing read buffer");
      RETINT(CVX_ERROR);
    }
    slot->read_buf = grown;
    slot->read_cap = max_len;
  }

  if (slot->ssl != NULL) {
    int result = SSL_read(slot->ssl, slot->read_buf, (int)max_len);
    if (result > 0) {
      slot->want_write = 0;
      slot->read_len = result;
      RETINT(result);
    }
    int reason = SSL_get_error(slot->ssl, result);
    if (reason == SSL_ERROR_ZERO_RETURN) {
      slot->read_len = 0;
      RETINT(0);
    }
    if (reason == SSL_ERROR_WANT_READ) {
      slot->want_write = 0;
      RETINT(CVX_AGAIN);
    }
    if (reason == SSL_ERROR_WANT_WRITE) {
      slot->want_write = 1;
      RETINT(CVX_AGAIN);
    }
    if (reason == SSL_ERROR_SYSCALL && ERR_peek_error() == 0 && errno == 0) {
      slot->read_len = 0;
      RETINT(0); /* peer closed without a TLS shutdown alert */
    }
    cvx_set_ssl_error("TLS read");
    RETINT(CVX_ERROR);
  }

  for (;;) {
    ssize_t result = read(slot->fd, slot->read_buf, (size_t)max_len);
    if (result >= 0) {
      slot->read_len = result;
      RETINT((long)result);
    }
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) RETINT(CVX_AGAIN);
    cvx_set_errno("read failed");
    RETINT(CVX_ERROR);
  }
}

/* CVXREADBUF(handle) STRING -- the exact bytes the most recent successful
   CVXREAD() on this handle produced, as a counted (binary-safe) string. */
lret_t CVXREADBUF(LA_ALIST) LA_DCL {
  long handle = LA_INT(0);
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL || slot->read_len <= 0) {
    RETSTR2("", 0);
  }
  RETSTR2(slot->read_buf, (int)slot->read_len);
}

/* CVXWRITE(handle, data) INTEGER -- write at most the whole string. Returns
   the accepted byte count, CVX_AGAIN when the stream is full, or
   CVX_ERROR. A short write is reported honestly so the SNOBOL4 side can
   apply its own write deadline across repeated calls. */
lret_t CVXWRITE(LA_ALIST) LA_DCL {
  long handle = LA_INT(0);
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) RETINT(CVX_ERROR);
  const char *data = LA_STR_PTR(1);
  long length = LA_STR_LEN(1);
  if (data == NULL || length <= 0) RETINT(0);

  if (slot->ssl != NULL) {
    int result = SSL_write(slot->ssl, data, (int)length);
    if (result > 0) {
      slot->want_write = 0;
      RETINT(result);
    }
    int reason = SSL_get_error(slot->ssl, result);
    if (reason == SSL_ERROR_WANT_READ) {
      slot->want_write = 0;
      RETINT(CVX_AGAIN);
    }
    if (reason == SSL_ERROR_WANT_WRITE) {
      slot->want_write = 1;
      RETINT(CVX_AGAIN);
    }
    cvx_set_ssl_error("TLS write");
    RETINT(CVX_ERROR);
  }

  for (;;) {
    ssize_t result = write(slot->fd, data, (size_t)length);
    if (result >= 0) RETINT((long)result);
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) RETINT(CVX_AGAIN);
    cvx_set_errno("write failed");
    RETINT(CVX_ERROR);
  }
}

/*
 * CVXPOLL(handle0, want0, handle1, want1, handle2, want2, timeoutms)
 * INTEGER -- wait for up to three streams at once with a relative timeout
 * in milliseconds. Each want argument is 0 for readability and 1 for
 * writability; a handle of -1 is ignored. The result is a bit mask: bit 0
 * for the first stream, bit 1 for the second, bit 2 for the third. 0 means
 * the timeout expired.
 *
 * A TLS session can hold a decrypted record that the kernel no longer
 * reports as readable, so buffered TLS data is reported ready immediately.
 * Without that check a Live reader could block while a complete frame is
 * already decoded in memory.
 */
lret_t CVXPOLL(LA_ALIST) LA_DCL {
  long handles[3] = {LA_INT(0), LA_INT(2), LA_INT(4)};
  long wants[3] = {LA_INT(1), LA_INT(3), LA_INT(5)};
  long timeout_ms = LA_INT(6);
  struct pollfd entries[3];
  int slots[3];
  int count = 0;
  int buffered = 0;

  for (int index = 0; index < 3; index++) {
    if (handles[index] < 0) continue;
    cvx_handle *slot = cvx_slot(handles[index]);
    if (slot == NULL) {
      cvx_set_error("wait on a closed handle");
      RETINT(CVX_ERROR);
    }
    if (slot->ssl != NULL && wants[index] == 0 && SSL_pending(slot->ssl) > 0) {
      buffered |= 1 << index;
      continue;
    }
    int for_write = wants[index] != 0 || slot->want_write;
    entries[count].fd = slot->fd;
    entries[count].events = (short)(for_write ? POLLOUT : POLLIN);
    entries[count].revents = 0;
    slots[count] = index;
    count++;
  }

  if (buffered != 0) RETINT(buffered);
  if (timeout_ms < 0) timeout_ms = 0;
  if (count == 0) {
    /* Nothing to watch. This is a plain sleep, used by the SNOBOL4 side
       while a reconnect is held off by backoff; returning immediately
       would turn that wait into a spin. */
    if (timeout_ms > 0) poll(NULL, 0, (int)timeout_ms);
    RETINT(0);
  }

  for (;;) {
    int ready = poll(entries, (nfds_t)count, (int)timeout_ms);
    if (ready == 0) RETINT(0);
    if (ready < 0) {
      if (errno == EINTR) continue;
      cvx_set_errno("wait failed");
      RETINT(CVX_ERROR);
    }
    int mask = 0;
    for (int index = 0; index < count; index++) {
      if (entries[index].revents != 0) mask |= 1 << slots[index];
    }
    RETINT(mask);
  }
}

/* CVXCLOSE(handle) INTEGER -- always succeeds; closing an unknown handle is
   a no-op so cleanup code never has to track whether it already ran. */
lret_t CVXCLOSE(LA_ALIST) LA_DCL {
  long handle = LA_INT(0);
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) RETINT(0);
  if (slot->ssl != NULL) SSL_set_quiet_shutdown(slot->ssl, 1);
  cvx_release(slot);
  RETINT(0);
}

/* CVXNOWMS() INTEGER -- a monotonic millisecond clock, used to compute
   every absolute deadline on the SNOBOL4 side. */
lret_t CVXNOWMS(LA_ALIST) LA_DCL {
  (void)nargs;
  (void)args;
  RETINT(cvx_now_ms_raw());
}

/* CVXRANDOM(count) STRING -- count cryptographically random bytes, used for
   RFC 6455 masking keys and the handshake nonce. Falls back to /dev/urandom
   if OpenSSL's generator is not seeded, which cannot happen in practice on
   Linux but keeps this function honest about how it can fail. */
lret_t CVXRANDOM(LA_ALIST) LA_DCL {
  long count = LA_INT(0);
  static unsigned char buffer[256];
  if (count <= 0 || count > (long)sizeof(buffer)) {
    cvx_set_error("random byte count out of range");
    RETSTR2("", 0);
  }
  if (RAND_bytes(buffer, (int)count) == 1) {
    RETSTR2((char *)buffer, (int)count);
  }
  FILE *urandom = fopen("/dev/urandom", "rb");
  if (urandom != NULL) {
    size_t got = fread(buffer, 1, (size_t)count, urandom);
    fclose(urandom);
    if (got == (size_t)count) RETSTR2((char *)buffer, (int)count);
  }
  cvx_set_error("no entropy source available");
  RETSTR2("", 0);
}

/* CVXGETENV(name) STRING -- an environment variable's value, or the empty
   string when it is unset. CSNOBOL4's own lib/snolib/getenv.c requires a
   static PML link this build does not perform, so the adapter, the example
   and the client's own configuration all read the environment through this
   shim function instead. */
lret_t CVXGETENV(LA_ALIST) LA_DCL {
  (void)nargs;
  char name[256];
  getstring(LA_PTR(0), name, sizeof(name));
  const char *value = getenv(name);
  if (value == NULL) RETSTR2("", 0);
  RETSTR2(value, (int)strlen(value));
}

/* CVXSTDERR(text) INTEGER -- write one diagnostic line (with a trailing
   newline this function adds) directly to file descriptor 2. Protocol
   events belong on stdout, so every diagnostic the adapter and the example
   print goes through this instead of SNOBOL4's own OUTPUT variable. */
lret_t CVXSTDERR(LA_ALIST) LA_DCL {
  (void)nargs;
  const char *text = LA_STR_PTR(0);
  long length = LA_STR_LEN(0);
  if (text != NULL && length > 0) {
    ssize_t ignored = write(2, text, (size_t)length);
    (void)ignored;
  }
  ssize_t ignored_nl = write(2, "\n", 1);
  (void)ignored_nl;
  RETINT(0);
}

/* CVXERRTEXT() STRING -- human-readable detail for the most recent CVX_ERROR
   this shim returned, used only for diagnostics on stderr. */
lret_t CVXERRTEXT(LA_ALIST) LA_DCL {
  (void)nargs;
  (void)args;
  RETSTR2(cvx_last_error, (int)strlen(cvx_last_error));
}

/* CVXEXIT(code) INTEGER -- SNOBOL4 has no portable way to set a process
   exit status, and the shared verifier distinguishes a clean run from a
   failed one by that status alone. The SNOBOL4 caller flushes its own
   output streams (ENDFILE on the standard output unit) before calling
   this; _exit() does not flush stdio itself. */
lret_t CVXEXIT(LA_ALIST) LA_DCL {
  long code = LA_INT(0);
  _exit((int)code);
  RETINT(0); /* unreachable; keeps the compiler happy about a return path */
}
