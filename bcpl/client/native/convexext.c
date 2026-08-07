/*
convexext.c -- the whole native surface of the BCPL Convex client.

BCPL (1967) predates sockets, TLS and even the notion of a byte-addressed
network stack, and no BCPL implementation offers any of them. Martin Richards'
Cintcode distribution anticipates exactly this situation: sysc/extfn.c is
documented as "This file can be modified by users to provide any extension to
the BCPL library that the user would like", reachable from BCPL as

    res := sys(Sys_ext, fno, a1, a2, ...)

This file replaces that stub. It is deliberately the *only* C in the client and
it deliberately knows nothing about Convex. It moves bytes and reports time:

  * name resolution, TCP connect, TLS handshake and verification
  * byte reads and writes against an absolute deadline
  * a listening socket for the conformance adapter's TCP mode
  * a monotonic millisecond clock, readiness waiting, and secure random bytes
  * access to the process environment

HTTP/1.1, RFC 6455 WebSocket framing, SHA-1, base64, JSON, the Convex sync
protocol, reconnect and every bound and deadline policy live in BCPL. Nothing
here parses or generates a Convex message.

Cintcode addressing note: a BCPL pointer is a word index into the Cintcode
memory W, so the machine address of BCPL byte `p%off` is (char *)(W + p) + off.
That is the same convention cintsys.c uses for sys(Sys_read, ...).

64-bit Cintcode note: this client links against the distribution's 64-bit
Cintcode system (cintsys64.c / cinterp64.c / cfuncs64.c / kblib64.c /
nrastlib64.c, selected by -DforLinux64 -DforLinuxAMD64), not the 32-bit one.
The 32-bit interpreter stores a raw C pointer -- such as the stdio FILE* a
file-handling primitive receives from fopen() -- directly inside a 32-bit
BCPL word; on a 64-bit host a heap or mmap address routinely lands above
2**32, so the low 32 bits alone are not a valid pointer and dereferencing the
reconstructed value corrupts memory (observed directly: a SIGSEGV inside libc
ftell(), called with a sign-extended garbage FILE*, before any client source
ever ran). The 64-bit interpreter uses a 64-bit BCPLWORD that a real pointer
fits in natively, which is why this client targets it instead of working
around the 32-bit interpreter's pointer truncation. One vendor gap remains:
the pinned commit's cintsys64.c dosys() switch never received the 2014
Sys_ext addition that cintsys.c has, so the Dockerfile patches in a `case 68`
(Sys_ext's value in g/libhdr.h) that calls extfn() exactly as the 32-bit
interpreter does; see the Dockerfile for that patch and its anchor assertion.
*/

#include "cintsys64.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
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

extern char *b2c_str(BCPLWORD bstr, char *cstr);
extern void c2b_str(char *cstr, BCPLWORD bstr);

/* Function numbers. These must agree with client/convexhdr.h. */
#define EXT_Avail 0
#define EXT_Init 1
#define EXT_Testfn 2

#define CX_Now 100
#define CX_Getenv 101
#define CX_Random 102
#define CX_Connect 103
#define CX_Read 104
#define CX_Write 105
#define CX_Close 106
#define CX_Listen 107
#define CX_Accept 108
#define CX_Wait 109
#define CX_Errtext 110
#define CX_Tlsavail 111

/* Result codes shared with BCPL. Byte counts are returned as non-negative
   values, so every failure is strictly negative and 0 always means "peer
   closed cleanly". */
#define CX_EOF 0
#define CX_TIMEOUT (-1)
#define CX_ERROR (-2)
#define CX_BADHANDLE (-3)

/* A deliberately small fixed table. The client never needs more than a control
   connection, a listener and one Live socket, and a fixed table means the
   native layer cannot grow without bound however hostile the peer is. */
#define CX_MAXHANDLES 16
#define CX_FIRSTSOCKET 3

/* Handles 0, 1 and 2 are installed by EXT_Init and are never sockets:
   0 = control input, 1 = protocol output, 2 = diagnostics. Keeping the
   protocol output as a handle lets the launcher hand us the real stdout while
   the Cintcode system's own console chatter is redirected to stderr. */
