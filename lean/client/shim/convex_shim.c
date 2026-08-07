/*
 * Lean has no networking in its core library, so this shim is the client's
 * only foreign surface: BSD sockets, OpenSSL, poll(2), a monotonic clock,
 * SHA-1, and the CSPRNG. Every Convex-specific decision -- HTTP framing,
 * RFC 6455 framing, the sync protocol, deadlines, and every bound -- is
 * implemented in Lean on top of these primitives.
 *
 * The surface is deliberately neutral. It knows nothing about Convex, and it
 * contains no fault injection; the deterministic fixtures that misbehave are
 * ordinary Lean test code that happens to call listen/accept.
 */

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

#include <arpa/inet.h>

#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#include <lean/lean.h>

/* ------------------------------------------------------------------ */
/* Connection objects                                                  */
/* ------------------------------------------------------------------ */

typedef struct {
  int fd;
  SSL *ssl;
  SSL_CTX *ctx;
  int listening;
  int eof;
} convex_conn;

static lean_external_class *g_convex_conn_class = NULL;

static void convex_conn_release(convex_conn *conn) {
  if (conn == NULL) {
    return;
  }
  if (conn->ssl != NULL) {
    SSL_free(conn->ssl);
    conn->ssl = NULL;
  }
  if (conn->ctx != NULL) {
    SSL_CTX_free(conn->ctx);
    conn->ctx = NULL;
  }
  if (conn->fd >= 0) {
    close(conn->fd);
    conn->fd = -1;
  }
}

static void convex_conn_finalize(void *pointer) {
  convex_conn *conn = (convex_conn *)pointer;
  convex_conn_release(conn);
  free(conn);
}

static void convex_conn_foreach(void *pointer, b_lean_obj_arg function) {
  (void)pointer;
  (void)function;
}

/*
 * OpenSSL initialisation and the external class are both idempotent one-time
 * setups. The client is single threaded, so a plain guard is sufficient.
 */
static void convex_ensure_initialised(void) {
  if (g_convex_conn_class == NULL) {
    OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, NULL);
    g_convex_conn_class = lean_register_external_class(convex_conn_finalize, convex_conn_foreach);
  }
}

static convex_conn *convex_conn_of(b_lean_obj_arg object) {
  return (convex_conn *)lean_get_external_data(object);
}

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static lean_object *convex_fail(const char *message) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(message)));
}

static lean_object *convex_fail_fmt(const char *prefix, const char *detail) {
  char buffer[512];
  snprintf(buffer, sizeof(buffer), "%s: %s", prefix, detail);
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(buffer)));
}

/* The newest OpenSSL error is far more useful than errno for TLS failures. */
static lean_object *convex_fail_ssl(const char *prefix) {
  char detail[256];
  unsigned long code = ERR_peek_last_error();
  if (code == 0) {
    snprintf(detail, sizeof(detail), "%s", strerror(errno));
  } else {
    ERR_error_string_n(code, detail, sizeof(detail));
  }
  ERR_clear_error();
  return convex_fail_fmt(prefix, detail);
}

static uint64_t convex_monotonic_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000u + (uint64_t)(now.tv_nsec / 1000000);
}

/*
 * Deadlines are absolute monotonic milliseconds throughout the client. A
 * deadline that has already passed yields a zero wait rather than an
 * accidental infinite one, which is what makes "dribble" peers bounded.
 */
static int convex_remaining_ms(uint64_t deadline) {
  uint64_t now = convex_monotonic_ms();
  if (deadline <= now) {
    return 0;
  }
  uint64_t remaining = deadline - now;
  if (remaining > 2147483000u) {
    remaining = 2147483000u;
  }
  return (int)remaining;
}

static int convex_set_nonblocking_fd(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) {
    return -1;
  }
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int convex_wait_fd(int fd, short events, uint64_t deadline) {
  struct pollfd descriptor;
  descriptor.fd = fd;
  descriptor.events = events;
  descriptor.revents = 0;
  for (;;) {
    int ready = poll(&descriptor, 1, convex_remaining_ms(deadline));
    if (ready > 0) {
      return 1;
    }
    if (ready == 0) {
      return 0;
    }
    if (errno != EINTR) {
      return -1;
    }
  }
}

