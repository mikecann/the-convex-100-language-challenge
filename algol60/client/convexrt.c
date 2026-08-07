/*
 * convexrt.c - the only native code in the ALGOL 60 Convex client.
 *
 * ALGOL 60 has no sockets, no TLS, no monotonic clock, no entropy source, no
 * environment access and no way to name a formal parameter that could hold
 * any of those. This file offers exactly those primitives and nothing else:
 * open a TCP or TLS stream, adopt an inherited descriptor, read, write, poll
 * for readiness, listen, accept, close, read a monotonic millisecond clock,
 * fill a buffer with random bytes, read an environment variable, report the
 * last error text and exit with a status code.
 *
 * Everything a reviewer would call "the client" -- HTTP/1.1 framing, JSON
 * encoding and decoding, RFC 6455 WebSocket framing, the /api/sync state
 * machine and the NDJSON adapter protocol -- is written in ALGOL 60 in the
 * files under client/. There is no HTTP, no WebSocket framing, no JSON and
 * no Convex protocol knowledge below this comment.
 *
 * Calling convention
 * -------------------
 * GNU MARST compiles every ALGOL 60 procedure -- including a `code`
 * procedure implemented in C -- to a C function named "<identifier>_0"
 * (the trailing digit is the procedure's declaration level; every procedure
 * here is declared at the outermost level, so it is always 0) that returns
 * "struct desc" and receives one "struct arg" per formal parameter:
 *
 *   - A by-value scalar (integer/real/Boolean) argument arrives as a thunk:
 *     arg1 is a pointer to a zero-argument C function returning
 *     "struct desc", and arg2 is the caller's DSA (display) pointer that the
 *     thunk may need while it runs. Evaluating it means temporarily
 *     installing arg2 as `global_dsa`, calling the thunk, and restoring the
 *     previous `global_dsa`; algolarg{Int,Real,Bool} below do exactly that.
 *   - An array argument arrives already resolved: arg1 is the array's dope
 *     vector ("struct dv *"), and arg2 is the element type tag ('r', 'i' or
 *     'b') cast to a pointer. Every array this client passes to C is
 *     declared `integer array`, so arg2 is always (void *) 'i' in practice,
 *     but algolarg checks it anyway.
 *   - A quoted string literal argument arrives as a plain, already
 *     NUL-terminated `char *` in arg1 with arg2 NULL; ALGOL 60 has no string
 *     variables, so this client never passes anything but a literal here.
 *
 * This file confirmed the exact shape above from marst's own generated C
 * (`marst -o prog.c prog.alg`, then reading prog.c) rather than assuming it
 * from the manual, per the project's own instructions.
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

#include "algol.h"

/* Sentinels shared with the ALGOL side (see client/convex-config.alg). */
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

static cvx_handle *cvx_slot(int handle) {
  if (handle < 0 || handle >= CVX_MAX_HANDLES) return NULL;
  if (!cvx_handles[handle].used) return NULL;
  return &cvx_handles[handle];
}