struct cxhandle {
  int inuse;
  int fd;
  int islisten;
  SSL *ssl;
  SSL_CTX *ctx;
};

static struct cxhandle handles[CX_MAXHANDLES];
static int cxinitialised = 0;
static struct timespec cxepoch;
static char cxerror[256] = "";

static void cxseterror(const char *what, const char *detail) {
  if (detail == NULL || *detail == '\0') {
    snprintf(cxerror, sizeof(cxerror), "%s", what);
  } else {
    snprintf(cxerror, sizeof(cxerror), "%s: %s", what, detail);
  }
}

static void cxseterrno(const char *what) { cxseterror(what, strerror(errno)); }

static void cxsetsslerror(const char *what) {
  unsigned long code = ERR_get_error();
  char buffer[160];
  if (code == 0) {
    cxseterror(what, "TLS error");
    return;
  }
  ERR_error_string_n(code, buffer, sizeof(buffer));
  ERR_clear_error();
  cxseterror(what, buffer);
}

/* Milliseconds since EXT_Init. A monotonic clock relative to process start,
   rather than the wall-clock epoch, keeps every deadline comfortably inside a
   single Cintcode word on this 64-bit Cintcode build. */
static BCPLWORD cxnow(void) {
  struct timespec now;
  long long ms;
  clock_gettime(CLOCK_MONOTONIC, &now);
  ms = (long long)(now.tv_sec - cxepoch.tv_sec) * 1000LL +
       (long long)(now.tv_nsec - cxepoch.tv_nsec) / 1000000LL;
  if (ms < 0) ms = 0;
  return (BCPLWORD)ms;
}

/* Deadlines arrive as absolute CX_Now values. A deadline that has already
   passed yields a zero timeout rather than a negative (infinite) one, so an
   expired deadline can never block. */
static int cxremaining(BCPLWORD deadline) {
  BCPLWORD left = deadline - cxnow();
  if (left < 0) return 0;
  if (left > 600000) return 600000;
  return (int)left;
}

static struct cxhandle *cxslot(BCPLWORD handle) {
  if (handle < 0 || handle >= CX_MAXHANDLES) return NULL;
  if (!handles[handle].inuse) return NULL;
  return &handles[handle];
}

static BCPLWORD cxalloc(int fd) {
  BCPLWORD index;
  for (index = CX_FIRSTSOCKET; index < CX_MAXHANDLES; index++) {
    if (!handles[index].inuse) {
      handles[index].inuse = 1;
      handles[index].fd = fd;
      handles[index].islisten = 0;
      handles[index].ssl = NULL;
      handles[index].ctx = NULL;
      return index;
    }
  }
  cxseterror("connect", "no free transport handle");
  return CX_ERROR;
}

static void cxrelease(struct cxhandle *slot) {
  if (slot->ssl != NULL) {
    SSL_free(slot->ssl);
    slot->ssl = NULL;
  }
  if (slot->ctx != NULL) {
    SSL_CTX_free(slot->ctx);
    slot->ctx = NULL;
  }
  if (slot->fd >= 0) close(slot->fd);
  slot->fd = -1;
  slot->inuse = 0;
  slot->islisten = 0;
}

static int cxnonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* Wait for one descriptor. Returns 1 ready, 0 timed out, -1 failed. EINTR is
   retried against the same absolute deadline so a signal cannot silently
   shorten or extend a caller's deadline. */
static int cxpoll(int fd, int forwrite, BCPLWORD deadline) {
  struct pollfd entry;
  for (;;) {
    int result;
    entry.fd = fd;
    entry.events = (short)(forwrite ? POLLOUT : POLLIN);
    entry.revents = 0;
    result = poll(&entry, 1, cxremaining(deadline));
    if (result > 0) return 1;
    if (result == 0) return 0;
    if (errno == EINTR) continue;
    cxseterrno("poll");
    return -1;
  }
}