static lean_object *convex_alloc_conn(int fd, SSL *ssl, SSL_CTX *ctx, int listening) {
  convex_conn *conn = (convex_conn *)calloc(1, sizeof(convex_conn));
  conn->fd = fd;
  conn->ssl = ssl;
  conn->ctx = ctx;
  conn->listening = listening;
  conn->eof = 0;
  return lean_alloc_external(g_convex_conn_class, conn);
}

static lean_object *convex_mk_bytes(const uint8_t *data, size_t size) {
  lean_object *array = lean_alloc_sarray(1, size, size);
  if (size > 0) {
    memcpy(lean_sarray_cptr(array), data, size);
  }
  return array;
}

/* `none` means end of stream; `some bytes` may still be empty for "not yet". */
static lean_object *convex_mk_some(lean_object *value) {
  lean_object *option = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(option, 0, value);
  return option;
}

/* ------------------------------------------------------------------ */
/* Clock, randomness, digest                                           */
/* ------------------------------------------------------------------ */

LEAN_EXPORT lean_object *convex_shim_now_ms(lean_object *world) {
  (void)world;
  return lean_io_result_mk_ok(lean_box_uint64(convex_monotonic_ms()));
}

LEAN_EXPORT lean_object *convex_shim_random_bytes(uint32_t count, lean_object *world) {
  (void)world;
  convex_ensure_initialised();
  if (count > 4096) {
    return convex_fail("convex shim: refusing an unreasonable random request");
  }
  lean_object *array = lean_alloc_sarray(1, count, count);
  if (count > 0 && RAND_bytes(lean_sarray_cptr(array), (int)count) != 1) {
    lean_dec(array);
    return convex_fail_ssl("convex shim: RAND_bytes failed");
  }
  return lean_io_result_mk_ok(array);
}

LEAN_EXPORT lean_object *convex_shim_sha1(b_lean_obj_arg data, lean_object *world) {
  (void)world;
  convex_ensure_initialised();
  uint8_t digest[SHA_DIGEST_LENGTH];
  SHA1(lean_sarray_cptr((lean_object *)data), lean_sarray_size((lean_object *)data), digest);
  return lean_io_result_mk_ok(convex_mk_bytes(digest, sizeof(digest)));
}

/* ------------------------------------------------------------------ */
/* Descriptor-level primitives used by the adapter's single event loop */
/* ------------------------------------------------------------------ */

LEAN_EXPORT lean_object *convex_shim_set_nonblocking(uint32_t fd, lean_object *world) {
  (void)world;
  if (convex_set_nonblocking_fd((int)fd) < 0) {
    return convex_fail_fmt("convex shim: could not set O_NONBLOCK", strerror(errno));
  }
  return lean_io_result_mk_ok(lean_box(0));
}

/*
 * Shrink a socket's kernel send and receive buffers. Only a test fixture
 * calls this: it makes a "nobody reads this socket" backpressure scenario
 * fill up after a small, fixed number of bytes rather than however large
 * this host's autotuned TCP buffers happen to be, which otherwise varies by
 * machine and can swallow megabytes before a write ever blocks.
 */
LEAN_EXPORT lean_object *convex_shim_set_socket_buffer_size(uint32_t fd, uint32_t bytes,
                                                             lean_object *world) {
  (void)world;
  int size = (int)bytes;
  if (setsockopt((int)fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) < 0) {
    return convex_fail_fmt("convex shim: could not set SO_SNDBUF", strerror(errno));
  }
  if (setsockopt((int)fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) < 0) {
    return convex_fail_fmt("convex shim: could not set SO_RCVBUF", strerror(errno));
  }
  return lean_io_result_mk_ok(lean_box(0));
}

/*
 * One poll over at most three descriptors is the whole scheduler: the
 * adapter's input, its output, and the Live socket. Each slot contributes
 * three result bits -- readable, writable, and error or hangup -- so a dead
 * peer wakes the loop instead of stalling it.
 */
