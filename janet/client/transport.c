/*
 * Byte transport for the Janet Convex client.
 *
 * Janet's core library deliberately ships TCP sockets without TLS, HTTP, or
 * WebSocket support, so this native module supplies the one missing primitive:
 * a bounded, deadline-driven stream of bytes that is optionally wrapped in a
 * verified TLS session. It also exposes the two cryptographic primitives the
 * WebSocket handshake needs (a CSPRNG and SHA-1) because reimplementing those
 * in Janet would be worse code, not more honest code.
 *
 * Everything above bytes lives in Janet: HTTP/1.1 framing, RFC 6455 framing and
 * validation, JSON, base64, the Convex sync profile, and the adapter protocol.
 * This file must never learn what a Convex request looks like. Keeping the C
 * surface this narrow is what makes the boundary auditable.
 *
 * Every entry point either returns a value or panics with a Janet table shaped
 * {:name "TransportError" :message "..."} so Janet code can classify failures
 * without parsing strings.
 */
/* MSG_NOSIGNAL, and the rest of the Linux socket surface this module uses,
 * are only declared with the GNU feature set. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <janet.h>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509_vfy.h>
#include <openssl/x509v3.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* One read or write call never moves more than this many bytes. Janet loops
 * around the primitive, so a hostile peer cannot make a single call unbounded. */
#define TRANSPORT_CHUNK 65536

/* Guard rails on the arguments themselves, so a Janet-side arithmetic slip
 * cannot turn into an unbounded allocation or an infinite poll. */
#define TRANSPORT_MAX_CHUNK (4 * 1024 * 1024)
#define TRANSPORT_MAX_TIMEOUT_MS 60000

typedef struct {
  int read_fd;
  int write_fd;
  /* Standard input/output is borrowed from the process, never owned, so the
   * garbage collector must not close it out from under the runtime. */
  int owns_fds;
  /* recv()/send() require an actual socket file descriptor: called on a pipe
   * (standard input/output, wired up by cfun_stdio for the shared conformance
   * adapter's stdio transport) they fail with ENOTSOCK rather than behaving
   * like read()/write(). This flag picks the right syscall pair per fd. */
  int is_socket;
  int eof;
  SSL *ssl;
  SSL_CTX *ctx;
} Conn;

typedef struct {
  int fd;
} Listener;

__attribute__((noreturn)) static void fail(const char *name, const char *message) {
  JanetTable *error = janet_table(2);
  janet_table_put(error, janet_ckeywordv("name"), janet_cstringv(name));
  janet_table_put(error, janet_ckeywordv("message"), janet_cstringv(message));
  janet_panicv(janet_wrap_table(error));
  abort(); /* janet_panicv never returns; this only satisfies the attribute. */
}

__attribute__((noreturn)) static void fail_transport(const char *message) {
  fail("TransportError", message);
}

__attribute__((noreturn)) static void fail_protocol(const char *message) {
  fail("ProtocolError", message);
}

/* Copy a Janet byte value into a NUL-terminated C string, rejecting embedded
 * NUL bytes so a host name can never be truncated into a different host. */
static void copy_cstring(const Janet *argv, int32_t n, char *out, size_t size) {
  JanetByteView view = janet_getbytes(argv, n);
  if ((size_t)view.len + 1 > size) fail_protocol("text argument is too long");
  if (memchr(view.bytes, '\0', (size_t)view.len))
    fail_protocol("text argument contains a NUL byte");
  memcpy(out, view.bytes, (size_t)view.len);
  out[view.len] = '\0';
}

static int64_t now_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
  return (int64_t)now.tv_sec * 1000 + (int64_t)(now.tv_nsec / 1000000);
}

/* Wait until `fd` is ready, the absolute deadline passes, or the poll fails.
 * Returns 1 for ready, 0 for deadline reached, -1 for a poll error. */
static int wait_fd(int fd, short events, int64_t deadline) {
  for (;;) {
    int64_t now = now_ms();
    if (now < 0) return -1;
    if (now >= deadline) return 0;
    int64_t remaining = deadline - now;
    if (remaining > 1000) remaining = 1000;
    struct pollfd item;
    item.fd = fd;
    item.events = events;
    item.revents = 0;
    int ready = poll(&item, 1, (int)remaining);
    if (ready > 0) return 1;
    if (ready == 0) continue;
    if (errno != EINTR) return -1;
  }
}

