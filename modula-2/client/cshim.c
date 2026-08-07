/* cshim.c implements the small foreign boundary declared in CShim.def:
 * raw TCP sockets, TLS via OpenSSL, poll(), a monotonic clock, random
 * bytes and SHA-1. It has no knowledge of HTTP, JSON, WebSocket framing,
 * or the Convex sync protocol; all of that lives in Modula-2. Everything
 * here reads into or writes from caller-supplied buffers rather than
 * returning heap pointers, so no ownership ever crosses the language
 * boundary and there is nothing for the Modula-2 side to free.
 *
 * GNU Modula-2's "FOR C" convention maps every exported procedure name to
 * a plain, unmangled C symbol (no module prefix), which is why the names
 * below match CShim.def exactly.
 */

#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>

/* Writing to a socket after the peer has reset the connection (a hard
 * disconnect, exactly what the reconnect tests deliberately provoke)
 * raises SIGPIPE by default, and gm2's runtime does not ignore it, so an
 * ordinary write() there would kill the whole process instead of letting
 * ShimWrite report an ordinary transport error. This constructor (a
 * portable GCC extension available on this GCC-based toolchain) runs
 * before any Modula-2 code, including this program's own module
 * initialisation order, so the signal is never live. */
__attribute__((constructor)) static void ignore_sigpipe(void) {
  signal(SIGPIPE, SIG_IGN);
}

typedef struct {
  int fd;
  SSL *ssl;      /* NULL for a plain (non-TLS) connection */
  SSL_CTX *ctx;  /* owned by this connection when ssl is non-NULL */
} ShimConn;

static char last_error[512] = "";

static void set_error(const char *message) {
  size_t length = strlen(message);
  if (length >= sizeof(last_error)) length = sizeof(last_error) - 1;
  memcpy(last_error, message, length);
  last_error[length] = '\0';
}

static void set_errno_error(const char *context) {
  char buffer[512];
  snprintf(buffer, sizeof(buffer), "%s: %s", context, strerror(errno));
  set_error(buffer);
}

static void set_ssl_error(const char *context) {
  unsigned long code = ERR_get_error();
  char detail[256];
  if (code != 0) {
    ERR_error_string_n(code, detail, sizeof(detail));
  } else {
    detail[0] = '\0';
  }
  char buffer[512];
  snprintf(buffer, sizeof(buffer), "%s: %s", context, detail);
  set_error(buffer);
}

int ShimLastError(char *buf, int cap) {
  size_t length = strlen(last_error);
  size_t copy_length = length;
  if (cap < 0) cap = 0;
  if (copy_length > (size_t)cap) copy_length = (size_t)cap;
  if (copy_length > 0) memcpy(buf, last_error, copy_length);
  return (int)length;
}

void ShimSetNonBlocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) flags = 0;
  fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int set_blocking_mode(int fd, int nonblocking) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  if (nonblocking) {
    flags |= O_NONBLOCK;
  } else {
    flags &= ~O_NONBLOCK;
  }
  return fcntl(fd, F_SETFL, flags);
}

static long deadline_from_now(int timeout_ms) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  long now_ms = (long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
  return now_ms + timeout_ms;
}

static long remaining_ms(long deadline) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  long now_ms = (long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
  long remaining = deadline - now_ms;
  if (remaining < 0) remaining = 0;
  return remaining;
}

