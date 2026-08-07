/*
 * Convex transport shim for Regina Rexx.
 *
 * Regina Rexx has no built-in socket or TLS support, so this file supplies
 * exactly those two things as external functions loaded with RXFUNCADD:
 * raw byte transport (connect/listen/accept/send/recv/close over TCP, with
 * OpenSSL doing the TLS handshake and record layer when requested) and a
 * source of random bytes. Nothing here knows about HTTP, JSON, WebSocket
 * framing, or the Convex sync protocol -- every one of those is implemented
 * in Rexx itself, in client/convex.rexx. This file only moves bytes.
 *
 * Handles are small integers indexing a fixed table of slots. Slots 0, 1
 * and 2 are pre-populated at load time to alias the process's own stdin,
 * stdout and stderr, so Rexx can read commands and write NDJSON through the
 * exact same RXRECV/RXSEND primitives it uses for Convex sockets -- one
 * transport abstraction for the adapter's stdio mode, its TCP mode, and
 * every HTTPS/WSS connection the client opens.
 */
#define INCL_RXFUNC
#include <rexxsaa.h>

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
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

__attribute__((constructor)) static void shim_init(void) {
    /* A peer that closes mid-write must surface as a normal recv/send
     * failure the Rexx side can classify, not a process-killing signal. */
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

/* Regina hands every external function a pre-allocated RXAUTOBUFLEN-byte
 * buffer at retstr->strptr and expects the result written into it when it
 * fits. A larger result must instead go into a fresh RexxAllocateMemory
 * buffer with retstr->strptr repointed at it -- Regina frees whichever
 * buffer strptr ends up naming once it has read strlength bytes from it.
 * Pointing strptr at a static or stack buffer instead crashes the
 * interpreter the moment it tries to free that address. */
static void set_result(RXSTRING *retstr, const char *tag, const void *data, size_t n) {
    size_t tagLen = strlen(tag);
    size_t total = tagLen + n;
    if (total > MAX_MESSAGE) total = MAX_MESSAGE;
    size_t dataLen = total > tagLen ? total - tagLen : 0;

    char *dest = retstr->strptr;
    if (total > RXAUTOBUFLEN) {
        dest = (char *)RexxAllocateMemory(total);
        if (dest == NULL) {
            /* Fall back to whatever Regina already gave us, truncated: an
             * allocation failure here must not corrupt the heap either. */
            dest = retstr->strptr;
            if (total > RXAUTOBUFLEN) {
                total = RXAUTOBUFLEN;
                dataLen = total > tagLen ? total - tagLen : 0;
            }
        } else {
            retstr->strptr = dest;
        }
    }

    memcpy(dest, tag, tagLen);
    if (dataLen > 0) memcpy(dest + tagLen, data, dataLen);
    retstr->strlength = tagLen + dataLen;
}

static void set_err(RXSTRING *retstr, const char *message) {
    set_result(retstr, "E:", message, strlen(message));
}

static void set_ok(RXSTRING *retstr, const char *payload) {
    set_result(retstr, "K:", payload, strlen(payload));
}

static int find_free_slot(void) {
    for (int i = 3; i < MAX_SLOTS; i++) {
        if (!slots[i].inUse) return i;
    }
    return -1;
}

static long arg_long(RXSTRING *argv, ULONG argc, ULONG idx, long fallback) {
    if (idx >= argc || argv[idx].strptr == NULL) return fallback;
    char buf[32];
    size_t n = argv[idx].strlength < sizeof(buf) - 1 ? argv[idx].strlength : sizeof(buf) - 1;
    memcpy(buf, argv[idx].strptr, n);
    buf[n] = 0;
    return strtol(buf, NULL, 10);
}

static void arg_str(RXSTRING *argv, ULONG argc, ULONG idx, char *out, size_t outSize) {
    out[0] = 0;
    if (idx >= argc || argv[idx].strptr == NULL) return;
    size_t n = argv[idx].strlength < outSize - 1 ? argv[idx].strlength : outSize - 1;
    memcpy(out, argv[idx].strptr, n);
    out[n] = 0;
}

/* RXCONNECT(host, port, tls) -> "K:<handle>" | "E:<message>" */
RexxFunctionHandler RXCONNECT;
ULONG RXCONNECT(const char *name, ULONG argc, RXSTRING *argv, const char *queuename, RXSTRING *retstr) {
    (void)name;
    (void)queuename;
    char host[256];
    char port[16];
    arg_str(argv, argc, 0, host, sizeof(host));
    arg_str(argv, argc, 1, port, sizeof(port));
    long useTls = arg_long(argv, argc, 2, 0);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    if (getaddrinfo(host, port, &hints, &res) != 0 || res == NULL) {
        set_err(retstr, "dns resolution failed");
        return 0;
    }

    /* A non-blocking connect bounded by poll() keeps an unreachable or
     * black-holed peer from stalling the whole adapter for the OS's own
     * (much longer) default connect timeout. */
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
        set_err(retstr, "connect failed or timed out");
        return 0;
    }

    int slotIdx = find_free_slot();
    if (slotIdx < 0) {
        close(fd);
        set_err(retstr, "no free connection slots");
        return 0;
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
            set_err(retstr, "tls handshake failed");
            return 0;
        }
    }

    slots[slotIdx].inUse = 1;
    slots[slotIdx].fd = fd;
    slots[slotIdx].listening = 0;
    slots[slotIdx].ssl = ssl;

    char handleBuf[16];
    snprintf(handleBuf, sizeof(handleBuf), "%d", slotIdx);
    set_ok(retstr, handleBuf);
    return 0;
}