static int set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void conn_release(Conn *conn) {
  if (conn->ssl) {
    SSL_free(conn->ssl);
    conn->ssl = NULL;
  }
  if (conn->ctx) {
    SSL_CTX_free(conn->ctx);
    conn->ctx = NULL;
  }
  if (conn->owns_fds) {
    if (conn->read_fd >= 0) close(conn->read_fd);
    if (conn->write_fd >= 0 && conn->write_fd != conn->read_fd) close(conn->write_fd);
  }
  conn->read_fd = -1;
  conn->write_fd = -1;
  conn->eof = 1;
}

static int conn_gc(void *data, size_t length) {
  (void)length;
  conn_release((Conn *)data);
  return 0;
}

static const JanetAbstractType conn_type = {
  .name = "convex/connection",
  .gc = conn_gc,
  JANET_ATEND_GC
};

static int listener_gc(void *data, size_t length) {
  (void)length;
  Listener *listener = (Listener *)data;
  if (listener->fd >= 0) {
    close(listener->fd);
    listener->fd = -1;
  }
  return 0;
}

static const JanetAbstractType listener_type = {
  .name = "convex/listener",
  .gc = listener_gc,
  JANET_ATEND_GC
};

static Conn *open_conn(const Janet *argv, int32_t n) {
  Conn *conn = janet_getabstract(argv, n, &conn_type);
  if (conn->read_fd < 0 && conn->write_fd < 0) fail_transport("connection is closed");
  return conn;
}

static int64_t checked_timeout(const Janet *argv, int32_t n) {
  int64_t timeout = janet_getinteger64(argv, n);
  if (timeout < 0 || timeout > TRANSPORT_MAX_TIMEOUT_MS)
    fail_protocol("timeout must be between 0 and 60000 milliseconds");
  return timeout;
}

static int is_ip_literal(const char *host) {
  struct in_addr v4;
  struct in6_addr v6;
  return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1;
}

/* Connect one TCP socket with a real deadline. getaddrinfo itself is the only
 * blocking step in this module; the resolver's own timeout bounds it. */
static int connect_tcp(const char *host, int32_t port, int64_t deadline) {
  char service[16];
  snprintf(service, sizeof(service), "%d", (int)port);
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;
  struct addrinfo *candidates = NULL;
  if (getaddrinfo(host, service, &hints, &candidates) != 0 || !candidates) return -1;

  int connected = -1;
  for (struct addrinfo *item = candidates; item && connected < 0; item = item->ai_next) {
    int fd = socket(item->ai_family, item->ai_socktype, item->ai_protocol);
    if (fd < 0) continue;
    if (set_nonblocking(fd) != 0) {
      close(fd);
      continue;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    int result = connect(fd, item->ai_addr, item->ai_addrlen);
    if (result != 0) {
      if (errno != EINPROGRESS && errno != EINTR) {
        close(fd);
        continue;
      }
      if (wait_fd(fd, POLLOUT, deadline) != 1) {
        close(fd);
        continue;
      }
      int error = 0;
      socklen_t length = sizeof(error);
      if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0 || error != 0) {
        close(fd);
        continue;
      }
    }
    connected = fd;
  }
  freeaddrinfo(candidates);
  return connected;
}

/* Drive a TLS handshake on a non-blocking socket until it completes or the
 * absolute deadline passes. Returns 0 on success. */
static int handshake_tls(Conn *conn, int64_t deadline) {
  for (;;) {
    int result = SSL_connect(conn->ssl);
    if (result == 1) return 0;
    int reason = SSL_get_error(conn->ssl, result);
    short events;
    if (reason == SSL_ERROR_WANT_READ) {
      events = POLLIN;
    } else if (reason == SSL_ERROR_WANT_WRITE) {
      events = POLLOUT;
    } else {
      return -1;
    }
    if (wait_fd(conn->read_fd, events, deadline) != 1) return -1;
  }
}