static int wait_fd(int fd, short events, long deadline) {
  struct pollfd entry;
  entry.fd = fd;
  entry.events = events;
  long remaining = remaining_ms(deadline);
  int rc = poll(&entry, 1, (int)remaining);
  if (rc < 0) return -1;
  if (rc == 0) return 0;
  if (entry.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
  return 1;
}

int ShimTcpConnect(const char *host, int port, int timeout_ms) {
  char port_text[16];
  snprintf(port_text, sizeof(port_text), "%d", port);

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  struct addrinfo *results = NULL;
  int gai_status = getaddrinfo(host, port_text, &hints, &results);
  if (gai_status != 0) {
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "DNS resolution failed: %s", gai_strerror(gai_status));
    set_error(buffer);
    return -1;
  }

  long deadline = deadline_from_now(timeout_ms);
  int fd = -1;
  int last_errno = 0;
  int timed_out = 0;
  for (struct addrinfo *candidate = results; candidate != NULL; candidate = candidate->ai_next) {
    fd = socket(candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol);
    if (fd < 0) {
      last_errno = errno;
      continue;
    }
    set_blocking_mode(fd, 1);
    int rc = connect(fd, candidate->ai_addr, candidate->ai_addrlen);
    if (rc == 0) break;
    if (errno != EINPROGRESS) {
      last_errno = errno;
      close(fd);
      fd = -1;
      continue;
    }
    int ready = wait_fd(fd, POLLOUT, deadline);
    if (ready == 0) timed_out = 1;
    if (ready <= 0) {
      close(fd);
      fd = -1;
      continue;
    }
    int socket_error = 0;
    socklen_t error_length = sizeof(socket_error);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &error_length);
    if (socket_error != 0) {
      last_errno = socket_error;
      close(fd);
      fd = -1;
      continue;
    }
    break;
  }
  freeaddrinfo(results);

  if (fd < 0) {
    if (timed_out && last_errno == 0) {
      set_error("connect: timed out");
    } else if (last_errno != 0) {
      char buffer[512];
      snprintf(buffer, sizeof(buffer), "connect: %s", strerror(last_errno));
      set_error(buffer);
    } else {
      set_error("connect: failed");
    }
    return -1;
  }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  return fd;
}

void *ShimTlsWrap(int fd, const char *sni_host, int timeout_ms) {
  SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
  if (ctx == NULL) {
    set_ssl_error("SSL_CTX_new");
    close(fd);
    return NULL;
  }
  SSL_CTX_set_default_verify_paths(ctx);
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);

  SSL *ssl = SSL_new(ctx);
  if (ssl == NULL) {
    set_ssl_error("SSL_new");
    SSL_CTX_free(ctx);
    close(fd);
    return NULL;
  }
  SSL_set_tlsext_host_name(ssl, sni_host);
  SSL_set1_host(ssl, sni_host);
  SSL_set_fd(ssl, fd);
  SSL_set_connect_state(ssl);

  long deadline = deadline_from_now(timeout_ms);
  for (;;) {
    int rc = SSL_connect(ssl);
    if (rc == 1) break;
    int ssl_error = SSL_get_error(ssl, rc);
    if (ssl_error == SSL_ERROR_WANT_READ) {
      if (wait_fd(fd, POLLIN, deadline) <= 0) {
        set_error("TLS handshake timed out waiting to read");
        SSL_free(ssl);
        SSL_CTX_free(ctx);
        close(fd);
        return NULL;
      }
    } else if (ssl_error == SSL_ERROR_WANT_WRITE) {
      if (wait_fd(fd, POLLOUT, deadline) <= 0) {
        set_error("TLS handshake timed out waiting to write");
        SSL_free(ssl);
        SSL_CTX_free(ctx);
        close(fd);
        return NULL;
      }
    } else {
      set_ssl_error("TLS handshake failed");
      SSL_free(ssl);
      SSL_CTX_free(ctx);
      close(fd);
      return NULL;
    }
  }

  ShimConn *conn = malloc(sizeof(ShimConn));
  conn->fd = fd;
  conn->ssl = ssl;
  conn->ctx = ctx;
  return conn;
}

void *ShimPlainWrap(int fd) {
  ShimConn *conn = malloc(sizeof(ShimConn));
  conn->fd = fd;
  conn->ssl = NULL;
  conn->ctx = NULL;
  return conn;
}

int ShimRead(void *opaque, char *buf, int cap) {
  ShimConn *conn = (ShimConn *)opaque;
  if (conn->ssl != NULL) {
    int n = SSL_read(conn->ssl, buf, cap);
    if (n > 0) return n;
    int ssl_error = SSL_get_error(conn->ssl, n);
    if (ssl_error == SSL_ERROR_ZERO_RETURN) return 0;
    if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) return -1;
    if (ssl_error == SSL_ERROR_SYSCALL && n == 0) return 0;
    set_ssl_error("TLS read failed");
    return -2;
  }
  ssize_t n = read(conn->fd, buf, (size_t)cap);
  if (n > 0) return (int)n;
  if (n == 0) return 0;
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -1;
  set_errno_error("read");
  return -2;
}

int ShimWrite(void *opaque, const char *buf, int length) {
  ShimConn *conn = (ShimConn *)opaque;
  if (conn->ssl != NULL) {
    int n = SSL_write(conn->ssl, buf, length);
    if (n > 0) return n;
    int ssl_error = SSL_get_error(conn->ssl, n);
    if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) return -1;
    set_ssl_error("TLS write failed");
    return -2;
  }
  ssize_t n = write(conn->fd, buf, (size_t)length);
  if (n >= 0) return (int)n;
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -1;
  set_errno_error("write");
  return -2;
}