LEAN_EXPORT lean_object *convex_shim_poll(uint32_t fd0, uint32_t events0, uint32_t fd1, uint32_t events1,
                                          uint32_t fd2, uint32_t events2, uint32_t timeout_ms,
                                          lean_object *world) {
  (void)world;
  const uint32_t requested[3] = {fd0, fd1, fd2};
  const uint32_t interests[3] = {events0, events1, events2};
  struct pollfd descriptors[3];
  int slot_index[3] = {-1, -1, -1};
  int count = 0;

  for (int slot = 0; slot < 3; slot++) {
    if (requested[slot] == 0xFFFFFFFFu) {
      continue;
    }
    descriptors[count].fd = (int)requested[slot];
    descriptors[count].events =
        (short)(((interests[slot] & 1u) ? POLLIN : 0) | ((interests[slot] & 2u) ? POLLOUT : 0));
    descriptors[count].revents = 0;
    slot_index[slot] = count;
    count++;
  }

  int ready = poll(descriptors, (nfds_t)count, (int)timeout_ms);
  if (ready < 0) {
    if (errno == EINTR) {
      return lean_io_result_mk_ok(lean_box_uint32(0));
    }
    return convex_fail_fmt("convex shim: poll failed", strerror(errno));
  }

  uint32_t mask = 0;
  for (int slot = 0; slot < 3; slot++) {
    int index = slot_index[slot];
    if (index < 0) {
      continue;
    }
    if (descriptors[index].revents & POLLIN) mask |= (1u << (slot * 3));
    if (descriptors[index].revents & POLLOUT) mask |= (2u << (slot * 3));
    if (descriptors[index].revents & (POLLERR | POLLHUP | POLLNVAL)) mask |= (4u << (slot * 3));
  }
  return lean_io_result_mk_ok(lean_box_uint32(mask));
}

LEAN_EXPORT lean_object *convex_shim_read_fd(uint32_t fd, uint32_t limit, lean_object *world) {
  (void)world;
  if (limit > 1048576u) {
    limit = 1048576u;
  }
  uint8_t *buffer = (uint8_t *)malloc(limit == 0 ? 1 : limit);
  ssize_t received = read((int)fd, buffer, limit);
  if (received == 0) {
    free(buffer);
    return lean_io_result_mk_ok(lean_box(0));
  }
  if (received < 0) {
    int code = errno;
    free(buffer);
    if (code == EAGAIN || code == EWOULDBLOCK || code == EINTR) {
      return lean_io_result_mk_ok(convex_mk_some(convex_mk_bytes(NULL, 0)));
    }
    return convex_fail_fmt("convex shim: read failed", strerror(code));
  }
  lean_object *bytes = convex_mk_bytes(buffer, (size_t)received);
  free(buffer);
  return lean_io_result_mk_ok(convex_mk_some(bytes));
}

/*
 * A partial write is normal on a non-blocking descriptor whose reader has
 * stopped. Returning the accepted count lets the Lean output queue keep its
 * own byte accounting instead of blocking inside the runtime.
 */
LEAN_EXPORT lean_object *convex_shim_write_fd(uint32_t fd, b_lean_obj_arg data, uint32_t offset,
                                              lean_object *world) {
  (void)world;
  size_t size = lean_sarray_size((lean_object *)data);
  if ((size_t)offset >= size) {
    return lean_io_result_mk_ok(lean_box_uint32(0));
  }
  ssize_t written = write((int)fd, lean_sarray_cptr((lean_object *)data) + offset, size - (size_t)offset);
  if (written < 0) {
    int code = errno;
    if (code == EAGAIN || code == EWOULDBLOCK || code == EINTR) {
      return lean_io_result_mk_ok(lean_box_uint32(0));
    }
    return convex_fail_fmt("convex shim: write failed", strerror(code));
  }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)written));
}

/* ------------------------------------------------------------------ */
/* Outbound connections                                                */
/* ------------------------------------------------------------------ */