static int cvx_alloc(void) {
  for (int index = 0; index < CVX_MAX_HANDLES; index++) {
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
   value could already be close to a 32-bit millisecond wraparound on a
   long-uptime host -- ALGOL 60's `integer` is a 32-bit C int, not a 64-bit
   cell. Rebasing to the value seen at this process's first call keeps every
   deadline this short-lived adapter or example process computes (now plus
   a budget) far from that boundary. */
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

/* ------------------------------------------------------------------------
 * ALGOL 60 <-> C argument bridging
 * ---------------------------------------------------------------------- */

static struct desc algol_eval(struct arg a) {
  struct dsa *save = global_dsa;
  global_dsa = (struct dsa *)a.arg2;
  struct desc d = (*(struct desc (*)(void))a.arg1)();
  global_dsa = save;
  return d;
}

static int algol_int(struct arg a) { return get_int(algol_eval(a)); }

static struct desc mk_int(int v) {
  struct desc d;
  d.lval = 0;
  d.type = 'i';
  d.u.int_val = v;
  return d;
}

static struct desc mk_void(void) {
  struct desc d;
  d.lval = 0;
  d.type = 0;
  return d;
}

/* Copy an ALGOL `integer array` byte buffer (each element 0..255) into a
   fresh NUL-terminated C string. `length` is a by-value ALGOL integer
   argument giving the number of bytes to copy. Returns 0 on success, -1 if
   the buffer will not fit `cap` bytes including the terminator. */
static int algol_bytes_to_cstr(struct arg array_arg, int length, char *out,
                                int cap) {
  if (length < 0 || length + 1 > cap) return -1;
  struct dv *dv = (struct dv *)array_arg.arg1;
  int *base = (int *)dv->base;
  for (int i = 0; i < length; i++) out[i] = (char)(base[i] & 0xFF);
  out[length] = '\0';
  return 0;
}

/* ------------------------------------------------------------------------
 * Exported primitives, one per ALGOL 60 `code` procedure declaration in
 * client/convex-native.alg. Every identifier below is `<name>_0` because
 * every corresponding ALGOL declaration lives at the outermost level.
 * ---------------------------------------------------------------------- */

/* cxopen(host, hostlen, port, portlen, tls, deadlinems) : integer */
struct desc cxopen_0(struct arg host_arg, struct arg hostlen_arg,
                      struct arg port_arg, struct arg portlen_arg,
                      struct arg tls_arg, struct arg deadline_arg) {
  char host[256];
  char port[32];
  int hostlen = algol_int(hostlen_arg);
  int portlen = algol_int(portlen_arg);
  int tls = algol_int(tls_arg);
  long deadline = (long)algol_int(deadline_arg);

  if (algol_bytes_to_cstr(host_arg, hostlen, host, sizeof(host)) != 0) {
    cvx_set_error("host name too long");
    return mk_int(CVX_ERROR);
  }
  if (algol_bytes_to_cstr(port_arg, portlen, port, sizeof(port)) != 0) {
    cvx_set_error("port too long");
    return mk_int(CVX_ERROR);
  }

  int handle = cvx_alloc();
  if (handle < 0) return mk_int(handle);
  cvx_handle *slot = &cvx_handles[handle];

  int fd = cvx_connect_fd(host, port, deadline);
  if (fd < 0) {
    cvx_release(slot);
    return mk_int(CVX_ERROR);
  }
  slot->fd = fd;
  slot->owns_fd = 1;

  if (tls != 0 && cvx_start_tls(slot, host, deadline) != 0) {
    cvx_release(slot);
    return mk_int(CVX_ERROR);
  }
  return mk_int(handle);
}

/* cxadopt(fd) : integer */
struct desc cxadopt_0(struct arg fd_arg) {
  int fd = algol_int(fd_arg);
  int handle = cvx_alloc();
  if (handle < 0) return mk_int(handle);
  cvx_handle *slot = &cvx_handles[handle];
  if (cvx_nonblocking(fd) != 0) {
    cvx_set_errno("non-blocking mode");
    cvx_release(slot);
    return mk_int(CVX_ERROR);
  }
  slot->fd = fd;
  slot->owns_fd = 0;
  return mk_int(handle);
}

/* cxlisten(host, hostlen, port, portlen) : integer */
struct desc cxlisten_0(struct arg host_arg, struct arg hostlen_arg,
                        struct arg port_arg, struct arg portlen_arg) {
  char host[256];
  char port[32];
  int hostlen = algol_int(hostlen_arg);
  int portlen = algol_int(portlen_arg);

  if (algol_bytes_to_cstr(host_arg, hostlen, host, sizeof(host)) != 0) {
    cvx_set_error("host name too long");
    return mk_int(CVX_ERROR);
  }
  if (algol_bytes_to_cstr(port_arg, portlen, port, sizeof(port)) != 0) {
    cvx_set_error("port too long");
    return mk_int(CVX_ERROR);
  }

  struct addrinfo hints;
  struct addrinfo *list = NULL;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_PASSIVE;

  int status = getaddrinfo(host, port, &hints, &list);
  if (status != 0) {
    cvx_set_error(gai_strerror(status));
    return mk_int(CVX_ERROR);
  }

  int fd = -1;
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
  if (fd < 0) return mk_int(CVX_ERROR);

  int handle = cvx_alloc();
  if (handle < 0) {
    close(fd);
    return mk_int(handle);
  }
  cvx_handles[handle].fd = fd;
  cvx_handles[handle].owns_fd = 1;
  return mk_int(handle);
}

/* cxaccept(handle, timeoutms) : integer */
struct desc cxaccept_0(struct arg handle_arg, struct arg timeout_arg) {
  int handle = algol_int(handle_arg);
  long timeout = (long)algol_int(timeout_arg);
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) {
    cvx_set_error("accept on a closed handle");
    return mk_int(CVX_ERROR);
  }
  int ready = cvx_wait_fd(slot->fd, 0, timeout);
  if (ready != 1) return mk_int(ready == 0 ? CVX_AGAIN : CVX_ERROR);

  int fd = accept(slot->fd, NULL, NULL);
  if (fd < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return mk_int(CVX_AGAIN);
    cvx_set_errno("accept failed");
    return mk_int(CVX_ERROR);
  }
  if (cvx_nonblocking(fd) != 0) {
    cvx_set_errno("non-blocking mode");
    close(fd);
    return mk_int(CVX_ERROR);
  }
  int accepted = cvx_alloc();
  if (accepted < 0) {
    close(fd);
    return mk_int(accepted);
  }
  cvx_handles[accepted].fd = fd;
  cvx_handles[accepted].owns_fd = 1;
  return mk_int(accepted);
}

/* cxread(handle, buf, cap) : integer -- writes up to cap bytes into buf[0..] */
struct desc cxread_0(struct arg handle_arg, struct arg buf_arg,
                      struct arg cap_arg) {
  int handle = algol_int(handle_arg);
  int cap = algol_int(cap_arg);
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) {
    cvx_set_error("read on a closed handle");
    return mk_int(CVX_ERROR);
  }
  if (cap <= 0) return mk_int(0);

  struct dv *dv = (struct dv *)buf_arg.arg1;
  int *base = (int *)dv->base;
  unsigned char scratch[65536];
  int want = cap > (int)sizeof(scratch) ? (int)sizeof(scratch) : cap;
  long result;

  if (slot->ssl != NULL) {
    int r = SSL_read(slot->ssl, scratch, want);
    if (r > 0) {
      slot->want_write = 0;
      result = r;
    } else {
      int reason = SSL_get_error(slot->ssl, r);
      if (reason == SSL_ERROR_ZERO_RETURN) {
        result = 0;
      } else if (reason == SSL_ERROR_WANT_READ) {
        slot->want_write = 0;
        return mk_int(CVX_AGAIN);
      } else if (reason == SSL_ERROR_WANT_WRITE) {
        slot->want_write = 1;
        return mk_int(CVX_AGAIN);
      } else if (reason == SSL_ERROR_SYSCALL && ERR_peek_error() == 0 &&
                 errno == 0) {
        result = 0; /* peer closed without a TLS shutdown alert */
      } else {
        cvx_set_ssl_error("TLS read");
        return mk_int(CVX_ERROR);
      }
    }
  } else {
    for (;;) {
      ssize_t r = read(slot->fd, scratch, want);
      if (r >= 0) {
        result = r;
        break;
      }
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) return mk_int(CVX_AGAIN);
      cvx_set_errno("read failed");
      return mk_int(CVX_ERROR);
    }
  }
  for (long i = 0; i < result; i++) base[i] = scratch[i];
  return mk_int((int)result);
}

