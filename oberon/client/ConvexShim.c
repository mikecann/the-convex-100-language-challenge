/* ConvexShim.c implements the small foreign boundary declared in
 * ConvexShim.obn: raw TCP sockets, TLS via OpenSSL, poll(), a monotonic
 * clock, random bytes and SHA-1. It has no knowledge of HTTP, JSON,
 * WebSocket framing, or the Convex sync protocol; all of that lives in
 * Oberon. Everything here reads into or writes from caller-supplied
 * buffers rather than returning heap pointers, so no ownership of raw
 * memory ever crosses the language boundary except the OBNC-managed Conn
 * handle itself (allocated with OBNC_NEW so OBNC's own garbage collector
 * tracks it, exactly like the standard library's extPipes.Stream).
 *
 * OBNC's C interface for a module marked "(*implemented in C*)" generates
 * .obnc/ConvexShim.h from ConvexShim.obn's declarations; every function and
 * type below matches that header exactly.
 */

#define _POSIX_C_SOURCE 200809L

#include ".obnc/ConvexShim.h"

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
 * raises SIGPIPE by default, and OBNC's runtime does not ignore it, so an
 * ordinary write() there would kill the whole process instead of letting
 * Write report an ordinary transport error. This constructor (a portable
 * GCC/Clang extension available on every toolchain OBNC itself requires)
 * runs before any Oberon code, including this program's own module
 * initialisation order, so the signal is never live. */
__attribute__((constructor)) static void ignore_sigpipe(void) {
  signal(SIGPIPE, SIG_IGN);
}

/* The real per-connection state lives in this C-only struct, which starts
 * with the exact fields OBNC's generated struct declares (see
 * ConvexShim__Conn_ in the header) so a ConvexShim__Conn_ pointer can be
 * reinterpreted as a pointer to this larger struct, exactly like the
 * standard library's extPipes.c does for its own Stream type. */
struct RealConn {
  struct ConvexShim__Conn_ base;
  int fd;
  SSL *ssl;     /* NULL for a plain (non-TLS) connection */
  SSL_CTX *ctx; /* owned by this connection when ssl is non-NULL */
};

struct RealConnHeap {
  const OBNC_Td *td;
  struct RealConn fields;
};

/* OBNC's C interface generates only extern declarations of a C-implemented
 * module's own pointer types (see ConvexShim__Conn_id/_ids/_td in the
 * generated header); the module itself must define them once, exactly like
 * the standard library's extPipes.c does for its Stream type. */
const int ConvexShim__Conn_id;
const int *const ConvexShim__Conn_ids[1] = {&ConvexShim__Conn_id};
const OBNC_Td ConvexShim__Conn_td = {ConvexShim__Conn_ids, 1};

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

OBNC_INTEGER ConvexShim__LastError_(char text_[], OBNC_INTEGER text_len) {
  size_t length = strlen(last_error);
  size_t copy_length = length;
  OBNC_INTEGER cap = text_len;
  if (cap < 0) cap = 0;
  if (copy_length > (size_t)cap) copy_length = (size_t)cap;
  if (copy_length > 0) memcpy(text_, last_error, copy_length);
  if ((OBNC_INTEGER)copy_length < text_len) text_[copy_length] = '\0';
  return (OBNC_INTEGER)length;
}

void ConvexShim__SetNonBlocking_(OBNC_INTEGER fd_) {
  int flags = fcntl((int)fd_, F_GETFL, 0);
  if (flags < 0) flags = 0;
  fcntl((int)fd_, F_SETFL, flags | O_NONBLOCK);
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

OBNC_INTEGER ConvexShim__TcpConnect_(const char host_[], OBNC_INTEGER host_len, OBNC_INTEGER port_, OBNC_INTEGER timeoutMs_) {
  char port_text[16];
  snprintf(port_text, sizeof(port_text), "%d", (int)port_);

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  struct addrinfo *results = NULL;
  int gai_status = getaddrinfo(host_, port_text, &hints, &results);
  if (gai_status != 0) {
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "DNS resolution failed: %s", gai_strerror(gai_status));
    set_error(buffer);
    return -1;
  }

  long deadline = deadline_from_now((int)timeoutMs_);
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
  return (OBNC_INTEGER)fd;
}

