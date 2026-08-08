/*
 * Convex transport shim for Unicon.
 *
 * Unicon has real native TCP sockets via open(s, "n"), but no TLS, so this
 * file supplies raw byte transport uniformly for both plain and TLS
 * connections: connect/listen/accept/send/recv/close, plus a source of
 * random bytes, loaded with Unicon's own loadfunc() foreign-function
 * interface (ipl/cfuncs/icall.h's UARGS and its Arg.../Ret... macros are
 * the officially documented mechanism for exactly this). Nothing here knows
 * about HTTP, JSON, WebSocket framing, or the Convex sync protocol --
 * every one of those is implemented in Unicon itself, in
 * client/convex.icn. This file only moves bytes -- plus one more thing
 * Unicon itself has no way to ask for: wall-clock time. Icon/Unicon's
 * built-in &time keyword is documented as *execution* time (time actually
 * spent running, excluding time blocked on I/O), so it barely advances
 * while a poll()/recv() call is waiting on the network -- exactly the
 * common case for Live's reconnect backoff. uconvexnowms() supplies real
 * elapsed wall-clock milliseconds instead.
 *
 * The wire convention matches client/convex.icn's expectations exactly:
 * every function returns a single string, tagged by its first two
 * characters ("K:" ok, "D:" data, "T:" timed out, "C:" closed, "E:"
 * error), with the payload (which may contain arbitrary binary bytes,
 * including embedded NULs) following. Using an ordinary string return for
 * every outcome, rather than Unicon's native success/fail signal, keeps
 * one uniform protocol between this shim and both languages' clients
 * (compare client/shim.c in ../../rexx, which the same convention was
 * proven in first).
 *
 * Handles are small integers indexing a fixed table of slots. Slots 0, 1
 * and 2 are pre-populated at load time to alias the process's own stdin,
 * stdout and stderr, so the adapter's stdio mode and its TCP mode share
 * the exact same rxrecv/rxsend primitives used for every HTTPS/WSS
 * connection the client opens.
 */
#include "icall.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>

#define MAX_SLOTS 128
#define MAX_MESSAGE 8388608 /* 8 MiB: comfortably above one Convex frame. */

typedef struct {
    int inUse;
    int fd;
    int listening;
    SSL *ssl;
} slot_t;

static slot_t slots[MAX_SLOTS];
static SSL_CTX *sharedCtx = NULL;
static int initialised = 0;

static void ensure_init(void) {
    if (initialised) return;
    initialised = 1;
    signal(SIGPIPE, SIG_IGN);
    memset(slots, 0, sizeof(slots));
    slots[0].inUse = 1;
    slots[0].fd = 0;
    slots[1].inUse = 1;
    slots[1].fd = 1;
    slots[2].inUse = 1;
    slots[2].fd = 2;
    SSL_library_init();
    SSL_load_error_strings();
}

static int find_free_slot(void) {
    for (int i = 3; i < MAX_SLOTS; i++) {
        if (!slots[i].inUse) return i;
    }
    return -1;
}

/* Builds "<tag><payload>" (payload may be binary) and hands it back to
 * Unicon as an explicit-length string, never NUL-terminated-truncated.
 * RetStringN's alcstr() copies the bytes into Unicon-managed memory
 * immediately and synchronously, so a reused static scratch buffer is
 * safe here (and, since RetStringN's own expansion already contains a
 * `return`, this function could never free a heap buffer afterwards
 * anyway -- that path would just leak on every call). */
static char scratch[MAX_MESSAGE];

static int ret_tagged(descriptor *argv, const char *tag, const void *data, size_t n) {
    size_t tagLen = strlen(tag);
    size_t total = tagLen + n;
    if (total > MAX_MESSAGE) total = MAX_MESSAGE;
    if (tagLen > total) tagLen = total;
    memcpy(scratch, tag, tagLen);
    size_t dataLen = total - tagLen;
    if (dataLen > n) dataLen = n;
    if (dataLen > 0) memcpy(scratch + tagLen, data, dataLen);
    RetStringN(scratch, (word)(tagLen + dataLen));
}

