/*
 * convexrt.c - the only native code in the Forth Convex client.
 *
 * Standard Forth has no sockets, no TLS and no monotonic clock, and gforth
 * cannot expose those safely from Forth source alone. This file therefore
 * offers exactly those primitives and nothing else: open a TCP or TLS stream,
 * read, write, wait for readiness, listen, accept, close, and read a monotonic
 * millisecond clock.
 *
 * Everything a reviewer would call "the client" stays in Forth. There is no
 * HTTP, no WebSocket framing, no JSON, no retry policy, no deadline policy and
 * no Convex protocol knowledge below this comment. The Forth side drives every
 * loop, so every bound it enforces is visible in Forth source.
 *
 * All calls are non-blocking. A short read or write is reported honestly and
 * the caller decides whether to wait again, which is what lets the Forth side
 * own absolute and dribble deadlines.
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
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

/* Return codes shared with the Forth side. Keep these in sync with the
   constants declared in client/convex-io.fth. */
#define CVX_AGAIN (-1)  /* the stream is open but not ready yet */
#define CVX_ERROR (-2)  /* the stream is unusable and must be closed */

/* A conformance run needs at most a listening socket, one controller stream,
   one Convex WebSocket, one HTTP stream and the two standard streams. The
   fixed table keeps handle lifetime auditable and removes any allocator from
   the transport path. */
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

long cvx_now_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
  return (long)now.tv_sec * 1000L + (long)(now.tv_nsec / 1000000L);
}

long cvx_error_text(char *buffer, long length) {
  long size = (long)strlen(cvx_last_error);
  if (length <= 0) return size;
  if (size > length) size = length;
  memcpy(buffer, cvx_last_error, (size_t)size);
  return size;
}

/* Wait for one file descriptor with a relative timeout. Used only while a
   stream is still being established; steady-state waiting goes through
   cvx_poll so the Forth side can watch several streams at once. */
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

/* Verification is switched on here rather than in Forth because a mistake in
   this function silently disables certificate checking. Hostname verification
   uses SSL_set1_host, so a certificate valid for another name is rejected. */
static int cvx_start_tls(cvx_handle *slot, const char *host, long deadline_ms) {
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
    if (cvx_wait_fd(slot->fd, reason == SSL_ERROR_WANT_WRITE, remaining) != 1) {
      return CVX_ERROR;
    }
  }
}

/* Open a TCP stream, optionally wrapped in a verified TLS session. deadline_ms
   is an absolute monotonic deadline taken from cvx_now_ms. */
long cvx_open(const char *host, const char *port, long tls, long deadline_ms) {
  long handle = cvx_alloc();
  if (handle < 0) return handle;
  cvx_handle *slot = &cvx_handles[handle];

  int fd = cvx_connect_fd(host, port, deadline_ms);
  if (fd < 0) {
    cvx_release(slot);
    return CVX_ERROR;
  }
  slot->fd = fd;
  slot->owns_fd = 1;

  if (tls != 0 && cvx_start_tls(slot, host, deadline_ms) != 0) {
    cvx_release(slot);
    return CVX_ERROR;
  }
  return handle;
}

/* Adopt an already open descriptor, such as the adapter's stdin and stdout.
   The descriptor is switched to non-blocking so the adapter can wait on the
   controller stream and the Convex WebSocket in one place. */
long cvx_adopt(long fd) {
  long handle = cvx_alloc();
  if (handle < 0) return handle;
  cvx_handle *slot = &cvx_handles[handle];
  if (cvx_nonblocking((int)fd) != 0) {
    cvx_set_errno("non-blocking mode");
    cvx_release(slot);
    return CVX_ERROR;
  }
  slot->fd = (int)fd;
  slot->owns_fd = 0;
  return handle;
}

long cvx_listen(const char *host, const char *port) {
  struct addrinfo hints;
  struct addrinfo *list = NULL;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_PASSIVE;

  int status = getaddrinfo(host, port, &hints, &list);
  if (status != 0) {
    cvx_set_error(gai_strerror(status));
    return CVX_ERROR;
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
  if (fd < 0) return CVX_ERROR;

  long handle = cvx_alloc();
  if (handle < 0) {
    close(fd);
    return handle;
  }
  cvx_handles[handle].fd = fd;
  cvx_handles[handle].owns_fd = 1;
  return handle;
}

long cvx_accept(long handle, long timeout_ms) {
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) {
    cvx_set_error("accept on a closed handle");
    return CVX_ERROR;
  }
  int ready = cvx_wait_fd(slot->fd, 0, timeout_ms);
  if (ready != 1) return ready == 0 ? CVX_AGAIN : CVX_ERROR;

  int fd = accept(slot->fd, NULL, NULL);
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
  long accepted = cvx_alloc();
  if (accepted < 0) {
    close(fd);
    return accepted;
  }
  cvx_handles[accepted].fd = fd;
  cvx_handles[accepted].owns_fd = 1;
  return accepted;
}