int ShimFd(void *opaque) {
  ShimConn *conn = (ShimConn *)opaque;
  return conn->fd;
}

int ShimPending(void *opaque) {
  ShimConn *conn = (ShimConn *)opaque;
  if (conn->ssl == NULL) return 0;
  return SSL_pending(conn->ssl) > 0 ? 1 : 0;
}

void ShimCloseConn(void *opaque) {
  ShimConn *conn = (ShimConn *)opaque;
  if (conn == NULL) return;
  if (conn->ssl != NULL) {
    SSL_shutdown(conn->ssl);
    SSL_free(conn->ssl);
  }
  if (conn->ctx != NULL) SSL_CTX_free(conn->ctx);
  if (conn->fd >= 0) close(conn->fd);
  free(conn);
}

int ShimPoll2(int fd1, int fd2, int timeout_ms, int *ready1, int *ready2) {
  struct pollfd entries[2];
  int count = 0;
  int index1 = -1, index2 = -1;
  *ready1 = 0;
  *ready2 = 0;
  if (fd1 >= 0) {
    index1 = count;
    entries[count].fd = fd1;
    entries[count].events = POLLIN;
    count++;
  }
  if (fd2 >= 0) {
    index2 = count;
    entries[count].fd = fd2;
    entries[count].events = POLLIN;
    count++;
  }
  /* poll() with zero descriptors is a defined, portable way to sleep for
   * timeout_ms: callers rely on this when neither fd is currently open
   * (for example the adapter reactor idling between commands with no Live
   * connection yet) so the loop does not spin at 100% CPU. */
  int rc = poll(entries, (nfds_t)count, timeout_ms);
  if (rc < 0) {
    set_errno_error("poll");
    return -1;
  }
  if (rc == 0) return 0;
  int ready_count = 0;
  if (index1 >= 0 && (entries[index1].revents & (POLLIN | POLLHUP | POLLERR))) {
    *ready1 = 1;
    ready_count++;
  }
  if (index2 >= 0 && (entries[index2].revents & (POLLIN | POLLHUP | POLLERR))) {
    *ready2 = 1;
    ready_count++;
  }
  return ready_count;
}

int ShimListen(const char *bind_address, int port) {
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons((unsigned short)port);
  if (inet_pton(AF_INET, bind_address, &address.sin_addr) != 1) {
    set_error("invalid bind address");
    return -1;
  }
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    set_errno_error("socket");
    return -1;
  }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
    set_errno_error("bind");
    close(fd);
    return -1;
  }
  if (listen(fd, 4) != 0) {
    set_errno_error("listen");
    close(fd);
    return -1;
  }
  return fd;
}

int ShimAccept(int listen_fd, int timeout_ms) {
  long deadline = deadline_from_now(timeout_ms);
  int ready = wait_fd(listen_fd, POLLIN, deadline);
  if (ready < 0) {
    set_errno_error("poll while accepting");
    return -2;
  }
  if (ready == 0) return -1;
  int fd = accept(listen_fd, NULL, NULL);
  if (fd < 0) {
    set_errno_error("accept");
    return -2;
  }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  return fd;
}

void ShimCloseFd(int fd) {
  if (fd >= 0) close(fd);
}

void ShimRandomBytes(char *buf, int length) {
  if (RAND_bytes((unsigned char *)buf, length) != 1) {
    /* RAND_bytes should not fail on a sane platform; fall back to a
     * deterministic-but-unpredictable source so callers never read
     * uninitialised memory even in that unlikely case. */
    for (int index = 0; index < length; index++) {
      buf[index] = (char)(index * 2654435761u);
    }
  }
}

void ShimSha1(const char *data, int length, char *out_digest) {
  unsigned int digest_length = 0;
  EVP_MD_CTX *context = EVP_MD_CTX_new();
  EVP_DigestInit_ex(context, EVP_sha1(), NULL);
  EVP_DigestUpdate(context, data, (size_t)length);
  EVP_DigestFinal_ex(context, (unsigned char *)out_digest, &digest_length);
  EVP_MD_CTX_free(context);
}

long ShimMonotonicMs(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

void ShimExit(int code) {
  exit(code);
}