static BCPLWORD cxconnecttcp(const char *host, int port, BCPLWORD deadline) {
  struct addrinfo hints;
  struct addrinfo *list = NULL;
  struct addrinfo *entry = NULL;
  char service[16];
  int status;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  snprintf(service, sizeof(service), "%d", port);

  status = getaddrinfo(host, service, &hints, &list);
  if (status != 0) {
    cxseterror("resolve", gai_strerror(status));
    return CX_ERROR;
  }

  for (entry = list; entry != NULL; entry = entry->ai_next) {
    int fd = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
    int flag = 1;
    if (fd < 0) {
      cxseterrno("socket");
      continue;
    }
    if (cxnonblocking(fd) < 0) {
      cxseterrno("nonblocking");
      close(fd);
      continue;
    }
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));

    if (connect(fd, entry->ai_addr, entry->ai_addrlen) == 0) {
      freeaddrinfo(list);
      return cxalloc(fd);
    }
    if (errno == EINPROGRESS || errno == EINTR) {
      int ready = cxpoll(fd, 1, deadline);
      if (ready > 0) {
        int soerror = 0;
        socklen_t length = sizeof(soerror);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerror, &length) == 0 &&
            soerror == 0) {
          freeaddrinfo(list);
          return cxalloc(fd);
        }
        errno = soerror;
        cxseterrno("connect");
      } else if (ready == 0) {
        cxseterror("connect", "deadline expired");
        close(fd);
        freeaddrinfo(list);
        return CX_TIMEOUT;
      }
    } else {
      cxseterrno("connect");
    }
    close(fd);
  }

  freeaddrinfo(list);
  if (cxerror[0] == '\0') cxseterror("connect", "no usable address");
  return CX_ERROR;
}

/* Drive a non-blocking TLS handshake to completion, or to the deadline. */
static int cxhandshake(struct cxhandle *slot, BCPLWORD deadline) {
  for (;;) {
    int result = SSL_connect(slot->ssl);
    int reason;
    if (result == 1) return 0;
    reason = SSL_get_error(slot->ssl, result);
    if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
      int ready = cxpoll(slot->fd, reason == SSL_ERROR_WANT_WRITE, deadline);
      if (ready > 0) continue;
      if (ready == 0) {
        cxseterror("tls-handshake", "deadline expired");
        return CX_TIMEOUT;
      }
      return CX_ERROR;
    }
    cxsetsslerror("tls-handshake");
    return CX_ERROR;
  }
}

static BCPLWORD cxconnect(const char *host, int port, int usetls,
                          BCPLWORD deadline) {
  BCPLWORD handle = cxconnecttcp(host, port, deadline);
  struct cxhandle *slot;
  int status;

  if (handle < 0) return handle;
  if (!usetls) return handle;

  slot = &handles[handle];
  slot->ctx = SSL_CTX_new(TLS_client_method());
  if (slot->ctx == NULL) {
    cxsetsslerror("tls-context");
    cxrelease(slot);
    return CX_ERROR;
  }
  /* Verification is on and the hostname is checked, so a Convex deployment URL
     really is authenticated rather than merely encrypted. */
  SSL_CTX_set_min_proto_version(slot->ctx, TLS1_2_VERSION);
  if (SSL_CTX_set_default_verify_paths(slot->ctx) != 1) {
    cxsetsslerror("tls-truststore");
    cxrelease(slot);
    return CX_ERROR;
  }
  SSL_CTX_set_verify(slot->ctx, SSL_VERIFY_PEER, NULL);

  slot->ssl = SSL_new(slot->ctx);
  if (slot->ssl == NULL) {
    cxsetsslerror("tls-session");
    cxrelease(slot);
    return CX_ERROR;
  }
  SSL_set_fd(slot->ssl, slot->fd);
  SSL_set_tlsext_host_name(slot->ssl, host);
  if (SSL_set1_host(slot->ssl, host) != 1) {
    cxsetsslerror("tls-hostname");
    cxrelease(slot);
    return CX_ERROR;
  }

  status = cxhandshake(slot, deadline);
  if (status != 0) {
    cxrelease(slot);
    return status;
  }
  if (SSL_get_verify_result(slot->ssl) != X509_V_OK) {
    cxseterror("tls-verify", "peer certificate was not accepted");
    cxrelease(slot);
    return CX_ERROR;
  }
  return handle;
}