/* RXLISTEN(bindHost, port) -> "K:<handle>" | "E:<message>" */
RexxFunctionHandler RXLISTEN;
ULONG RXLISTEN(const char *name, ULONG argc, RXSTRING *argv, const char *queuename, RXSTRING *retstr) {
    (void)name;
    (void)queuename;
    char host[256];
    char port[16];
    arg_str(argv, argc, 0, host, sizeof(host));
    arg_str(argv, argc, 1, port, sizeof(port));

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    struct addrinfo *res = NULL;
    if (getaddrinfo(host[0] ? host : NULL, port, &hints, &res) != 0 || res == NULL) {
        set_err(retstr, "bind address resolution failed");
        return 0;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        set_err(retstr, "socket creation failed");
        return 0;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(fd, res->ai_addr, res->ai_addrlen) != 0 || listen(fd, 1) != 0) {
        freeaddrinfo(res);
        close(fd);
        set_err(retstr, "bind or listen failed");
        return 0;
    }
    freeaddrinfo(res);

    int slotIdx = find_free_slot();
    if (slotIdx < 0) {
        close(fd);
        set_err(retstr, "no free connection slots");
        return 0;
    }
    slots[slotIdx].inUse = 1;
    slots[slotIdx].fd = fd;
    slots[slotIdx].listening = 1;
    slots[slotIdx].ssl = NULL;

    char handleBuf[16];
    snprintf(handleBuf, sizeof(handleBuf), "%d", slotIdx);
    set_ok(retstr, handleBuf);
    return 0;
}

/* RXACCEPT(handle, timeoutMs) -> "K:<handle>" | "T:" | "E:<message>" */
RexxFunctionHandler RXACCEPT;
ULONG RXACCEPT(const char *name, ULONG argc, RXSTRING *argv, const char *queuename, RXSTRING *retstr) {
    (void)name;
    (void)queuename;
    long handle = arg_long(argv, argc, 0, -1);
    long timeoutMs = arg_long(argv, argc, 1, -1);
    if (handle < 0 || handle >= MAX_SLOTS || !slots[handle].inUse || !slots[handle].listening) {
        set_err(retstr, "not a listening handle");
        return 0;
    }

    struct pollfd pfd;
    pfd.fd = slots[handle].fd;
    pfd.events = POLLIN;
    int rc = poll(&pfd, 1, (int)timeoutMs);
    if (rc == 0) {
        set_result(retstr, "T:", "", 0);
        return 0;
    }
    if (rc < 0) {
        set_err(retstr, "poll failed while accepting");
        return 0;
    }

    int newFd = accept(slots[handle].fd, NULL, NULL);
    if (newFd < 0) {
        set_err(retstr, "accept failed");
        return 0;
    }

    /* The listening socket's lifecycle is the caller's decision, not this
     * shim's: the adapter's TCP mode wants exactly one controller
     * connection and closes the listener itself right after this call
     * returns, but a test fixture may legitimately accept several
     * connections in turn from the same listener (see ws_fixture.rexx). */
    int slotIdx = find_free_slot();
    if (slotIdx < 0) {
        close(newFd);
        set_err(retstr, "no free connection slots");
        return 0;
    }
    slots[slotIdx].inUse = 1;
    slots[slotIdx].fd = newFd;
    slots[slotIdx].listening = 0;
    slots[slotIdx].ssl = NULL;

    char handleBuf[16];
    snprintf(handleBuf, sizeof(handleBuf), "%d", slotIdx);
    set_ok(retstr, handleBuf);
    return 0;
}