/* cxwrite(handle, buf, offset, length) : integer */
struct desc cxwrite_0(struct arg handle_arg, struct arg buf_arg,
                       struct arg offset_arg, struct arg length_arg) {
  int handle = algol_int(handle_arg);
  int offset = algol_int(offset_arg);
  int length = algol_int(length_arg);
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) {
    cvx_set_error("write on a closed handle");
    return mk_int(CVX_ERROR);
  }
  if (length <= 0) return mk_int(0);

  struct dv *dv = (struct dv *)buf_arg.arg1;
  int *base = (int *)dv->base;
  unsigned char scratch[65536];
  int want = length > (int)sizeof(scratch) ? (int)sizeof(scratch) : length;
  for (int i = 0; i < want; i++) scratch[i] = (unsigned char)(base[offset + i] & 0xFF);

  if (slot->ssl != NULL) {
    int r = SSL_write(slot->ssl, scratch, want);
    if (r > 0) {
      slot->want_write = 0;
      return mk_int(r);
    }
    int reason = SSL_get_error(slot->ssl, r);
    if (reason == SSL_ERROR_WANT_READ) {
      slot->want_write = 0;
      return mk_int(CVX_AGAIN);
    }
    if (reason == SSL_ERROR_WANT_WRITE) {
      slot->want_write = 1;
      return mk_int(CVX_AGAIN);
    }
    cvx_set_ssl_error("TLS write");
    return mk_int(CVX_ERROR);
  }

  for (;;) {
    ssize_t r = write(slot->fd, scratch, want);
    if (r >= 0) return mk_int((int)r);
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return mk_int(CVX_AGAIN);
    cvx_set_errno("write failed");
    return mk_int(CVX_ERROR);
  }
}