void ConvexShim__TlsWrap_(OBNC_INTEGER fd_, const char sniHost_[], OBNC_INTEGER sniHost_len, OBNC_INTEGER timeoutMs_, ConvexShim__Conn_ *conn_) {
  int fd = (int)fd_;
  *conn_ = NULL;

  SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
  if (ctx == NULL) {
    set_ssl_error("SSL_CTX_new");
    close(fd);
    return;
  }
  SSL_CTX_set_default_verify_paths(ctx);
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);

  SSL *ssl = SSL_new(ctx);
  if (ssl == NULL) {
    set_ssl_error("SSL_new");
    SSL_CTX_free(ctx);
    close(fd);
    return;
  }
  SSL_set_tlsext_host_name(ssl, sniHost_);
  SSL_set1_host(ssl, sniHost_);
  SSL_set_fd(ssl, fd);
  SSL_set_connect_state(ssl);

  long deadline = deadline_from_now((int)timeoutMs_);
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
        return;
      }
    } else if (ssl_error == SSL_ERROR_WANT_WRITE) {
      if (wait_fd(fd, POLLOUT, deadline) <= 0) {
        set_error("TLS handshake timed out waiting to write");
        SSL_free(ssl);
        SSL_CTX_free(ctx);
        close(fd);
        return;
      }
    } else {
      set_ssl_error("TLS handshake failed");
      SSL_free(ssl);
      SSL_CTX_free(ctx);
      close(fd);
      return;
    }
  }

  struct RealConn *conn;
  OBNC_NEW(conn, &ConvexShim__Conn_td, struct RealConnHeap, OBNC_REGULAR_ALLOC);
  if (conn == NULL) {
    set_error("out of memory");
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return;
  }
  conn->fd = fd;
  conn->ssl = ssl;
  conn->ctx = ctx;
  *conn_ = (ConvexShim__Conn_)conn;
}

void ConvexShim__PlainWrap_(OBNC_INTEGER fd_, ConvexShim__Conn_ *conn_) {
  struct RealConn *conn;
  OBNC_NEW(conn, &ConvexShim__Conn_td, struct RealConnHeap, OBNC_REGULAR_ALLOC);
  if (conn == NULL) {
    set_error("out of memory");
    *conn_ = NULL;
    return;
  }
  conn->fd = (int)fd_;
  conn->ssl = NULL;
  conn->ctx = NULL;
  *conn_ = (ConvexShim__Conn_)conn;
}

OBNC_INTEGER ConvexShim__Read_(ConvexShim__Conn_ conn_, char buf_[], OBNC_INTEGER buf_len, OBNC_INTEGER cap_) {
  struct RealConn *conn = (struct RealConn *)conn_;
  int cap = (int)cap_;
  if (cap > buf_len) cap = (int)buf_len;
  if (conn->ssl != NULL) {
    int n = SSL_read(conn->ssl, buf_, cap);
    if (n > 0) return (OBNC_INTEGER)n;
    int ssl_error = SSL_get_error(conn->ssl, n);
    if (ssl_error == SSL_ERROR_ZERO_RETURN) return 0;
    if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) return -1;
    if (ssl_error == SSL_ERROR_SYSCALL && n == 0) return 0;
    set_ssl_error("TLS read failed");
    return -2;
  }
  ssize_t n = read(conn->fd, buf_, (size_t)cap);
  if (n > 0) return (OBNC_INTEGER)n;
  if (n == 0) return 0;
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -1;
  set_errno_error("read");
  return -2;
}

OBNC_INTEGER ConvexShim__Write_(ConvexShim__Conn_ conn_, char buf_[], OBNC_INTEGER buf_len, OBNC_INTEGER length_) {
  struct RealConn *conn = (struct RealConn *)conn_;
  int length = (int)length_;
  if (length > buf_len) length = (int)buf_len;
  if (conn->ssl != NULL) {
    int n = SSL_write(conn->ssl, buf_, length);
    if (n > 0) return (OBNC_INTEGER)n;
    int ssl_error = SSL_get_error(conn->ssl, n);
    if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) return -1;
    set_ssl_error("TLS write failed");
    return -2;
  }
  ssize_t n = write(conn->fd, buf_, (size_t)length);
  if (n >= 0) return (OBNC_INTEGER)n;
  if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return -1;
  set_errno_error("write");
  return -2;
}

OBNC_INTEGER ConvexShim__Fd_(ConvexShim__Conn_ conn_) {
  struct RealConn *conn = (struct RealConn *)conn_;
  return (OBNC_INTEGER)conn->fd;
}

int ConvexShim__Pending_(ConvexShim__Conn_ conn_) {
  struct RealConn *conn = (struct RealConn *)conn_;
  if (conn->ssl == NULL) return 0;
  return SSL_pending(conn->ssl) > 0 ? 1 : 0;
}

void ConvexShim__CloseConn_(ConvexShim__Conn_ conn_) {
  struct RealConn *conn = (struct RealConn *)conn_;
  if (conn == NULL) return;
  if (conn->ssl != NULL) {
    SSL_shutdown(conn->ssl);
    SSL_free(conn->ssl);
  }
  if (conn->ctx != NULL) SSL_CTX_free(conn->ctx);
  if (conn->fd >= 0) close(conn->fd);
  /* conn itself is OBNC-managed (allocated with OBNC_NEW) and stays
   * reachable until Oberon drops its last reference; it is not freed here. */
}