static Janet cfun_connect(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 4);
  char host[256];
  copy_cstring(argv, 0, host, sizeof(host));
  int32_t port = janet_getinteger(argv, 1);
  int use_tls = janet_getboolean(argv, 2);
  int64_t timeout = checked_timeout(argv, 3);
  if (port < 1 || port > 65535) fail_protocol("port must be between 1 and 65535");
  if (host[0] == '\0') fail_protocol("host is required");

  int64_t started = now_ms();
  if (started < 0) fail_transport("monotonic clock is unavailable");
  int64_t deadline = started + timeout;

  /* Allocate the abstract first so a later panic still reaches the collector. */
  Conn *conn = janet_abstract(&conn_type, sizeof(Conn));
  memset(conn, 0, sizeof(Conn));
  conn->read_fd = -1;
  conn->write_fd = -1;
  conn->owns_fds = 1;
  conn->is_socket = 1;

  int fd = connect_tcp(host, port, deadline);
  if (fd < 0) fail_transport("could not establish a TCP connection before the deadline");
  conn->read_fd = fd;
  conn->write_fd = fd;
  if (!use_tls) return janet_wrap_abstract(conn);

  conn->ctx = SSL_CTX_new(TLS_client_method());
  if (!conn->ctx) fail_transport("could not create a TLS context");
  /* Reject everything below TLS 1.2 and require a verified chain. */
  SSL_CTX_set_min_proto_version(conn->ctx, TLS1_2_VERSION);
  SSL_CTX_set_verify(conn->ctx, SSL_VERIFY_PEER, NULL);
  SSL_CTX_set_mode(conn->ctx, SSL_MODE_ENABLE_PARTIAL_WRITE |
                                  SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
  /* Honours SSL_CERT_FILE and SSL_CERT_DIR, which is how the runtime image
   * points OpenSSL at the CA bundle it actually ships. */
  if (SSL_CTX_set_default_verify_paths(conn->ctx) != 1)
    fail_transport("could not load the trusted CA store");

  conn->ssl = SSL_new(conn->ctx);
  if (!conn->ssl) fail_transport("could not create a TLS session");

  X509_VERIFY_PARAM *param = SSL_get0_param(conn->ssl);
  X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
  if (is_ip_literal(host)) {
    /* An IP literal has no SNI name and must match an iPAddress SAN. */
    if (X509_VERIFY_PARAM_set1_ip_asc(param, host) != 1)
      fail_transport("could not require the requested IP address");
  } else {
    if (X509_VERIFY_PARAM_set1_host(param, host, 0) != 1)
      fail_transport("could not require the requested host name");
    if (SSL_set_tlsext_host_name(conn->ssl, host) != 1)
      fail_transport("could not set the TLS server name indication");
  }
  if (SSL_set_fd(conn->ssl, conn->read_fd) != 1)
    fail_transport("could not attach the socket to the TLS session");
  if (handshake_tls(conn, deadline) != 0)
    fail_transport("TLS handshake failed or was not trusted");
  /* Belt and braces: SSL_VERIFY_PEER already aborts on failure, but an explicit
   * check keeps the guarantee obvious to a reviewer. */
  if (SSL_get_verify_result(conn->ssl) != X509_V_OK)
    fail_transport("TLS peer certificate did not verify");
  return janet_wrap_abstract(conn);
}

static Janet cfun_stdio(int32_t argc, Janet *argv) {
  (void)argv;
  janet_fixarity(argc, 0);
  Conn *conn = janet_abstract(&conn_type, sizeof(Conn));
  memset(conn, 0, sizeof(Conn));
  conn->read_fd = STDIN_FILENO;
  conn->write_fd = STDOUT_FILENO;
  conn->owns_fds = 0;
  conn->is_socket = 0;
  if (set_nonblocking(conn->read_fd) != 0 || set_nonblocking(conn->write_fd) != 0)
    fail_transport("could not put standard input/output into non-blocking mode");
  return janet_wrap_abstract(conn);
}

static Janet cfun_listen(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  char host[256];
  copy_cstring(argv, 0, host, sizeof(host));
  int32_t port = janet_getinteger(argv, 1);
  if (port < 0 || port > 65535) fail_protocol("port must be between 0 and 65535");

  char service[16];
  snprintf(service, sizeof(service), "%d", (int)port);
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_PASSIVE;
  struct addrinfo *candidates = NULL;
  if (getaddrinfo(host[0] ? host : NULL, service, &hints, &candidates) != 0 || !candidates)
    fail_transport("could not resolve the listen address");

  int bound = -1;
  for (struct addrinfo *item = candidates; item && bound < 0; item = item->ai_next) {
    int fd = socket(item->ai_family, item->ai_socktype, item->ai_protocol);
    if (fd < 0) continue;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(fd, item->ai_addr, item->ai_addrlen) != 0 || listen(fd, 4) != 0) {
      close(fd);
      continue;
    }
    if (set_nonblocking(fd) != 0) {
      close(fd);
      continue;
    }
    bound = fd;
  }
  freeaddrinfo(candidates);
  if (bound < 0) fail_transport("could not bind the listen address");

  Listener *listener = janet_abstract(&listener_type, sizeof(Listener));
  listener->fd = bound;
  return janet_wrap_abstract(listener);
}