/* RXSEND(handle, bytes) -> "K:<bytesSent>" | "E:<message>" */
RexxFunctionHandler RXSEND;
ULONG RXSEND(const char *name, ULONG argc, RXSTRING *argv, const char *queuename, RXSTRING *retstr) {
    (void)name;
    (void)queuename;
    long handle = arg_long(argv, argc, 0, -1);
    if (handle < 0 || handle >= MAX_SLOTS || !slots[handle].inUse || slots[handle].listening) {
        set_err(retstr, "not an open connection handle");
        return 0;
    }
    const char *data = (argc > 1 && argv[1].strptr) ? argv[1].strptr : "";
    size_t len = argc > 1 ? argv[1].strlength : 0;

    size_t sent = 0;
    while (sent < len) {
        ssize_t n;
        if (slots[handle].ssl) {
            n = SSL_write(slots[handle].ssl, data + sent, (int)(len - sent));
        } else {
            /* write(), not send(): handles 0/1/2 alias stdio, which are
             * not sockets and reject socket-only calls with ENOTSOCK.
             * SIGPIPE is already globally ignored, so send()'s
             * MSG_NOSIGNAL buys nothing a plain write() does not also get. */
            n = write(slots[handle].fd, data + sent, len - sent);
        }
        if (n <= 0) {
            if (sent > 0) break; /* Report the partial write; caller retries the rest. */
            set_err(retstr, "send failed");
            return 0;
        }
        sent += (size_t)n;
    }

    char lenBuf[24];
    snprintf(lenBuf, sizeof(lenBuf), "%zu", sent);
    set_ok(retstr, lenBuf);
    return 0;
}

/* RXRECV(handle, maxBytes, timeoutMs) -> "D:<bytes>" | "T:" | "C:" | "E:<message>" */
RexxFunctionHandler RXRECV;
ULONG RXRECV(const char *name, ULONG argc, RXSTRING *argv, const char *queuename, RXSTRING *retstr) {
    (void)name;
    (void)queuename;
    long handle = arg_long(argv, argc, 0, -1);
    long maxBytes = arg_long(argv, argc, 1, 65536);
    long timeoutMs = arg_long(argv, argc, 2, -1);
    if (handle < 0 || handle >= MAX_SLOTS || !slots[handle].inUse || slots[handle].listening) {
        set_err(retstr, "not an open connection handle");
        return 0;
    }
    if (maxBytes > MAX_MESSAGE - 2) maxBytes = MAX_MESSAGE - 2;
    if (maxBytes < 1) maxBytes = 1;

    if (slots[handle].ssl && SSL_pending(slots[handle].ssl) > 0) {
        /* Already-buffered TLS record plaintext; no need to poll the fd. */
    } else {
        struct pollfd pfd;
        pfd.fd = slots[handle].fd;
        pfd.events = POLLIN;
        int rc = poll(&pfd, 1, (int)timeoutMs);
        if (rc == 0) {
            set_result(retstr, "T:", "", 0);
            return 0;
        }
        if (rc < 0) {
            set_err(retstr, "poll failed while receiving");
            return 0;
        }
    }

    static char buf[MAX_MESSAGE];
    ssize_t n;
    if (slots[handle].ssl) {
        n = SSL_read(slots[handle].ssl, buf, (int)maxBytes);
        if (n <= 0) {
            int reason = SSL_get_error(slots[handle].ssl, (int)n);
            if (reason == SSL_ERROR_ZERO_RETURN) {
                set_result(retstr, "C:", "", 0);
            } else if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
                set_result(retstr, "T:", "", 0);
            } else {
                set_err(retstr, "tls read failed");
            }
            return 0;
        }
    } else {
        n = read(slots[handle].fd, buf, (size_t)maxBytes);
        if (n == 0) {
            set_result(retstr, "C:", "", 0);
            return 0;
        }
        if (n < 0) {
            set_err(retstr, "recv failed");
            return 0;
        }
    }

    set_result(retstr, "D:", buf, (size_t)n);
    return 0;
}

/* RXCLOSE(handle) -> "K:" always */
RexxFunctionHandler RXCLOSE;
ULONG RXCLOSE(const char *name, ULONG argc, RXSTRING *argv, const char *queuename, RXSTRING *retstr) {
    (void)name;
    (void)queuename;
    long handle = arg_long(argv, argc, 0, -1);
    if (handle >= 3 && handle < MAX_SLOTS && slots[handle].inUse) {
        if (slots[handle].ssl) {
            SSL_shutdown(slots[handle].ssl);
            SSL_free(slots[handle].ssl);
        }
        close(slots[handle].fd);
        slots[handle].inUse = 0;
        slots[handle].ssl = NULL;
    }
    set_result(retstr, "K:", "", 0);
    return 0;
}

/* RXRANDBYTES(n) -> "K:<n raw bytes>" | "E:<message>" */
RexxFunctionHandler RXRANDBYTES;
ULONG RXRANDBYTES(const char *name, ULONG argc, RXSTRING *argv, const char *queuename, RXSTRING *retstr) {
    (void)name;
    (void)queuename;
    long n = arg_long(argv, argc, 0, 0);
    if (n < 0) n = 0;
    if (n > 4096) n = 4096;
    unsigned char buf[4096];
    if (RAND_bytes(buf, (int)n) != 1) {
        set_err(retstr, "random source failed");
        return 0;
    }
    set_result(retstr, "K:", buf, (size_t)n);
    return 0;
}