static int ret_ok(descriptor *argv, const char *payload) {
    return ret_tagged(argv, "K:", payload, strlen(payload));
}

static int ret_err(descriptor *argv, const char *message) {
    return ret_tagged(argv, "E:", message, strlen(message));
}

/* uconvexconnect(host, port, tls) -> "K:<handle>" | "E:<message>" */
int uconvexconnect(UARGS) {
    ensure_init();
    ArgString(1);
    ArgString(2);
    ArgInteger(3);
    char host[256];
    size_t hn = (size_t)StringLen(argv[1]) < sizeof(host) - 1 ? (size_t)StringLen(argv[1]) : sizeof(host) - 1;
    memcpy(host, StringAddr(argv[1]), hn);
    host[hn] = 0;
    char port[16];
    size_t pn = (size_t)StringLen(argv[2]) < sizeof(port) - 1 ? (size_t)StringLen(argv[2]) : sizeof(port) - 1;
    memcpy(port, StringAddr(argv[2]), pn);
    port[pn] = 0;
    long useTls = IntegerVal(argv[3]);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    if (getaddrinfo(host, port, &hints, &res) != 0 || res == NULL) {
        return ret_err(argv, "dns resolution failed");
    }

    int fd = -1;
    struct addrinfo *rp;
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, rp->ai_addr, rp->ai_addrlen);
        if (rc == 0) {
            fcntl(fd, F_SETFL, flags);
            break;
        }
        if (errno == EINPROGRESS) {
            struct pollfd pfd;
            pfd.fd = fd;
            pfd.events = POLLOUT;
            int pollRc = poll(&pfd, 1, 10000);
            int soErr = 0;
            socklen_t soErrLen = sizeof(soErr);
            if (pollRc > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soErrLen) == 0 && soErr == 0) {
                fcntl(fd, F_SETFL, flags);
                break;
            }
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        return ret_err(argv, "connect failed or timed out");
    }

    int slotIdx = find_free_slot();
    if (slotIdx < 0) {
        close(fd);
        return ret_err(argv, "no free connection slots");
    }

    SSL *ssl = NULL;
    if (useTls) {
        if (sharedCtx == NULL) {
            sharedCtx = SSL_CTX_new(TLS_client_method());
            SSL_CTX_set_verify(sharedCtx, SSL_VERIFY_PEER, NULL);
            SSL_CTX_set_default_verify_paths(sharedCtx);
        }
        ssl = SSL_new(sharedCtx);
        SSL_set_fd(ssl, fd);
        SSL_set_tlsext_host_name(ssl, host);
        SSL_set1_host(ssl, host);
        if (SSL_connect(ssl) != 1) {
            SSL_free(ssl);
            close(fd);
            return ret_err(argv, "tls handshake failed");
        }
    }

    slots[slotIdx].inUse = 1;
    slots[slotIdx].fd = fd;
    slots[slotIdx].listening = 0;
    slots[slotIdx].ssl = ssl;

    char handleBuf[16];
    snprintf(handleBuf, sizeof(handleBuf), "%d", slotIdx);
    return ret_ok(argv, handleBuf);
}