/* Report the port a listener actually bound, so tests can ask for port 0 and
 * never collide with a port another test in the same image is using. */
static Janet cfun_listen_port(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  Listener *listener = janet_getabstract(argv, 0, &listener_type);
  if (listener->fd < 0) fail_transport("listener is closed");
  struct sockaddr_storage address;
  socklen_t length = sizeof(address);
  if (getsockname(listener->fd, (struct sockaddr *)&address, &length) != 0)
    fail_transport("could not read the bound listen address");
  if (address.ss_family == AF_INET)
    return janet_wrap_integer(ntohs(((struct sockaddr_in *)&address)->sin_port));
  if (address.ss_family == AF_INET6)
    return janet_wrap_integer(ntohs(((struct sockaddr_in6 *)&address)->sin6_port));
  fail_transport("listener is not an IP socket");
  return janet_wrap_nil();
}

static Janet cfun_accept(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 2);
  Listener *listener = janet_getabstract(argv, 0, &listener_type);
  int64_t timeout = checked_timeout(argv, 1);
  if (listener->fd < 0) fail_transport("listener is closed");
  int64_t started = now_ms();
  if (started < 0) fail_transport("monotonic clock is unavailable");
  int64_t deadline = started + timeout;
  for (;;) {
    int fd = accept(listener->fd, NULL, NULL);
    if (fd >= 0) {
      if (set_nonblocking(fd) != 0) {
        close(fd);
        fail_transport("could not put the accepted socket into non-blocking mode");
      }
      Conn *conn = janet_abstract(&conn_type, sizeof(Conn));
      memset(conn, 0, sizeof(Conn));
      conn->read_fd = fd;
      conn->write_fd = fd;
      conn->owns_fds = 1;
      conn->is_socket = 1;
      return janet_wrap_abstract(conn);
    }
    if (errno == EINTR) continue;
    if (errno != EAGAIN && errno != EWOULDBLOCK) fail_transport("accept failed");
    if (wait_fd(listener->fd, POLLIN, deadline) != 1) return janet_wrap_nil();
  }
}

static Janet cfun_read(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 4);
  Conn *conn = open_conn(argv, 0);
  JanetBuffer *out = janet_getbuffer(argv, 1);
  int64_t maximum = janet_getinteger64(argv, 2);
  int64_t timeout = checked_timeout(argv, 3);
  if (maximum < 1 || maximum > TRANSPORT_MAX_CHUNK)
    fail_protocol("read size must be between 1 and 4 MiB");
  if (conn->eof) return janet_wrap_nil();
  if (conn->read_fd < 0) fail_transport("connection is not readable");

  int64_t started = now_ms();
  if (started < 0) fail_transport("monotonic clock is unavailable");
  int64_t deadline = started + timeout;
  size_t want = (size_t)(maximum < TRANSPORT_CHUNK ? maximum : TRANSPORT_CHUNK);
  uint8_t chunk[TRANSPORT_CHUNK];

  for (;;) {
    ssize_t received = -1;
    short events = POLLIN;
    if (conn->ssl) {
      size_t moved = 0;
      int result = SSL_read_ex(conn->ssl, chunk, want, &moved);
      if (result == 1) {
        received = (ssize_t)moved;
      } else {
        int reason = SSL_get_error(conn->ssl, result);
        if (reason == SSL_ERROR_WANT_READ) {
          events = POLLIN;
        } else if (reason == SSL_ERROR_WANT_WRITE) {
          events = POLLOUT;
        } else if (reason == SSL_ERROR_ZERO_RETURN) {
          conn->eof = 1;
          return janet_wrap_nil();
        } else if (reason == SSL_ERROR_SYSCALL && ERR_peek_error() == 0) {
          /* A peer that vanished without close_notify is still end of stream. */
          conn->eof = 1;
          return janet_wrap_nil();
        } else {
          fail_transport("TLS read failed");
        }
      }
    } else {
      /* recv() requires a real socket; the stdio transport wraps a pipe, so
       * that path uses read() instead (see the is_socket comment above). */
      ssize_t moved = conn->is_socket ? recv(conn->read_fd, chunk, want, 0)
                                       : read(conn->read_fd, chunk, want);
      if (moved > 0) {
        received = moved;
      } else if (moved == 0) {
        conn->eof = 1;
        return janet_wrap_nil();
      } else if (errno == EINTR) {
        continue;
      } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
        events = POLLIN;
      } else {
        fail_transport(conn->is_socket ? "socket read failed" : "read failed");
      }
    }
    if (received >= 0) {
      if (received > 0) janet_buffer_push_bytes(out, chunk, (int32_t)received);
      return janet_wrap_integer((int32_t)received);
    }
    int ready = wait_fd(conn->read_fd, events, deadline);
    if (ready == 0) return janet_wrap_integer(0);
    if (ready < 0) fail_transport("socket poll failed");
  }
}