static int convex_connect_socket(const char *host, const char *service, uint64_t deadline, char *problem,
                                 size_t problem_size) {
  struct addrinfo hints;
  struct addrinfo *results = NULL;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  int resolved = getaddrinfo(host, service, &hints, &results);
  if (resolved != 0) {
    snprintf(problem, problem_size, "%s", gai_strerror(resolved));
    return -1;
  }

  int fd = -1;
  for (struct addrinfo *candidate = results; candidate != NULL; candidate = candidate->ai_next) {
    fd = socket(candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol);
    if (fd < 0) {
      continue;
    }
    if (convex_set_nonblocking_fd(fd) < 0) {
      close(fd);
      fd = -1;
      continue;
    }
    int started = connect(fd, candidate->ai_addr, candidate->ai_addrlen);
    if (started == 0) {
      break;
    }
    if (errno == EINPROGRESS) {
      int ready = convex_wait_fd(fd, POLLOUT, deadline);
      if (ready == 1) {
        int error = 0;
        socklen_t length = sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0) {
          break;
        }
        snprintf(problem, problem_size, "%s", strerror(error == 0 ? ETIMEDOUT : error));
      } else if (ready == 0) {
        snprintf(problem, problem_size, "connect deadline expired");
      } else {
        snprintf(problem, problem_size, "%s", strerror(errno));
      }
    } else {
      snprintf(problem, problem_size, "%s", strerror(errno));
    }
    close(fd);
    fd = -1;
  }

  freeaddrinfo(results);
  if (fd < 0 && problem[0] == '\0') {
    snprintf(problem, problem_size, "no usable address");
  }
  if (fd >= 0) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  }
  return fd;
}

/*
 * Verification is requested explicitly rather than inherited from OpenSSL's
 * defaults: the chain must validate and the presented identity must match the
 * host the client asked for. A test can therefore prove that an untrusted CA
 * or a mismatched name is rejected, not merely that a handshake happened.
 */
static int convex_configure_verification(SSL_CTX *ctx, SSL *ssl, const char *verify_host,
                                         const char *ca_file) {
  if (ca_file != NULL && ca_file[0] != '\0') {
    if (SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1) {
      return -1;
    }
  } else if (SSL_CTX_set_default_verify_paths(ctx) != 1) {
    return -1;
  }
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);

  X509_VERIFY_PARAM *parameters = SSL_get0_param(ssl);
  X509_VERIFY_PARAM_set_hostflags(parameters, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);

  struct in_addr ipv4;
  struct in6_addr ipv6;
  if (inet_pton(AF_INET, verify_host, &ipv4) == 1 || inet_pton(AF_INET6, verify_host, &ipv6) == 1) {
    if (X509_VERIFY_PARAM_set1_ip_asc(parameters, verify_host) != 1) {
      return -1;
    }
  } else {
    if (X509_VERIFY_PARAM_set1_host(parameters, verify_host, 0) != 1) {
      return -1;
    }
    SSL_set_tlsext_host_name(ssl, verify_host);
  }
  return 0;
}

static int convex_ssl_pump(SSL *ssl, int result, int fd, uint64_t deadline) {
  int reason = SSL_get_error(ssl, result);
  if (reason == SSL_ERROR_WANT_READ) {
    return convex_wait_fd(fd, POLLIN, deadline);
  }
  if (reason == SSL_ERROR_WANT_WRITE) {
    return convex_wait_fd(fd, POLLOUT, deadline);
  }
  return -2;
}

LEAN_EXPORT lean_object *convex_shim_connect(b_lean_obj_arg host, uint32_t port, uint8_t use_tls,
                                             b_lean_obj_arg verify_host, b_lean_obj_arg ca_file,
                                             uint64_t deadline, lean_object *world) {
  (void)world;
  convex_ensure_initialised();

  char service[16];
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  char problem[256];
  problem[0] = '\0';

  int fd = convex_connect_socket(lean_string_cstr(host), service, deadline, problem, sizeof(problem));
  if (fd < 0) {
    return convex_fail_fmt("convex shim: could not connect", problem);
  }
  if (!use_tls) {
    return lean_io_result_mk_ok(convex_alloc_conn(fd, NULL, NULL, 0));
  }

  SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
  if (ctx == NULL) {
    close(fd);
    return convex_fail_ssl("convex shim: could not create a TLS context");
  }
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);

  SSL *ssl = SSL_new(ctx);
  if (ssl == NULL) {
    SSL_CTX_free(ctx);
    close(fd);
    return convex_fail_ssl("convex shim: could not create a TLS session");
  }
  if (convex_configure_verification(ctx, ssl, lean_string_cstr(verify_host), lean_string_cstr(ca_file)) < 0) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return convex_fail_ssl("convex shim: could not configure TLS verification");
  }
  SSL_set_fd(ssl, fd);

  for (;;) {
    int result = SSL_connect(ssl);
    if (result == 1) {
      break;
    }
    int waited = convex_ssl_pump(ssl, result, fd, deadline);
    if (waited != 1) {
      SSL_free(ssl);
      SSL_CTX_free(ctx);
      close(fd);
      if (waited == 0) {
        return convex_fail("convex shim: TLS handshake deadline expired");
      }
      return convex_fail_ssl("convex shim: TLS handshake failed");
    }
  }

  /* SSL_set1_host only takes effect when the result is inspected. */
  long verified = SSL_get_verify_result(ssl);
  if (verified != X509_V_OK) {
    const char *reason = X509_verify_cert_error_string(verified);
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return convex_fail_fmt("convex shim: TLS certificate verification failed", reason);
  }

  return lean_io_result_mk_ok(convex_alloc_conn(fd, ssl, ctx, 0));
}