/* uconvexlisten(bindHost, port) -> "K:<handle>" | "E:<message>" */
int uconvexlisten(UARGS) {
    ensure_init();
    ArgString(1);
    ArgString(2);
    char host[256];
    size_t hn = (size_t)StringLen(argv[1]) < sizeof(host) - 1 ? (size_t)StringLen(argv[1]) : sizeof(host) - 1;
    memcpy(host, StringAddr(argv[1]), hn);
    host[hn] = 0;
    char port[16];
    size_t pn = (size_t)StringLen(argv[2]) < sizeof(port) - 1 ? (size_t)StringLen(argv[2]) : sizeof(port) - 1;
    memcpy(port, StringAddr(argv[2]), pn);
    port[pn] = 0;

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    struct addrinfo *res = NULL;
    if (getaddrinfo(host[0] ? host : NULL, port, &hints, &res) != 0 || res == NULL) {
        return ret_err(argv, "bind address resolution failed");
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return ret_err(argv, "socket creation failed");
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(fd, res->ai_addr, res->ai_addrlen) != 0 || listen(fd, 1) != 0) {
        freeaddrinfo(res);
        close(fd);
        return ret_err(argv, "bind or listen failed");
    }
    freeaddrinfo(res);

    int slotIdx = find_free_slot();
    if (slotIdx < 0) {
        close(fd);
        return ret_err(argv, "no free connection slots");
    }
    slots[slotIdx].inUse = 1;
    slots[slotIdx].fd = fd;
    slots[slotIdx].listening = 1;
    slots[slotIdx].ssl = NULL;

    char handleBuf[16];
    snprintf(handleBuf, sizeof(handleBuf), "%d", slotIdx);
    return ret_ok(argv, handleBuf);
}

/* uconvexaccept(handle, timeoutMs) -> "K:<handle>" | "T:" | "E:<message>" */
int uconvexaccept(UARGS) {
    ensure_init();
    ArgInteger(1);
    ArgInteger(2);
    long handle = IntegerVal(argv[1]);
    long timeoutMs = IntegerVal(argv[2]);
    if (handle < 0 || handle >= MAX_SLOTS || !slots[handle].inUse || !slots[handle].listening) {
        return ret_err(argv, "not a listening handle");
    }

    struct pollfd pfd;
    pfd.fd = slots[handle].fd;
    pfd.events = POLLIN;
    int rc = poll(&pfd, 1, (int)timeoutMs);
    if (rc == 0) {
        return ret_tagged(argv, "T:", "", 0);
    }
    if (rc < 0) {
        return ret_err(argv, "poll failed while accepting");
    }

    int newFd = accept(slots[handle].fd, NULL, NULL);
    if (newFd < 0) {
        return ret_err(argv, "accept failed");
    }

    /* Listener lifecycle is the caller's decision: the adapter's TCP mode
     * wants exactly one controller connection and closes the listener
     * itself right after this returns, but a test fixture may legitimately
     * accept several connections in turn from the same listener. */
    int slotIdx = find_free_slot();
    if (slotIdx < 0) {
        close(newFd);
        return ret_err(argv, "no free connection slots");
    }
    slots[slotIdx].inUse = 1;
    slots[slotIdx].fd = newFd;
    slots[slotIdx].listening = 0;
    slots[slotIdx].ssl = NULL;

    char handleBuf[16];
    snprintf(handleBuf, sizeof(handleBuf), "%d", slotIdx);
    return ret_ok(argv, handleBuf);
}

/* uconvexsend(handle, bytes) -> "K:<bytesSent>" | "E:<message>" */
int uconvexsend(UARGS) {
    ensure_init();
    ArgInteger(1);
    ArgString(2);
    long handle = IntegerVal(argv[1]);
    if (handle < 0 || handle >= MAX_SLOTS || !slots[handle].inUse || slots[handle].listening) {
        return ret_err(argv, "not an open connection handle");
    }
    const char *data = StringAddr(argv[2]);
    size_t len = StringLen(argv[2]);

    size_t sent = 0;
    while (sent < len) {
        ssize_t n;
        if (slots[handle].ssl) {
            n = SSL_write(slots[handle].ssl, data + sent, (int)(len - sent));
        } else {
            n = write(slots[handle].fd, data + sent, len - sent);
        }
        if (n <= 0) {
            if (sent > 0) break;
            return ret_err(argv, "send failed");
        }
        sent += (size_t)n;
    }

    char lenBuf[24];
    snprintf(lenBuf, sizeof(lenBuf), "%zu", sent);
    return ret_ok(argv, lenBuf);
}