static Janet cfun_write(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 4);
  Conn *conn = open_conn(argv, 0);
  JanetByteView data = janet_getbytes(argv, 1);
  int64_t offset = janet_getinteger64(argv, 2);
  int64_t timeout = checked_timeout(argv, 3);
  if (offset < 0 || offset > (int64_t)data.len) fail_protocol("write offset is out of range");
  if (conn->write_fd < 0) fail_transport("connection is not writable");

  size_t remaining = (size_t)((int64_t)data.len - offset);
  if (remaining == 0) return janet_wrap_integer(0);
  if (remaining > TRANSPORT_CHUNK) remaining = TRANSPORT_CHUNK;

  int64_t started = now_ms();
  if (started < 0) fail_transport("monotonic clock is unavailable");
  int64_t deadline = started + timeout;
  const uint8_t *bytes = data.bytes + offset;

  for (;;) {
    ssize_t sent = -1;
    short events = POLLOUT;
    if (conn->ssl) {
      size_t moved = 0;
      int result = SSL_write_ex(conn->ssl, bytes, remaining, &moved);
      if (result == 1) {
        sent = (ssize_t)moved;
      } else {
        int reason = SSL_get_error(conn->ssl, result);
        if (reason == SSL_ERROR_WANT_READ) {
          events = POLLIN;
        } else if (reason == SSL_ERROR_WANT_WRITE) {
          events = POLLOUT;
        } else {
          fail_transport("TLS write failed");
        }
      }
    } else {
      /* send() requires a real socket; the stdio transport wraps a pipe, so
       * that path uses write() instead. SIGPIPE is already ignored process
       * wide (see below), so a reader that went away surfaces as EPIPE here
       * rather than killing the adapter, matching send()'s MSG_NOSIGNAL. */
      ssize_t moved = conn->is_socket
                          ? send(conn->write_fd, bytes, remaining, MSG_NOSIGNAL)
                          : write(conn->write_fd, bytes, remaining);
      if (moved >= 0) {
        sent = moved;
      } else if (errno == EINTR) {
        continue;
      } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
        events = POLLOUT;
      } else {
        fail_transport(conn->is_socket ? "socket write failed" : "write failed");
      }
    }
    if (sent >= 0) return janet_wrap_integer((int32_t)sent);
    int ready = wait_fd(conn->write_fd, events, deadline);
    if (ready == 0) return janet_wrap_integer(0);
    if (ready < 0) fail_transport("socket poll failed");
  }
}

static Janet cfun_close(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  if (janet_checkabstract(argv[0], &listener_type)) {
    Listener *listener = janet_getabstract(argv, 0, &listener_type);
    if (listener->fd >= 0) {
      close(listener->fd);
      listener->fd = -1;
    }
    return janet_wrap_true();
  }
  Conn *conn = janet_getabstract(argv, 0, &conn_type);
  conn_release(conn);
  return janet_wrap_true();
}

static Janet cfun_closed(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  Conn *conn = janet_getabstract(argv, 0, &conn_type);
  return janet_wrap_boolean(conn->read_fd < 0 && conn->write_fd < 0);
}

static Janet cfun_tls(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  Conn *conn = janet_getabstract(argv, 0, &conn_type);
  return janet_wrap_boolean(conn->ssl != NULL);
}