/* ------------------------------------------------------------------ */
/* Connection input and output                                         */
/* ------------------------------------------------------------------ */

LEAN_EXPORT lean_object *convex_shim_conn_fd(b_lean_obj_arg handle, lean_object *world) {
  (void)world;
  convex_conn *conn = convex_conn_of(handle);
  if (conn->fd < 0) {
    return lean_io_result_mk_ok(lean_box_uint32(0xFFFFFFFFu));
  }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)conn->fd));
}

/*
 * TLS records can hold more than one application message, so a poll on the
 * descriptor is not a complete readiness answer. The Lean loop asks this
 * before sleeping.
 */
LEAN_EXPORT lean_object *convex_shim_conn_pending(b_lean_obj_arg handle, lean_object *world) {
  (void)world;
  convex_conn *conn = convex_conn_of(handle);
  int pending = conn->ssl != NULL && SSL_pending(conn->ssl) > 0;
  return lean_io_result_mk_ok(lean_box(pending ? 1 : 0));
}

LEAN_EXPORT lean_object *convex_shim_conn_eof(b_lean_obj_arg handle, lean_object *world) {
  (void)world;
  return lean_io_result_mk_ok(lean_box(convex_conn_of(handle)->eof ? 1 : 0));
}

static lean_object *convex_conn_read_once(convex_conn *conn, uint32_t limit, int blocking,
                                          uint64_t deadline) {
  if (limit > 1048576u) {
    limit = 1048576u;
  }
  if (conn->fd < 0) {
    return convex_fail("convex shim: connection is closed");
  }
  uint8_t *buffer = (uint8_t *)malloc(limit == 0 ? 1 : limit);

  for (;;) {
    ssize_t received;
    if (conn->ssl != NULL) {
      int result = SSL_read(conn->ssl, buffer, (int)limit);
      if (result > 0) {
        lean_object *bytes = convex_mk_bytes(buffer, (size_t)result);
        free(buffer);
        return lean_io_result_mk_ok(convex_mk_some(bytes));
      }
      int reason = SSL_get_error(conn->ssl, result);
      if (reason == SSL_ERROR_ZERO_RETURN) {
        conn->eof = 1;
        free(buffer);
        return lean_io_result_mk_ok(lean_box(0));
      }
      if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
        if (!blocking) {
          free(buffer);
          return lean_io_result_mk_ok(convex_mk_some(convex_mk_bytes(NULL, 0)));
        }
        int waited = convex_wait_fd(conn->fd, reason == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT, deadline);
        if (waited == 1) {
          continue;
        }
        free(buffer);
        if (waited == 0) {
          return convex_fail("convex shim: read deadline expired");
        }
        return convex_fail_fmt("convex shim: poll failed while reading", strerror(errno));
      }
      if (reason == SSL_ERROR_SYSCALL && ERR_peek_last_error() == 0) {
        conn->eof = 1;
        free(buffer);
        return lean_io_result_mk_ok(lean_box(0));
      }
      free(buffer);
      return convex_fail_ssl("convex shim: TLS read failed");
    }

    received = read(conn->fd, buffer, limit);
    if (received > 0) {
      lean_object *bytes = convex_mk_bytes(buffer, (size_t)received);
      free(buffer);
      return lean_io_result_mk_ok(convex_mk_some(bytes));
    }
    if (received == 0) {
      conn->eof = 1;
      free(buffer);
      return lean_io_result_mk_ok(lean_box(0));
    }
    int code = errno;
    if (code == EAGAIN || code == EWOULDBLOCK || code == EINTR) {
      if (!blocking) {
        free(buffer);
        return lean_io_result_mk_ok(convex_mk_some(convex_mk_bytes(NULL, 0)));
      }
      int waited = convex_wait_fd(conn->fd, POLLIN, deadline);
      if (waited == 1) {
        continue;
      }
      free(buffer);
      if (waited == 0) {
        return convex_fail("convex shim: read deadline expired");
      }
      return convex_fail_fmt("convex shim: poll failed while reading", strerror(errno));
    }
    free(buffer);
    return convex_fail_fmt("convex shim: read failed", strerror(code));
  }
}