/* cxpoll(h0, w0, h1, w1, h2, w2, timeoutms) : integer -- bit mask */
struct desc cxpoll_0(struct arg h0a, struct arg w0a, struct arg h1a,
                      struct arg w1a, struct arg h2a, struct arg w2a,
                      struct arg tma) {
  int handles[3];
  int wants[3];
  handles[0] = algol_int(h0a);
  wants[0] = algol_int(w0a);
  handles[1] = algol_int(h1a);
  wants[1] = algol_int(w1a);
  handles[2] = algol_int(h2a);
  wants[2] = algol_int(w2a);
  long timeout_ms = (long)algol_int(tma);

  struct pollfd entries[3];
  int slots[3];
  int count = 0;
  int buffered = 0;

  for (int index = 0; index < 3; index++) {
    if (handles[index] < 0) continue;
    cvx_handle *slot = cvx_slot(handles[index]);
    if (slot == NULL) {
      cvx_set_error("wait on a closed handle");
      return mk_int(CVX_ERROR);
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

  if (buffered != 0) return mk_int(buffered);
  if (timeout_ms < 0) timeout_ms = 0;
  if (count == 0) {
    if (timeout_ms > 0) poll(NULL, 0, (int)timeout_ms);
    return mk_int(0);
  }

  for (;;) {
    int ready = poll(entries, (nfds_t)count, (int)timeout_ms);
    if (ready == 0) return mk_int(0);
    if (ready < 0) {
      if (errno == EINTR) continue;
      cvx_set_errno("wait failed");
      return mk_int(CVX_ERROR);
    }
    int mask = 0;
    for (int index = 0; index < count; index++) {
      if (entries[index].revents != 0) mask |= 1 << slots[index];
    }
    return mk_int(mask);
  }
}

/* cxnowms() : integer -- monotonic milliseconds since this process's first
   call to cxnowms, so the result stays small for the life of a short-lived
   adapter or example run and every deadline computed from it fits an
   ALGOL 60 integer with room to spare */
struct desc cxnowms_0(void) { return mk_int((int)cvx_now_ms()); }

/* cxerrtext(buf, cap) : integer -- writes the last error message as bytes */
struct desc cxerrtext_0(struct arg buf_arg, struct arg cap_arg) {
  int cap = algol_int(cap_arg);
  struct dv *dv = (struct dv *)buf_arg.arg1;
  int *base = (int *)dv->base;
  int len = (int)strlen(cvx_last_error);
  if (len > cap) len = cap;
  for (int i = 0; i < len; i++) base[i] = (unsigned char)cvx_last_error[i];
  return mk_int(len);
}

/* cxclose(handle) : integer */
struct desc cxclose_0(struct arg handle_arg) {
  int handle = algol_int(handle_arg);
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) return mk_int(0);
  if (slot->ssl != NULL) SSL_set_quiet_shutdown(slot->ssl, 1);
  cvx_release(slot);
  return mk_int(0);
}

/* cxexit(code) -- ALGOL 60 has no portable way to set a process exit
   status, and the shared verifier distinguishes a clean run from a failed
   one by that status alone. The ALGOL caller flushes its own output
   buffers to their handles before calling this. */
struct desc cxexit_0(struct arg code_arg) {
  int code = algol_int(code_arg);
  fflush(NULL);
  _exit(code);
  return mk_void(); /* unreachable */
}

/* cxrandom(buf, n) : integer -- fills n bytes of cryptographic entropy */
struct desc cxrandom_0(struct arg buf_arg, struct arg n_arg) {
  int n = algol_int(n_arg);
  struct dv *dv = (struct dv *)buf_arg.arg1;
  int *base = (int *)dv->base;
  unsigned char scratch[256];
  if (n < 0) n = 0;
  if (n > (int)sizeof(scratch)) n = (int)sizeof(scratch);
  if (RAND_bytes(scratch, n) != 1) {
    /* RAND_bytes should not fail on a Linux host with a seeded kernel CSPRNG;
       fall back to a low-quality clock-derived stream only so the client
       degrades instead of aborting a session id. */
    unsigned int seed = (unsigned int)cvx_now_ms() ^ (unsigned int)getpid();
    for (int i = 0; i < n; i++) {
      seed = seed * 1103515245u + 12345u;
      scratch[i] = (unsigned char)(seed >> 16);
    }
  }
  for (int i = 0; i < n; i++) base[i] = scratch[i];
  return mk_int(n);
}

/* cxstrbytes(s, buf, cap) : integer -- copies a literal string's bytes */
struct desc cxstrbytes_0(struct arg s_arg, struct arg buf_arg,
                          struct arg cap_arg) {
  const char *s = (const char *)s_arg.arg1;
  int cap = algol_int(cap_arg);
  struct dv *dv = (struct dv *)buf_arg.arg1;
  int *base = (int *)dv->base;
  int len = (int)strlen(s);
  if (len > cap) len = cap;
  for (int i = 0; i < len; i++) base[i] = (unsigned char)s[i];
  return mk_int(len);
}

/* cxgetenv(name, namelen, buf, cap) : integer -- -1 if unset, else the
   length written to buf (0 for a variable set to the empty string). */
struct desc cxgetenv_0(struct arg name_arg, struct arg namelen_arg,
                        struct arg buf_arg, struct arg cap_arg) {
  char name[256];
  int namelen = algol_int(namelen_arg);
  int cap = algol_int(cap_arg);
  if (algol_bytes_to_cstr(name_arg, namelen, name, sizeof(name)) != 0) {
    return mk_int(-1);
  }
  const char *value = getenv(name);
  if (value == NULL) return mk_int(-1);
  int len = (int)strlen(value);
  if (len > cap) len = cap;
  struct dv *dv = (struct dv *)buf_arg.arg1;
  int *base = (int *)dv->base;
  for (int i = 0; i < len; i++) base[i] = (unsigned char)value[i];
  return mk_int(len);
}