static Janet cfun_monotonic_ms(int32_t argc, Janet *argv) {
  (void)argv;
  janet_fixarity(argc, 0);
  int64_t now = now_ms();
  if (now < 0) fail_transport("monotonic clock is unavailable");
  return janet_wrap_number((double)now);
}

static Janet cfun_random(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  int32_t count = janet_getinteger(argv, 0);
  if (count < 1 || count > 1024) fail_protocol("random byte count must be 1 to 1024");
  uint8_t buffer[1024];
  if (RAND_bytes(buffer, count) != 1) fail_transport("the CSPRNG failed");
  return janet_wrap_string(janet_string(buffer, count));
}

/* SHA-1 exists here only because RFC 6455's handshake defines its accept value
 * in terms of it. It is not used for anything security-sensitive. */
static Janet cfun_sha1(int32_t argc, Janet *argv) {
  janet_fixarity(argc, 1);
  JanetByteView data = janet_getbytes(argv, 0);
  uint8_t digest[EVP_MAX_MD_SIZE];
  unsigned int length = 0;
  if (EVP_Digest(data.bytes, (size_t)data.len, digest, &length, EVP_sha1(), NULL) != 1)
    fail_transport("SHA-1 digest failed");
  return janet_wrap_string(janet_string(digest, (int32_t)length));
}

/* Resident set size in bytes, used by the stopped-reader memory proof. Returns
 * nil where /proc is unavailable so the test can report that honestly. */
static Janet cfun_resident_bytes(int32_t argc, Janet *argv) {
  (void)argv;
  janet_fixarity(argc, 0);
  FILE *status = fopen("/proc/self/statm", "r");
  if (!status) return janet_wrap_nil();
  long pages = 0;
  long resident = 0;
  int scanned = fscanf(status, "%ld %ld", &pages, &resident);
  fclose(status);
  if (scanned != 2) return janet_wrap_nil();
  long page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0) return janet_wrap_nil();
  return janet_wrap_number((double)resident * (double)page_size);
}

static const JanetReg transport_cfuns[] = {
  {"connect", cfun_connect,
   "(transport/connect host port tls? timeout-ms)\n\n"
   "Open a TCP connection, optionally wrapped in a verified TLS session."},
  {"stdio", cfun_stdio,
   "(transport/stdio)\n\n"
   "Borrow standard input and output as one non-blocking connection."},
  {"listen", cfun_listen,
   "(transport/listen host port)\n\nBind and listen on an address."},
  {"listen-port", cfun_listen_port,
   "(transport/listen-port listener)\n\nReport the port a listener bound."},
  {"accept", cfun_accept,
   "(transport/accept listener timeout-ms)\n\n"
   "Accept one connection, or return nil at the deadline."},
  {"read", cfun_read,
   "(transport/read conn buffer max-bytes timeout-ms)\n\n"
   "Append at most max-bytes to buffer. Returns the count, 0 at the deadline, "
   "or nil at end of stream."},
  {"write", cfun_write,
   "(transport/write conn bytes offset timeout-ms)\n\n"
   "Write once from bytes at offset. Returns the count written, possibly 0."},
  {"close", cfun_close, "(transport/close conn-or-listener)\n\nRelease a handle."},
  {"closed?", cfun_closed, "(transport/closed? conn)\n\nHas the handle been released?"},
  {"tls?", cfun_tls, "(transport/tls? conn)\n\nIs this connection TLS protected?"},
  {"monotonic-ms", cfun_monotonic_ms,
   "(transport/monotonic-ms)\n\nMonotonic milliseconds for absolute deadlines."},
  {"random", cfun_random, "(transport/random count)\n\nCSPRNG bytes."},
  {"sha1", cfun_sha1, "(transport/sha1 bytes)\n\nSHA-1 digest for the RFC 6455 handshake."},
  {"resident-bytes", cfun_resident_bytes,
   "(transport/resident-bytes)\n\nResident set size in bytes, or nil."},
  {NULL, NULL, NULL}
};

JANET_MODULE_ENTRY(JanetTable *env) {
  /* A peer that disappears mid-write must surface as an error value, never as
   * a signal that kills the adapter and loses its structured close event. */
  signal(SIGPIPE, SIG_IGN);
  janet_cfuns(env, "convex/transport", transport_cfuns);
}