LEAN_EXPORT lean_object *convex_shim_conn_read(b_lean_obj_arg handle, uint32_t limit, uint64_t deadline,
                                               lean_object *world) {
  (void)world;
  return convex_conn_read_once(convex_conn_of(handle), limit, 1, deadline);
}

LEAN_EXPORT lean_object *convex_shim_conn_read_available(b_lean_obj_arg handle, uint32_t limit,
                                                         lean_object *world) {
  (void)world;
  return convex_conn_read_once(convex_conn_of(handle), limit, 0, 0);
}

LEAN_EXPORT lean_object *convex_shim_conn_write(b_lean_obj_arg handle, b_lean_obj_arg data,
                                                uint64_t deadline, lean_object *world) {
  (void)world;
  convex_conn *conn = convex_conn_of(handle);
  if (conn->fd < 0) {
    return convex_fail("convex shim: connection is closed");
  }
  const uint8_t *bytes = lean_sarray_cptr((lean_object *)data);
  size_t size = lean_sarray_size((lean_object *)data);
  size_t offset = 0;

  while (offset < size) {
    ssize_t written;
    if (conn->ssl != NULL) {
      int result = SSL_write(conn->ssl, bytes + offset, (int)(size - offset));
      if (result > 0) {
        offset += (size_t)result;
        continue;
      }
      int waited = convex_ssl_pump(conn->ssl, result, conn->fd, deadline);
      if (waited == 1) {
        continue;
      }
      if (waited == 0) {
        return convex_fail("convex shim: write deadline expired");
      }
      return convex_fail_ssl("convex shim: TLS write failed");
    }

    written = write(conn->fd, bytes + offset, size - offset);
    if (written > 0) {
      offset += (size_t)written;
      continue;
    }
    int code = errno;
    if (code == EAGAIN || code == EWOULDBLOCK || code == EINTR) {
      int waited = convex_wait_fd(conn->fd, POLLOUT, deadline);
      if (waited == 1) {
        continue;
      }
      if (waited == 0) {
        return convex_fail("convex shim: write deadline expired");
      }
      return convex_fail_fmt("convex shim: poll failed while writing", strerror(errno));
    }
    return convex_fail_fmt("convex shim: write failed", strerror(code));
  }
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_object *convex_shim_conn_close(b_lean_obj_arg handle, lean_object *world) {
  (void)world;
  convex_conn *conn = convex_conn_of(handle);
  if (conn->ssl != NULL) {
    SSL_shutdown(conn->ssl);
  }
  convex_conn_release(conn);
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_object *convex_shim_conn_shutdown_write(b_lean_obj_arg handle, lean_object *world) {
  (void)world;
  convex_conn *conn = convex_conn_of(handle);
  if (conn->fd >= 0) {
    shutdown(conn->fd, SHUT_WR);
  }
  return lean_io_result_mk_ok(lean_box(0));
}

/* ------------------------------------------------------------------ */
/* Listening sockets                                                   */
/* ------------------------------------------------------------------ */

LEAN_EXPORT lean_object *convex_shim_listen(b_lean_obj_arg host, uint32_t port, lean_object *world) {
  (void)world;
  convex_ensure_initialised();

  struct addrinfo hints;
  struct addrinfo *results = NULL;
  char service[16];
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_PASSIVE;

  int resolved = getaddrinfo(lean_string_cstr(host), service, &hints, &results);
  if (resolved != 0) {
    return convex_fail_fmt("convex shim: could not resolve a listen address", gai_strerror(resolved));
  }

  int fd = socket(results->ai_family, results->ai_socktype, results->ai_protocol);
  if (fd < 0) {
    freeaddrinfo(results);
    return convex_fail_fmt("convex shim: could not create a listening socket", strerror(errno));
  }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  if (bind(fd, results->ai_addr, results->ai_addrlen) < 0) {
    int code = errno;
    freeaddrinfo(results);
    close(fd);
    return convex_fail_fmt("convex shim: could not bind", strerror(code));
  }
  freeaddrinfo(results);
  if (listen(fd, 8) < 0) {
    int code = errno;
    close(fd);
    return convex_fail_fmt("convex shim: could not listen", strerror(code));
  }
  return lean_io_result_mk_ok(convex_alloc_conn(fd, NULL, NULL, 1));
}

LEAN_EXPORT lean_object *convex_shim_listen_port(b_lean_obj_arg handle, lean_object *world) {
  (void)world;
  convex_conn *conn = convex_conn_of(handle);
  struct sockaddr_storage address;
  socklen_t length = sizeof(address);
  if (getsockname(conn->fd, (struct sockaddr *)&address, &length) < 0) {
    return convex_fail_fmt("convex shim: could not read the bound port", strerror(errno));
  }
  uint16_t port = 0;
  if (address.ss_family == AF_INET) {
    port = ntohs(((struct sockaddr_in *)&address)->sin_port);
  } else if (address.ss_family == AF_INET6) {
    port = ntohs(((struct sockaddr_in6 *)&address)->sin6_port);
  }
  return lean_io_result_mk_ok(lean_box_uint32(port));
}

LEAN_EXPORT lean_object *convex_shim_accept(b_lean_obj_arg handle, uint64_t deadline, lean_object *world) {
  (void)world;
  convex_conn *conn = convex_conn_of(handle);
  for (;;) {
    int accepted = accept(conn->fd, NULL, NULL);
    if (accepted >= 0) {
      convex_set_nonblocking_fd(accepted);
      int one = 1;
      setsockopt(accepted, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
      return lean_io_result_mk_ok(convex_alloc_conn(accepted, NULL, NULL, 0));
    }
    int code = errno;
    if (code != EAGAIN && code != EWOULDBLOCK && code != EINTR) {
      return convex_fail_fmt("convex shim: accept failed", strerror(code));
    }
    int waited = convex_wait_fd(conn->fd, POLLIN, deadline);
    if (waited == 0) {
      return convex_fail("convex shim: accept deadline expired");
    }
    if (waited < 0) {
      return convex_fail_fmt("convex shim: poll failed while accepting", strerror(errno));
    }
  }
}

/*
 * Server-side TLS exists so the deterministic fixtures can present a real
 * certificate chain. Nothing in the Convex client calls it.
 */
LEAN_EXPORT lean_object *convex_shim_server_handshake(b_lean_obj_arg handle, b_lean_obj_arg certificate,
                                                      b_lean_obj_arg key, uint64_t deadline,
                                                      lean_object *world) {
  (void)world;
  convex_ensure_initialised();
  convex_conn *conn = convex_conn_of(handle);
  if (conn->ssl != NULL) {
    return convex_fail("convex shim: connection already uses TLS");
  }

  SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
  if (ctx == NULL) {
    return convex_fail_ssl("convex shim: could not create a server TLS context");
  }
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  if (SSL_CTX_use_certificate_chain_file(ctx, lean_string_cstr(certificate)) != 1 ||
      SSL_CTX_use_PrivateKey_file(ctx, lean_string_cstr(key), SSL_FILETYPE_PEM) != 1) {
    SSL_CTX_free(ctx);
    return convex_fail_ssl("convex shim: could not load the fixture certificate");
  }

  SSL *ssl = SSL_new(ctx);
  if (ssl == NULL) {
    SSL_CTX_free(ctx);
    return convex_fail_ssl("convex shim: could not create a server TLS session");
  }
  SSL_set_fd(ssl, conn->fd);

  for (;;) {
    int result = SSL_accept(ssl);
    if (result == 1) {
      break;
    }
    int waited = convex_ssl_pump(ssl, result, conn->fd, deadline);
    if (waited != 1) {
      SSL_free(ssl);
      SSL_CTX_free(ctx);
      if (waited == 0) {
        return convex_fail("convex shim: server TLS handshake deadline expired");
      }
      return convex_fail_ssl("convex shim: server TLS handshake failed");
    }
  }

  conn->ssl = ssl;
  conn->ctx = ctx;
  return lean_io_result_mk_ok(lean_box(0));
}