/* uconvexrecv(handle, maxBytes, timeoutMs) ->
 *   "D:<bytes>" | "T:" | "C:" | "E:<message>" */
int uconvexrecv(UARGS) {
    ensure_init();
    ArgInteger(1);
    ArgInteger(2);
    ArgInteger(3);
    long handle = IntegerVal(argv[1]);
    long maxBytes = IntegerVal(argv[2]);
    long timeoutMs = IntegerVal(argv[3]);
    if (handle < 0 || handle >= MAX_SLOTS || !slots[handle].inUse || slots[handle].listening) {
        return ret_err(argv, "not an open connection handle");
    }
    if (maxBytes > MAX_MESSAGE - 2) maxBytes = MAX_MESSAGE - 2;
    if (maxBytes < 1) maxBytes = 1;

    if (!(slots[handle].ssl && SSL_pending(slots[handle].ssl) > 0)) {
        struct pollfd pfd;
        pfd.fd = slots[handle].fd;
        pfd.events = POLLIN;
        int rc = poll(&pfd, 1, (int)timeoutMs);
        if (rc == 0) {
            return ret_tagged(argv, "T:", "", 0);
        }
        if (rc < 0) {
            return ret_err(argv, "poll failed while receiving");
        }
    }

    static char buf[MAX_MESSAGE];
    ssize_t n;
    if (slots[handle].ssl) {
        n = SSL_read(slots[handle].ssl, buf, (int)maxBytes);
        if (n <= 0) {
            int reason = SSL_get_error(slots[handle].ssl, (int)n);
            if (reason == SSL_ERROR_ZERO_RETURN) return ret_tagged(argv, "C:", "", 0);
            if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) return ret_tagged(argv, "T:", "", 0);
            return ret_err(argv, "tls read failed");
        }
    } else {
        n = read(slots[handle].fd, buf, (size_t)maxBytes);
        if (n == 0) return ret_tagged(argv, "C:", "", 0);
        if (n < 0) return ret_err(argv, "recv failed");
    }

    return ret_tagged(argv, "D:", buf, (size_t)n);
}

/* uconvexclose(handle) -> "K:" always */
int uconvexclose(UARGS) {
    ensure_init();
    ArgInteger(1);
    long handle = IntegerVal(argv[1]);
    if (handle >= 3 && handle < MAX_SLOTS && slots[handle].inUse) {
        if (slots[handle].ssl) {
            SSL_shutdown(slots[handle].ssl);
            SSL_free(slots[handle].ssl);
        }
        close(slots[handle].fd);
        slots[handle].inUse = 0;
        slots[handle].ssl = NULL;
    }
    return ret_tagged(argv, "K:", "", 0);
}

/* uconvexrandbytes(n) -> "K:<n raw bytes>" | "E:<message>" */
int uconvexrandbytes(UARGS) {
    ensure_init();
    ArgInteger(1);
    long n = IntegerVal(argv[1]);
    if (n < 0) n = 0;
    if (n > 4096) n = 4096;
    unsigned char buf[4096];
    if (RAND_bytes(buf, (int)n) != 1) {
        return ret_err(argv, "random source failed");
    }
    return ret_tagged(argv, "K:", buf, (size_t)n);
}

/* uconvexnowms() -> "K:<milliseconds since the Unix epoch, decimal>" */
int uconvexnowms(UARGS) {
    (void)argc; /* no Icon-side arguments; only argv[0], the return slot, is used */
    struct timeval tv;
    gettimeofday(&tv, NULL);
    long long ms = (long long)tv.tv_sec * 1000 + (long long)tv.tv_usec / 1000;
    char buf[32];
    int n = snprintf(buf, sizeof buf, "%lld", ms);
    return ret_tagged(argv, "K:", buf, (size_t)n);
}