OBNC_INTEGER ConvexShim__Poll2_(OBNC_INTEGER fd1_, OBNC_INTEGER fd2_, OBNC_INTEGER timeoutMs_, int *ready1_, int *ready2_) {
  struct pollfd entries[2];
  int count = 0;
  int index1 = -1, index2 = -1;
  *ready1_ = 0;
  *ready2_ = 0;
  if (fd1_ >= 0) {
    index1 = count;
    entries[count].fd = (int)fd1_;
    entries[count].events = POLLIN;
    count++;
  }
  if (fd2_ >= 0) {
    index2 = count;
    entries[count].fd = (int)fd2_;
    entries[count].events = POLLIN;
    count++;
  }
  /* poll() with zero descriptors is a defined, portable way to sleep for
   * timeoutMs: callers rely on this when neither fd is currently open (for
   * example the adapter reactor idling between commands with no Live
   * connection yet) so the loop does not spin at 100% CPU. */
  int rc = poll(entries, (nfds_t)count, (int)timeoutMs_);
  if (rc < 0) {
    set_errno_error("poll");
    return -1;
  }
  if (rc == 0) return 0;
  int ready_count = 0;
  if (index1 >= 0 && (entries[index1].revents & (POLLIN | POLLHUP | POLLERR))) {
    *ready1_ = 1;
    ready_count++;
  }
  if (index2 >= 0 && (entries[index2].revents & (POLLIN | POLLHUP | POLLERR))) {
    *ready2_ = 1;
    ready_count++;
  }
  return ready_count;
}

OBNC_INTEGER ConvexShim__Listen_(const char bindAddress_[], OBNC_INTEGER bindAddress_len, OBNC_INTEGER port_) {
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons((unsigned short)port_);
  if (inet_pton(AF_INET, bindAddress_, &address.sin_addr) != 1) {
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
  return (OBNC_INTEGER)fd;
}

OBNC_INTEGER ConvexShim__Accept_(OBNC_INTEGER listenFd_, OBNC_INTEGER timeoutMs_) {
  long deadline = deadline_from_now((int)timeoutMs_);
  int ready = wait_fd((int)listenFd_, POLLIN, deadline);
  if (ready < 0) {
    set_errno_error("poll while accepting");
    return -2;
  }
  if (ready == 0) return -1;
  int fd = accept((int)listenFd_, NULL, NULL);
  if (fd < 0) {
    set_errno_error("accept");
    return -2;
  }
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  return (OBNC_INTEGER)fd;
}

void ConvexShim__CloseFd_(OBNC_INTEGER fd_) {
  if (fd_ >= 0) close((int)fd_);
}

void ConvexShim__RandomBytes_(char buf_[], OBNC_INTEGER buf_len, OBNC_INTEGER length_) {
  int length = (int)length_;
  if (length > buf_len) length = (int)buf_len;
  if (RAND_bytes((unsigned char *)buf_, length) != 1) {
    /* RAND_bytes should not fail on a sane platform; fall back to a
     * deterministic-but-unpredictable source so callers never read
     * uninitialised memory even in that unlikely case. */
    int index;
    for (index = 0; index < length; index++) {
      buf_[index] = (char)(index * 2654435761u);
    }
  }
}

void ConvexShim__Sha1_(char data_[], OBNC_INTEGER data_len, OBNC_INTEGER length_, char outDigest_[], OBNC_INTEGER outDigest_len) {
  unsigned int digest_length = 0;
  EVP_MD_CTX *context = EVP_MD_CTX_new();
  EVP_DigestInit_ex(context, EVP_sha1(), NULL);
  EVP_DigestUpdate(context, data_, (size_t)length_);
  EVP_DigestFinal_ex(context, (unsigned char *)outDigest_, &digest_length);
  EVP_MD_CTX_free(context);
}

static int monotonic_initialized = 0;
static long monotonic_baseline_ms = 0;

OBNC_INTEGER ConvexShim__MonotonicMs_(void) {
  struct timespec now;
  long now_ms;
  clock_gettime(CLOCK_MONOTONIC, &now);
  now_ms = (long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
  if (!monotonic_initialized) {
    monotonic_baseline_ms = now_ms;
    monotonic_initialized = 1;
  }
  return (OBNC_INTEGER)(now_ms - monotonic_baseline_ms);
}

void ConvexShim__Exit_(OBNC_INTEGER code_) {
  exit((int)code_);
}

void ConvexShim__Init(void) {
  /*do nothing*/
}