/* Read at most length bytes. Returns the byte count, 0 at end of stream,
   CVX_AGAIN when nothing is available yet, or CVX_ERROR. */
long cvx_read(long handle, char *buffer, long length) {
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) {
    cvx_set_error("read on a closed handle");
    return CVX_ERROR;
  }
  if (length <= 0) return 0;

  if (slot->ssl != NULL) {
    int result = SSL_read(slot->ssl, buffer, (int)length);
    if (result > 0) {
      slot->want_write = 0;
      return result;
    }
    int reason = SSL_get_error(slot->ssl, result);
    if (reason == SSL_ERROR_ZERO_RETURN) return 0;
    if (reason == SSL_ERROR_WANT_READ) {
      slot->want_write = 0;
      return CVX_AGAIN;
    }
    if (reason == SSL_ERROR_WANT_WRITE) {
      slot->want_write = 1;
      return CVX_AGAIN;
    }
    if (reason == SSL_ERROR_SYSCALL && ERR_peek_error() == 0 && errno == 0) {
      return 0; /* peer closed without a TLS shutdown alert */
    }
    cvx_set_ssl_error("TLS read");
    return CVX_ERROR;
  }

  for (;;) {
    ssize_t result = read(slot->fd, buffer, (size_t)length);
    if (result >= 0) return (long)result;
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return CVX_AGAIN;
    cvx_set_errno("read failed");
    return CVX_ERROR;
  }
}

/* Write at most length bytes. Returns the accepted byte count, CVX_AGAIN when
   the stream is full, or CVX_ERROR. Partial writes are reported so the Forth
   side can apply its own write deadline. */
long cvx_write(long handle, const char *buffer, long length) {
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) {
    cvx_set_error("write on a closed handle");
    return CVX_ERROR;
  }
  if (length <= 0) return 0;

  if (slot->ssl != NULL) {
    int result = SSL_write(slot->ssl, buffer, (int)length);
    if (result > 0) {
      slot->want_write = 0;
      return result;
    }
    int reason = SSL_get_error(slot->ssl, result);
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
    ssize_t result = write(slot->fd, buffer, (size_t)length);
    if (result >= 0) return (long)result;
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return CVX_AGAIN;
    cvx_set_errno("write failed");
    return CVX_ERROR;
  }
}

/*
 * Wait for up to three streams at once with a relative timeout in
 * milliseconds. Each want argument is 0 for readability and 1 for writability;
 * a handle of -1 is ignored. The result is a bit mask: bit 0 for the first
 * stream, bit 1 for the second, bit 2 for the third. 0 means the timeout
 * expired.
 *
 * A TLS session can hold a decrypted record that the kernel no longer reports
 * as readable, so buffered TLS data is reported ready immediately. Without
 * that check a Live reader could block while a complete frame is already
 * decoded in memory.
 */
long cvx_poll(long handle0, long want0, long handle1, long want1, long handle2,
              long want2, long timeout_ms) {
  long handles[3] = {handle0, handle1, handle2};
  long wants[3] = {want0, want1, want2};
  struct pollfd entries[3];
  int slots[3];
  int count = 0;
  int buffered = 0;

  for (int index = 0; index < 3; index++) {
    if (handles[index] < 0) continue;
    cvx_handle *slot = cvx_slot(handles[index]);
    if (slot == NULL) {
      cvx_set_error("wait on a closed handle");
      return CVX_ERROR;
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

  if (buffered != 0) return buffered;
  if (timeout_ms < 0) timeout_ms = 0;
  if (count == 0) {
    /* Nothing to watch. This is a plain sleep, used by the Forth side while a
       reconnect is held off by backoff; returning immediately would turn that
       wait into a spin. */
    if (timeout_ms > 0) poll(NULL, 0, (int)timeout_ms);
    return 0;
  }

  for (;;) {
    int ready = poll(entries, (nfds_t)count, (int)timeout_ms);
    if (ready == 0) return 0;
    if (ready < 0) {
      if (errno == EINTR) continue;
      cvx_set_errno("wait failed");
      return CVX_ERROR;
    }
    int mask = 0;
    for (int index = 0; index < count; index++) {
      if (entries[index].revents != 0) mask |= 1 << slots[index];
    }
    return mask;
  }
}

/* Forth has no portable way to set a process exit status, and the shared
   verifier distinguishes a clean run from a failed one by that status alone.
   The Forth caller flushes its output streams before calling this. */
void cvx_exit(long code) { _exit((int)code); }

long cvx_close(long handle) {
  cvx_handle *slot = cvx_slot(handle);
  if (slot == NULL) return 0;
  if (slot->ssl != NULL) SSL_set_quiet_shutdown(slot->ssl, 1);
  cvx_release(slot);
  return 0;
}