static BCPLWORD cxread(struct cxhandle *slot, char *buffer, int length,
                       BCPLWORD deadline) {
  for (;;) {
    if (slot->ssl != NULL) {
      int result = SSL_read(slot->ssl, buffer, length);
      int reason;
      if (result > 0) return (BCPLWORD)result;
      reason = SSL_get_error(slot->ssl, result);
      if (reason == SSL_ERROR_ZERO_RETURN) return CX_EOF;
      if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
        int ready = cxpoll(slot->fd, reason == SSL_ERROR_WANT_WRITE, deadline);
        if (ready > 0) continue;
        if (ready == 0) return CX_TIMEOUT;
        return CX_ERROR;
      }
      if (reason == SSL_ERROR_SYSCALL && result == 0) return CX_EOF;
      cxsetsslerror("tls-read");
      return CX_ERROR;
    } else {
      ssize_t result = read(slot->fd, buffer, (size_t)length);
      if (result > 0) return (BCPLWORD)result;
      if (result == 0) return CX_EOF;
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        int ready = cxpoll(slot->fd, 0, deadline);
        if (ready > 0) continue;
        if (ready == 0) return CX_TIMEOUT;
        return CX_ERROR;
      }
      cxseterrno("read");
      return CX_ERROR;
    }
  }
}

/* Writes are all-or-deadline: a short write is retried until the whole slice
   has been handed to the peer or the caller's deadline expires. Returning a
   partial count would force every BCPL caller to re-derive the same loop. */
static BCPLWORD cxwrite(struct cxhandle *slot, const char *buffer, int length,
                        BCPLWORD deadline) {
  int sent = 0;
  while (sent < length) {
    if (slot->ssl != NULL) {
      int result = SSL_write(slot->ssl, buffer + sent, length - sent);
      int reason;
      if (result > 0) {
        sent += result;
        continue;
      }
      reason = SSL_get_error(slot->ssl, result);
      if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
        int ready = cxpoll(slot->fd, reason != SSL_ERROR_WANT_READ, deadline);
        if (ready > 0) continue;
        if (ready == 0) return CX_TIMEOUT;
        return CX_ERROR;
      }
      cxsetsslerror("tls-write");
      return CX_ERROR;
    } else {
      ssize_t result = write(slot->fd, buffer + sent, (size_t)(length - sent));
      if (result > 0) {
        sent += (int)result;
        continue;
      }
      if (result < 0 && errno == EINTR) continue;
      if (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        int ready = cxpoll(slot->fd, 1, deadline);
        if (ready > 0) continue;
        if (ready == 0) return CX_TIMEOUT;
        return CX_ERROR;
      }
      cxseterrno("write");
      return CX_ERROR;
    }
  }
  return (BCPLWORD)sent;
}

static BCPLWORD cxlisten(const char *host, int port) {
  struct addrinfo hints;
  struct addrinfo *list = NULL;
  struct addrinfo *entry = NULL;
  char service[16];
  int status;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_PASSIVE;
  snprintf(service, sizeof(service), "%d", port);

  status = getaddrinfo(host[0] == '\0' ? NULL : host, service, &hints, &list);
  if (status != 0) {
    cxseterror("listen-resolve", gai_strerror(status));
    return CX_ERROR;
  }

  for (entry = list; entry != NULL; entry = entry->ai_next) {
    int fd = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
    int flag = 1;
    BCPLWORD handle;
    if (fd < 0) {
      cxseterrno("listen-socket");
      continue;
    }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &flag, sizeof(flag));
    if (bind(fd, entry->ai_addr, entry->ai_addrlen) != 0) {
      cxseterrno("bind");
      close(fd);
      continue;
    }
    if (listen(fd, 4) != 0) {
      cxseterrno("listen");
      close(fd);
      continue;
    }
    if (cxnonblocking(fd) < 0) {
      cxseterrno("listen-nonblocking");
      close(fd);
      continue;
    }
    handle = cxalloc(fd);
    if (handle < 0) {
      close(fd);
      freeaddrinfo(list);
      return handle;
    }
    handles[handle].islisten = 1;
    freeaddrinfo(list);
    return handle;
  }

  freeaddrinfo(list);
  return CX_ERROR;
}

static BCPLWORD cxaccept(struct cxhandle *slot, BCPLWORD deadline) {
  for (;;) {
    int fd = accept(slot->fd, NULL, NULL);
    int flag = 1;
    if (fd >= 0) {
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
      if (cxnonblocking(fd) < 0) {
        cxseterrno("accept-nonblocking");
        close(fd);
        return CX_ERROR;
      }
      return cxalloc(fd);
    }
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      int ready = cxpoll(slot->fd, 0, deadline);
      if (ready > 0) continue;
      if (ready == 0) return CX_TIMEOUT;
      return CX_ERROR;
    }
    cxseterrno("accept");
    return CX_ERROR;
  }
}

/* Wait on up to two handles at once. The adapter uses this to interleave the
   controller connection and the Live socket without threads, which BCPL does
   not have. Returns a bitmask: 1 for the first handle, 2 for the second.

   Waiting on no handle at all is a plain sleep to the deadline rather than an
   immediate return. BCPL has no sleep of its own, and returning at once would
   turn every "wait until the reconnect backoff expires" into a spin at the
   speed of the interpreter. */
static BCPLWORD cxwait(BCPLWORD first, BCPLWORD second, BCPLWORD deadline) {
  struct pollfd entries[2];
  int count = 0;
  int firstindex = -1;
  int secondindex = -1;
  struct cxhandle *slot;

  slot = cxslot(first);
  if (slot != NULL) {
    entries[count].fd = slot->fd;
    entries[count].events = POLLIN;
    entries[count].revents = 0;
    firstindex = count;
    count++;
  }
  slot = cxslot(second);
  if (slot != NULL) {
    entries[count].fd = slot->fd;
    entries[count].events = POLLIN;
    entries[count].revents = 0;
    secondindex = count;
    count++;
  }
  if (count == 0) {
    for (;;) {
      int result = poll(NULL, 0, cxremaining(deadline));
      if (result >= 0) return 0;
      if (errno == EINTR) continue;
      cxseterrno("wait");
      return CX_ERROR;
    }
  }

  for (;;) {
    BCPLWORD mask = 0;
    int result = poll(entries, (nfds_t)count, cxremaining(deadline));
    if (result < 0) {
      if (errno == EINTR) continue;
      cxseterrno("wait");
      return CX_ERROR;
    }
    if (result == 0) return 0;
    if (firstindex >= 0 && entries[firstindex].revents != 0) mask |= 1;
    if (secondindex >= 0 && entries[secondindex].revents != 0) mask |= 2;
    /* A buffered TLS record is already in userspace and will never make the
       descriptor readable, so report it as ready too. */
    return mask;
  }
}

/* Buffered TLS bytes are invisible to poll(). BCPL asks about them separately
   so a Live socket holding a complete frame inside OpenSSL is never mistaken
   for an idle connection. */
static BCPLWORD cxpending(BCPLWORD handle) {
  struct cxhandle *slot = cxslot(handle);
  if (slot == NULL) return 0;
  if (slot->ssl == NULL) return 0;
  return SSL_pending(slot->ssl) > 0 ? -1 : 0;
}

static void cxinstall(BCPLWORD index, int fd) {
  handles[index].inuse = 1;
  handles[index].fd = fd;
  handles[index].islisten = 0;
  handles[index].ssl = NULL;
  handles[index].ctx = NULL;
}

static BCPLWORD cxinit(void) {
  const char *outfd;
  int protocolfd = 1;
  int index;

  if (cxinitialised) return -1;

  for (index = 0; index < CX_MAXHANDLES; index++) {
    handles[index].inuse = 0;
    handles[index].fd = -1;
    handles[index].islisten = 0;
    handles[index].ssl = NULL;
    handles[index].ctx = NULL;
  }

  clock_gettime(CLOCK_MONOTONIC, &cxepoch);
  signal(SIGPIPE, SIG_IGN);

  /* The launcher redirects the Cintcode system's own console output to stderr
     and passes the real stdout on a spare descriptor, so that BCPL runtime
     chatter can never contaminate the adapter's NDJSON or the canonical
     example's transcript. */
  outfd = getenv("CONVEX_OUT_FD");
  if (outfd != NULL && *outfd != '\0') {
    int parsed = atoi(outfd);
    if (parsed > 0) protocolfd = parsed;
  }

  cxinstall(0, 0);
  cxinstall(1, protocolfd);
  cxinstall(2, 2);

  OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS, NULL);
  cxinitialised = 1;
  return -1;
}

BCPLWORD extfn(BCPLWORD *a, BCPLWORD *g, BCPLWORD *W) {
  (void)g;

  switch (a[0]) {
    default:
      cxseterror("ext", "unknown native function");
      return CX_ERROR;

    case EXT_Avail:
      return -1;

    case EXT_Init:
      return cxinit();

    case EXT_Testfn:
      return 0;

    case CX_Now:
      return cxnow();

    case CX_Getenv: {
      /* getenv(name, out, maxbytes) -> length, or -1 when unset. */
      char name[128];
      const char *value;
      int length;
      b2c_str(a[1], name);
      value = getenv(name);
      if (value == NULL) return -1;
      length = (int)strlen(value);
      if (length > a[3]) length = (int)a[3];
      memcpy((char *)(W + a[2]) + 1, value, (size_t)length);
      *(unsigned char *)(W + a[2]) = (unsigned char)length;
      return length;
    }

    case CX_Random: {
      /* random(buffer, offset, length) -> TRUE when the bytes are usable. */
      char *target = (char *)(W + a[1]) + a[2];
      if (RAND_bytes((unsigned char *)target, (int)a[3]) != 1) {
        cxsetsslerror("random");
        return 0;
      }
      return -1;
    }

    case CX_Connect: {
      /* connect(host, port, tls, deadline) -> handle */
      char host[256];
      b2c_str(a[1], host);
      cxerror[0] = '\0';
      return cxconnect(host, (int)a[2], a[3] != 0, a[4]);
    }

    case CX_Read: {
      /* read(handle, buffer, offset, maxbytes, deadline) */
      struct cxhandle *slot = cxslot(a[1]);
      if (slot == NULL) return CX_BADHANDLE;
      if (a[4] <= 0) return 0;
      return cxread(slot, (char *)(W + a[2]) + a[3], (int)a[4], a[5]);
    }

    case CX_Write: {
      /* write(handle, buffer, offset, bytes, deadline) */
      struct cxhandle *slot = cxslot(a[1]);
      if (slot == NULL) return CX_BADHANDLE;
      if (a[4] <= 0) return 0;
      return cxwrite(slot, (const char *)(W + a[2]) + a[3], (int)a[4], a[5]);
    }

    case CX_Close: {
      struct cxhandle *slot = cxslot(a[1]);
      if (slot == NULL) return CX_BADHANDLE;
      /* Handles 0 to 2 are the process's own descriptors and outlive us. */
      if (a[1] < CX_FIRSTSOCKET) return 0;
      cxrelease(slot);
      return 0;
    }

    case CX_Listen: {
      char host[256];
      b2c_str(a[1], host);
      cxerror[0] = '\0';
      return cxlisten(host, (int)a[2]);
    }

    case CX_Accept: {
      struct cxhandle *slot = cxslot(a[1]);
      if (slot == NULL) return CX_BADHANDLE;
      return cxaccept(slot, a[2]);
    }

    case CX_Wait:
      if (cxpending(a[1]) != 0) return 1;
      if (cxpending(a[2]) != 0) return 2;
      return cxwait(a[1], a[2], a[3]);

    case CX_Errtext: {
      /* errtext(out, maxbytes) -> length of the last native failure. */
      int length = (int)strlen(cxerror);
      if (length > a[2]) length = (int)a[2];
      memcpy((char *)(W + a[1]) + 1, cxerror, (size_t)length);
      *(unsigned char *)(W + a[1]) = (unsigned char)length;
      return length;
    }

    case CX_Tlsavail:
      return -1;
  }
}

/* The stock distribution links sdlfn.c and glfn.c purely so that sys(Sys_sdl,
   ...) and sys(Sys_gl, ...) resolve. This client builds neither, and declaring
   the stubs here keeps SDL and OpenGL out of the image entirely. */
BCPLWORD sdlfn(BCPLWORD *args, BCPLWORD *g, BCPLWORD *W) {
  (void)args;
  (void)g;
  (void)W;
  return 0;
}

BCPLWORD glfn(BCPLWORD *args, BCPLWORD *g, BCPLWORD *W) {
  (void)args;
  (void)g;
  (void)W;
  return 0;
}
