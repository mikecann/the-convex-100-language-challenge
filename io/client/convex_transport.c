/*
 * ConvexIO - the native transport boundary for the educational Io Convex
 * client.
 *
 * Io's reference VM ships no sockets. The maintained `master` branch targets
 * WebAssembly and removed the addon system outright; the `native` branch keeps
 * the CMake VM but the historical Socket and SecureSocket addons moved to
 * unmaintained 2018-era repositories that predate OpenSSL 3. There is
 * therefore no ordinary Io library that can open a TCP connection, let alone a
 * validated TLS one, so this file supplies the smallest boundary that lets the
 * rest of the client stay in Io.
 *
 * What lives here: byte-level sockets, OpenSSL client TLS with CA and hostname
 * verification, readiness polling over a handle bitmask, CSPRNG bytes and a
 * monotonic clock.
 *
 * What deliberately does NOT live here: HTTP/1.1, RFC 6455 framing, JSON,
 * SHA-1, base64, the Convex sync state machine and the adapter protocol. All
 * of those are implemented in client/convex.io so the Convex behaviour this
 * repository is measuring is genuinely written in Io.
 *
 * The proto is loaded by client/convex.io through Io's ordinary DynLib:
 *
 *     DynLib clone setPath(path) open voidCall("IoConvexIOInit", context)
 *
 * Every method is added tagless, so it may be called on the registered proto
 * or on any object that inherits from it.
 */

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/opensslv.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include "IoMessage.h"
#include "IoNumber.h"
#include "IoObject.h"
#include "IoSeq.h"
#include "IoState.h"

/*
 * Handles are small integers so that Io can describe a readiness set as a
 * single Number bitmask. The adapter needs at most five at once (stdin,
 * stdout, the Convex WebSocket, an optional TCP listener and its accepted
 * controller connection), and a hostile-peer test may hold a couple of
 * loopback sockets, so a 32-entry table is generous and keeps every mask
 * inside a double's exact-integer range.
 */
#define CONVEXIO_MAX_HANDLES 32
#define CONVEXIO_MAX_READ 65536

/* Connection lifecycle. Io drives the transitions through `handshake`. */
enum {
    CONVEXIO_FREE = 0,
    CONVEXIO_CONNECTING = 1, /* TCP connect() is still in flight */
    CONVEXIO_TLS = 2,        /* TCP is up, SSL_connect is still negotiating */
    CONVEXIO_OPEN = 3,
    CONVEXIO_LISTENING = 4
};

/* Values returned by `handshake`, and the readiness bits Io waits on. */
#define CONVEXIO_READY 0
#define CONVEXIO_WANT_READ 1
#define CONVEXIO_WANT_WRITE 2

typedef struct {
    int state;
    int fd;
    /* the peer half-closed; read() reports it exactly once */
    int eof;
    /* NULL for plaintext handles, including stdio */
    SSL *ssl;
    SSL_CTX *ctx;
    /* stdio handles are borrowed and must never be closed */
    int ownsFd;
    /*
     * A borrowed descriptor belongs to whoever started this process, and
     * O_NONBLOCK lives on the shared open file description rather than on this
     * process's copy. Setting it on stdout would make the parent's own writes
     * to the same terminal or pipe start failing with EAGAIN, so the original
     * flags are remembered here and put back when the handle is released.
     */
    int savedFlags;
    int restoreFlags;
} ConvexIOHandle;

static ConvexIOHandle convexIOHandles[CONVEXIO_MAX_HANDLES];
static int convexIOInitialized = 0;
static double convexIOReadyRead = 0;
static double convexIOReadyWrite = 0;
static char convexIOError[256] = {0};

static const char *protoId = "ConvexIO";

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static void convexIO_setError(const char *prefix, const char *detail) {
    if (detail == NULL || *detail == '\0') {
        snprintf(convexIOError, sizeof(convexIOError), "%s", prefix);
    } else {
        snprintf(convexIOError, sizeof(convexIOError), "%s: %s", prefix,
                 detail);
    }
}

/*
 * OpenSSL stacks several errors per failure. Drain the queue so a later,
 * unrelated call cannot report a stale reason, and keep only the first one for
 * the Io-side message.
 */
static void convexIO_setSSLError(const char *prefix) {
    unsigned long first = ERR_get_error();
    char buffer[192];

    if (first == 0) {
        convexIO_setError(prefix, "no OpenSSL detail available");
        return;
    }

    ERR_error_string_n(first, buffer, sizeof(buffer));
    convexIO_setError(prefix, buffer);
    while (ERR_get_error() != 0) {
    }
}

static void convexIO_initTable(void) {
    int index;

    if (convexIOInitialized) {
        return;
    }
    convexIOInitialized = 1;
    for (index = 0; index < CONVEXIO_MAX_HANDLES; index++) {
        convexIOHandles[index].state = CONVEXIO_FREE;
        convexIOHandles[index].fd = -1;
        convexIOHandles[index].eof = 0;
        convexIOHandles[index].ssl = NULL;
        convexIOHandles[index].ctx = NULL;
        convexIOHandles[index].ownsFd = 0;
        convexIOHandles[index].savedFlags = 0;
        convexIOHandles[index].restoreFlags = 0;
    }
}

static int convexIO_allocate(void) {
    int index;

    convexIO_initTable();
    for (index = 0; index < CONVEXIO_MAX_HANDLES; index++) {
        if (convexIOHandles[index].state == CONVEXIO_FREE) {
            return index;
        }
    }
    return -1;
}

static ConvexIOHandle *convexIO_at(int index) {
    convexIO_initTable();
    if (index < 0 || index >= CONVEXIO_MAX_HANDLES) {
        return NULL;
    }
    if (convexIOHandles[index].state == CONVEXIO_FREE) {
        return NULL;
    }
    return &convexIOHandles[index];
}

static int convexIO_setNonBlocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);

    if (flags == -1) {
        return -1;
    }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void convexIO_release(ConvexIOHandle *handle) {
    if (handle->ssl != NULL) {
        /*
         * A best-effort close_notify only. The peer may be gone or stalled and
         * the caller's deadline already expired, so never block here.
         */
        SSL_shutdown(handle->ssl);
        SSL_free(handle->ssl);
        handle->ssl = NULL;
    }
    if (handle->ctx != NULL) {
        SSL_CTX_free(handle->ctx);
        handle->ctx = NULL;
    }
    if (handle->fd >= 0 && handle->restoreFlags) {
        /* Leave a borrowed descriptor exactly as it was found. */
        fcntl(handle->fd, F_SETFL, handle->savedFlags);
    }
    if (handle->fd >= 0 && handle->ownsFd) {
        close(handle->fd);
    }
    handle->fd = -1;
    handle->eof = 0;
    handle->ownsFd = 0;
    handle->savedFlags = 0;
    handle->restoreFlags = 0;
    handle->state = CONVEXIO_FREE;
}

/* ------------------------------------------------------------------ */
/* Io methods                                                          */
/* ------------------------------------------------------------------ */

static IoObject *IoConvexIO_version(IoObject *self, IoObject *locals,
                                    IoMessage *m) {
    return IOSYMBOL("convex-io-transport-0.1.0");
}

static IoObject *IoConvexIO_tlsVersion(IoObject *self, IoObject *locals,
                                       IoMessage *m) {
    return IOSYMBOL(OpenSSL_version(OPENSSL_VERSION));
}

static IoObject *IoConvexIO_errorText(IoObject *self, IoObject *locals,
                                      IoMessage *m) {
    return IOSYMBOL(convexIOError);
}

/*
 * A monotonic millisecond clock. Every deadline in the Io client is absolute,
 * so it must not move when the container's wall clock is stepped.
 */
static IoObject *IoConvexIO_monotonicMs(IoObject *self, IoObject *locals,
                                        IoMessage *m) {
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        IoState_error_(IOSTATE, m, "ConvexIO could not read CLOCK_MONOTONIC");
        return IONIL(self);
    }
    return IONUMBER((double)now.tv_sec * 1000.0 +
                    (double)now.tv_nsec / 1000000.0);
}

/*
 * WebSocket masking keys must be unguessable, so they come from the CSPRNG
 * rather than Io's Random addon (which does not exist on this VM anyway).
 */
static IoObject *IoConvexIO_randomBytes(IoObject *self, IoObject *locals,
                                        IoMessage *m) {
    int count = IoMessage_locals_intArgAt_(m, locals, 0);
    unsigned char buffer[256];

    if (count < 0 || count > (int)sizeof(buffer)) {
        IoState_error_(IOSTATE, m, "ConvexIO randomBytes count out of range");
        return IONIL(self);
    }
    if (count > 0 && RAND_bytes(buffer, count) != 1) {
        convexIO_setSSLError("RAND_bytes failed");
        IoState_error_(IOSTATE, m, "ConvexIO could not read secure randomness");
        return IONIL(self);
    }
    return IOSEQ(buffer, (size_t)count);
}

/*
 * Adopt one of the process's own standard descriptors as a handle, so the
 * adapter can poll the controller and the Convex socket at a single wait
 * point. The descriptor is borrowed: `close` must never really close it, and
 * the O_NONBLOCK this function has to set is put back on release because it is
 * shared with whatever started the process.
 */
static IoObject *IoConvexIO_adoptDescriptor(IoObject *self, IoObject *locals,
                                            IoMessage *m) {
    int fd = IoMessage_locals_intArgAt_(m, locals, 0);
    int index;
    int flags;

    if (fd < 0) {
        IoState_error_(IOSTATE, m, "ConvexIO cannot adopt a negative fd");
        return IONIL(self);
    }
    index = convexIO_allocate();
    if (index < 0) {
        IoState_error_(IOSTATE, m, "ConvexIO handle table is full");
        return IONIL(self);
    }
    flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1 || convexIO_setNonBlocking(fd) != 0) {
        IoState_error_(IOSTATE, m,
                       "ConvexIO could not make the descriptor nonblocking");
        return IONIL(self);
    }
    convexIOHandles[index].state = CONVEXIO_OPEN;
    convexIOHandles[index].fd = fd;
    convexIOHandles[index].ownsFd = 0;
    convexIOHandles[index].eof = 0;
    convexIOHandles[index].savedFlags = flags;
    convexIOHandles[index].restoreFlags = 1;
    return IONUMBER(index);
}

/*
 * Start a connection. This never blocks: it returns as soon as connect() is in
 * flight so the caller keeps ownership of the deadline, and `handshake` later
 * finishes both the TCP and the TLS negotiation.
 */
static IoObject *IoConvexIO_connect(IoObject *self, IoObject *locals,
                                    IoMessage *m) {
    IoSeq *hostArgument = IoMessage_locals_seqArgAt_(m, locals, 0);
    int port = IoMessage_locals_intArgAt_(m, locals, 1);
    int useTls = IoMessage_locals_intArgAt_(m, locals, 2);
    char host[256];
    char portText[16];
    size_t hostLength = IoSeq_rawSize(hostArgument);
    struct addrinfo hints;
    struct addrinfo *resolved = NULL;
    struct addrinfo *candidate = NULL;
    int index;
    int fd = -1;
    int resolveStatus;

    if (hostLength == 0 || hostLength >= sizeof(host)) {
        IoState_error_(IOSTATE, m, "ConvexIO connect host is out of range");
        return IONIL(self);
    }
    if (port < 1 || port > 65535) {
        IoState_error_(IOSTATE, m, "ConvexIO connect port is out of range");
        return IONIL(self);
    }
    memcpy(host, IoSeq_rawBytes(hostArgument), hostLength);
    host[hostLength] = '\0';
    snprintf(portText, sizeof(portText), "%d", port);

    index = convexIO_allocate();
    if (index < 0) {
        IoState_error_(IOSTATE, m, "ConvexIO handle table is full");
        return IONIL(self);
    }

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    resolveStatus = getaddrinfo(host, portText, &hints, &resolved);
    if (resolveStatus != 0) {
        convexIO_setError("resolve failed", gai_strerror(resolveStatus));
        return IONUMBER(-1);
    }

    for (candidate = resolved; candidate != NULL;
         candidate = candidate->ai_next) {
        fd = socket(candidate->ai_family, candidate->ai_socktype,
                    candidate->ai_protocol);
        if (fd < 0) {
            continue;
        }
        if (convexIO_setNonBlocking(fd) != 0) {
            close(fd);
            fd = -1;
            continue;
        }
        if (connect(fd, candidate->ai_addr, candidate->ai_addrlen) == 0) {
            break;
        }
        if (errno == EINPROGRESS) {
            break;
        }
        convexIO_setError("connect failed", strerror(errno));
        close(fd);
        fd = -1;
    }
    freeaddrinfo(resolved);

    if (fd < 0) {
        if (convexIOError[0] == '\0') {
            convexIO_setError("connect failed", "no usable address");
        }
        return IONUMBER(-1);
    }

    {
        /* Convex sync sends small frames, so Nagle would only add latency. */
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    }

    convexIOHandles[index].fd = fd;
    convexIOHandles[index].ownsFd = 1;
    convexIOHandles[index].eof = 0;
    convexIOHandles[index].state = CONVEXIO_CONNECTING;

    if (useTls) {
        SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());

        if (ctx == NULL) {
            convexIO_setSSLError("SSL_CTX_new failed");
            convexIO_release(&convexIOHandles[index]);
            return IONUMBER(-1);
        }
        SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
        /*
         * The Io side keeps one growing buffer of pending bytes and retries
         * whatever is left, so OpenSSL must be allowed to report a partial
         * write and to see a different buffer address on the retry. Without
         * these two modes a retry after WANT_WRITE fails with a bad-write-
         * retry error as soon as anything else is queued behind it.
         */
        SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE |
                                  SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
        /*
         * Load the explicit bundle first so a stripped runtime image fails
         * loudly here rather than silently trusting nothing, then fall back to
         * the compiled-in default paths.
         */
        if (SSL_CTX_load_verify_locations(
                ctx, "/etc/ssl/certs/ca-certificates.crt", NULL) != 1 &&
            SSL_CTX_set_default_verify_paths(ctx) != 1) {
            convexIO_setSSLError("no usable CA bundle");
            SSL_CTX_free(ctx);
            convexIO_release(&convexIOHandles[index]);
            return IONUMBER(-1);
        }

        {
            SSL *ssl = SSL_new(ctx);

            if (ssl == NULL) {
                convexIO_setSSLError("SSL_new failed");
                SSL_CTX_free(ctx);
                convexIO_release(&convexIOHandles[index]);
                return IONUMBER(-1);
            }
            /* SNI, then the identity the peer's certificate must prove. */
            SSL_set_tlsext_host_name(ssl, host);
            if (SSL_set1_host(ssl, host) != 1) {
                convexIO_setSSLError("SSL_set1_host failed");
                SSL_free(ssl);
                SSL_CTX_free(ctx);
                convexIO_release(&convexIOHandles[index]);
                return IONUMBER(-1);
            }
            SSL_set_fd(ssl, fd);
            SSL_set_connect_state(ssl);
            convexIOHandles[index].ssl = ssl;
            convexIOHandles[index].ctx = ctx;
        }
    }

    convexIOError[0] = '\0';
    return IONUMBER(index);
}

/*
 * Advance a connecting handle by exactly one non-blocking step. Returns 0 when
 * the connection is usable, 1 when it needs readability and 2 when it needs
 * writability. Io owns the waiting and the absolute deadline; this function
 * never sleeps.
 */
static IoObject *IoConvexIO_handshake(IoObject *self, IoObject *locals,
                                      IoMessage *m) {
    int index = IoMessage_locals_intArgAt_(m, locals, 0);
    ConvexIOHandle *handle = convexIO_at(index);

    if (handle == NULL) {
        IoState_error_(IOSTATE, m, "ConvexIO handshake on an unknown handle");
        return IONIL(self);
    }

    if (handle->state == CONVEXIO_CONNECTING) {
        struct pollfd probe;
        int soError = 0;
        socklen_t length = sizeof(soError);

        /*
         * SO_ERROR only becomes meaningful once the kernel has finished the
         * connect, and it reads as success before then. Asking poll() first
         * makes this function safe to call at any moment rather than only
         * immediately after a readiness wait.
         */
        probe.fd = handle->fd;
        probe.events = POLLOUT;
        probe.revents = 0;
        if (poll(&probe, 1, 0) == 0) {
            return IONUMBER(CONVEXIO_WANT_WRITE);
        }
        if (getsockopt(handle->fd, SOL_SOCKET, SO_ERROR, &soError, &length) !=
            0) {
            convexIO_setError("connect status unavailable", strerror(errno));
            return IONUMBER(-1);
        }
        if (soError == EINPROGRESS || soError == EALREADY) {
            return IONUMBER(CONVEXIO_WANT_WRITE);
        }
        if (soError != 0) {
            convexIO_setError("connect failed", strerror(soError));
            return IONUMBER(-1);
        }
        handle->state = (handle->ssl == NULL) ? CONVEXIO_OPEN : CONVEXIO_TLS;
    }

    if (handle->state == CONVEXIO_TLS) {
        int result = SSL_connect(handle->ssl);

        if (result == 1) {
            long verifyResult = SSL_get_verify_result(handle->ssl);

            if (verifyResult != X509_V_OK) {
                convexIO_setError("TLS certificate rejected",
                                  X509_verify_cert_error_string(verifyResult));
                return IONUMBER(-1);
            }
            handle->state = CONVEXIO_OPEN;
            return IONUMBER(CONVEXIO_READY);
        }
        switch (SSL_get_error(handle->ssl, result)) {
        case SSL_ERROR_WANT_READ:
            return IONUMBER(CONVEXIO_WANT_READ);
        case SSL_ERROR_WANT_WRITE:
            return IONUMBER(CONVEXIO_WANT_WRITE);
        default:
            convexIO_setSSLError("TLS handshake failed");
            return IONUMBER(-1);
        }
    }

    if (handle->state == CONVEXIO_OPEN) {
        return IONUMBER(CONVEXIO_READY);
    }

    convexIO_setError("handshake on a handle that is not connecting", NULL);
    return IONUMBER(-1);
}

/*
 * Read at most `maxBytes`. An empty Sequence means "nothing available right
 * now", which is not an error; nil means the peer closed. Io distinguishes the
 * two and only the second one retires a connection.
 */
static IoObject *IoConvexIO_read(IoObject *self, IoObject *locals,
                                 IoMessage *m) {
    int index = IoMessage_locals_intArgAt_(m, locals, 0);
    int maxBytes = IoMessage_locals_intArgAt_(m, locals, 1);
    ConvexIOHandle *handle = convexIO_at(index);
    /*
     * Io coroutines get a 128 KiB C stack, and every read runs on whichever
     * coroutine is current, so a 64 KiB automatic buffer would be a stack
     * overflow waiting to happen. The VM is single threaded and this function
     * never re-enters, so one static buffer is both safe and cheap.
     */
    static unsigned char buffer[CONVEXIO_MAX_READ];
    ssize_t received;

    if (handle == NULL) {
        IoState_error_(IOSTATE, m, "ConvexIO read on an unknown handle");
        return IONIL(self);
    }
    if (maxBytes < 1) {
        IoState_error_(IOSTATE, m, "ConvexIO read size must be positive");
        return IONIL(self);
    }
    if (maxBytes > CONVEXIO_MAX_READ) {
        maxBytes = CONVEXIO_MAX_READ;
    }
    if (handle->eof) {
        return IONIL(self);
    }

    if (handle->ssl != NULL) {
        int result = SSL_read(handle->ssl, buffer, maxBytes);

        if (result > 0) {
            return IOSEQ(buffer, (size_t)result);
        }
        switch (SSL_get_error(handle->ssl, result)) {
        case SSL_ERROR_WANT_READ:
        case SSL_ERROR_WANT_WRITE:
            return IOSEQ(buffer, 0);
        case SSL_ERROR_ZERO_RETURN:
            handle->eof = 1;
            return IONIL(self);
        case SSL_ERROR_SYSCALL:
            if (result == 0 || errno == 0) {
                /* A truncated TLS stream still ends the connection. */
                handle->eof = 1;
                return IONIL(self);
            }
            convexIO_setError("TLS read failed", strerror(errno));
            handle->eof = 1;
            return IONIL(self);
        default:
            convexIO_setSSLError("TLS read failed");
            handle->eof = 1;
            return IONIL(self);
        }
    }

    received = read(handle->fd, buffer, (size_t)maxBytes);
    if (received > 0) {
        return IOSEQ(buffer, (size_t)received);
    }
    if (received == 0) {
        handle->eof = 1;
        return IONIL(self);
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return IOSEQ(buffer, 0);
    }
    convexIO_setError("read failed", strerror(errno));
    handle->eof = 1;
    return IONIL(self);
}

/*
 * A partial write is normal and expected. Returning the accepted byte count
 * lets the Io side keep exactly one authoritative copy of the pending bytes,
 * so a retry can never duplicate a frame that the kernel already took.
 */
static IoObject *IoConvexIO_write(IoObject *self, IoObject *locals,
                                  IoMessage *m) {
    int index = IoMessage_locals_intArgAt_(m, locals, 0);
    IoSeq *payload = IoMessage_locals_seqArgAt_(m, locals, 1);
    ConvexIOHandle *handle = convexIO_at(index);
    size_t length = IoSeq_rawSize(payload);
    /* IoSeq_rawBytes is a char *, so the byte view is made explicit here. */
    const unsigned char *bytes = (const unsigned char *)IoSeq_rawBytes(payload);
    ssize_t sent;

    if (handle == NULL) {
        IoState_error_(IOSTATE, m, "ConvexIO write on an unknown handle");
        return IONIL(self);
    }
    if (length == 0) {
        return IONUMBER(0);
    }
    if (length > CONVEXIO_MAX_READ) {
        length = CONVEXIO_MAX_READ;
    }

    if (handle->ssl != NULL) {
        int result = SSL_write(handle->ssl, bytes, (int)length);

        if (result > 0) {
            return IONUMBER(result);
        }
        switch (SSL_get_error(handle->ssl, result)) {
        case SSL_ERROR_WANT_READ:
        case SSL_ERROR_WANT_WRITE:
            return IONUMBER(0);
        default:
            convexIO_setSSLError("TLS write failed");
            return IONUMBER(-1);
        }
    }

    sent = write(handle->fd, bytes, length);
    if (sent >= 0) {
        return IONUMBER((double)sent);
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return IONUMBER(0);
    }
    convexIO_setError("write failed", strerror(errno));
    return IONUMBER(-1);
}

/*
 * Bytes already decrypted inside OpenSSL's own buffer. poll() cannot see
 * these, so a reader that only trusts readiness would stall on a record that
 * has in fact already arrived.
 *
 * A handle that has already reported end of stream reports nothing, whatever
 * OpenSSL still holds. Those bytes can never be handed out again, and claiming
 * them as readable would drive the Io event loop's timeout to zero on every
 * pass and spin the process for as long as the handle is kept.
 */
static IoObject *IoConvexIO_bufferedBytes(IoObject *self, IoObject *locals,
                                          IoMessage *m) {
    int index = IoMessage_locals_intArgAt_(m, locals, 0);
    ConvexIOHandle *handle = convexIO_at(index);

    if (handle == NULL || handle->eof || handle->ssl == NULL) {
        return IONUMBER(0);
    }
    return IONUMBER(SSL_pending(handle->ssl));
}

static IoObject *IoConvexIO_listen(IoObject *self, IoObject *locals,
                                   IoMessage *m) {
    IoSeq *hostArgument = IoMessage_locals_seqArgAt_(m, locals, 0);
    int port = IoMessage_locals_intArgAt_(m, locals, 1);
    char host[256];
    char portText[16];
    size_t hostLength = IoSeq_rawSize(hostArgument);
    struct addrinfo hints;
    struct addrinfo *resolved = NULL;
    struct addrinfo *candidate = NULL;
    int index;
    int fd = -1;
    int resolveStatus;

    if (hostLength == 0 || hostLength >= sizeof(host)) {
        IoState_error_(IOSTATE, m, "ConvexIO listen host is out of range");
        return IONIL(self);
    }
    if (port < 0 || port > 65535) {
        IoState_error_(IOSTATE, m, "ConvexIO listen port is out of range");
        return IONIL(self);
    }
    memcpy(host, IoSeq_rawBytes(hostArgument), hostLength);
    host[hostLength] = '\0';
    snprintf(portText, sizeof(portText), "%d", port);

    index = convexIO_allocate();
    if (index < 0) {
        IoState_error_(IOSTATE, m, "ConvexIO handle table is full");
        return IONIL(self);
    }

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    resolveStatus = getaddrinfo(host, portText, &hints, &resolved);
    if (resolveStatus != 0) {
        convexIO_setError("listen resolve failed", gai_strerror(resolveStatus));
        return IONUMBER(-1);
    }

    for (candidate = resolved; candidate != NULL;
         candidate = candidate->ai_next) {
        int one = 1;

        fd = socket(candidate->ai_family, candidate->ai_socktype,
                    candidate->ai_protocol);
        if (fd < 0) {
            continue;
        }
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (bind(fd, candidate->ai_addr, candidate->ai_addrlen) == 0 &&
            listen(fd, 4) == 0 && convexIO_setNonBlocking(fd) == 0) {
            break;
        }
        convexIO_setError("listen failed", strerror(errno));
        close(fd);
        fd = -1;
    }
    freeaddrinfo(resolved);

    if (fd < 0) {
        if (convexIOError[0] == '\0') {
            convexIO_setError("listen failed", "no usable address");
        }
        return IONUMBER(-1);
    }

    convexIOHandles[index].fd = fd;
    convexIOHandles[index].ownsFd = 1;
    convexIOHandles[index].eof = 0;
    convexIOHandles[index].state = CONVEXIO_LISTENING;
    convexIOError[0] = '\0';
    return IONUMBER(index);
}

/* Returns the bound port, so a test can listen on port 0 and discover it. */
static IoObject *IoConvexIO_localPort(IoObject *self, IoObject *locals,
                                      IoMessage *m) {
    int index = IoMessage_locals_intArgAt_(m, locals, 0);
    ConvexIOHandle *handle = convexIO_at(index);
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);

    if (handle == NULL) {
        IoState_error_(IOSTATE, m, "ConvexIO localPort on an unknown handle");
        return IONIL(self);
    }
    if (getsockname(handle->fd, (struct sockaddr *)&address, &length) != 0) {
        convexIO_setError("getsockname failed", strerror(errno));
        return IONUMBER(-1);
    }
    if (address.ss_family == AF_INET6) {
        return IONUMBER(ntohs(((struct sockaddr_in6 *)&address)->sin6_port));
    }
    return IONUMBER(ntohs(((struct sockaddr_in *)&address)->sin_port));
}

static IoObject *IoConvexIO_accept(IoObject *self, IoObject *locals,
                                   IoMessage *m) {
    int index = IoMessage_locals_intArgAt_(m, locals, 0);
    ConvexIOHandle *handle = convexIO_at(index);
    int accepted;
    int slot;

    if (handle == NULL || handle->state != CONVEXIO_LISTENING) {
        IoState_error_(IOSTATE, m, "ConvexIO accept on a non-listening handle");
        return IONIL(self);
    }

    accepted = accept(handle->fd, NULL, NULL);
    if (accepted < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            return IONIL(self);
        }
        convexIO_setError("accept failed", strerror(errno));
        return IONUMBER(-1);
    }
    if (convexIO_setNonBlocking(accepted) != 0) {
        close(accepted);
        convexIO_setError("accept nonblocking failed", strerror(errno));
        return IONUMBER(-1);
    }

    slot = convexIO_allocate();
    if (slot < 0) {
        close(accepted);
        convexIO_setError("accept failed", "handle table is full");
        return IONUMBER(-1);
    }
    convexIOHandles[slot].fd = accepted;
    convexIOHandles[slot].ownsFd = 1;
    convexIOHandles[slot].eof = 0;
    convexIOHandles[slot].state = CONVEXIO_OPEN;
    return IONUMBER(slot);
}

/*
 * Wait for readiness across every interesting handle at once. The masks are
 * plain bitmasks over handle indexes, which keeps the whole readiness API to
 * three Numbers and lets the Io event loop own a single wait point.
 *
 * A negative timeout is rejected: every wait in the Io client is a slice of an
 * absolute deadline, and an unbounded one here would defeat all of them.
 */
static IoObject *IoConvexIO_wait(IoObject *self, IoObject *locals,
                                 IoMessage *m) {
    double readMask = IoMessage_locals_doubleArgAt_(m, locals, 0);
    double writeMask = IoMessage_locals_doubleArgAt_(m, locals, 1);
    double timeoutMs = IoMessage_locals_doubleArgAt_(m, locals, 2);
    struct pollfd descriptors[CONVEXIO_MAX_HANDLES];
    int handleForDescriptor[CONVEXIO_MAX_HANDLES];
    int count = 0;
    int index;
    int ready;

    if (timeoutMs < 0) {
        IoState_error_(IOSTATE, m, "ConvexIO wait requires a bounded timeout");
        return IONIL(self);
    }
    if (timeoutMs > 60000) {
        timeoutMs = 60000;
    }

    convexIOReadyRead = 0;
    convexIOReadyWrite = 0;
    convexIO_initTable();

    for (index = 0; index < CONVEXIO_MAX_HANDLES; index++) {
        double bit = (double)(1u << index);
        int wantRead = ((unsigned long long)(readMask / bit)) & 1ULL;
        int wantWrite = ((unsigned long long)(writeMask / bit)) & 1ULL;
        short events = 0;

        if (!wantRead && !wantWrite) {
            continue;
        }
        if (convexIOHandles[index].state == CONVEXIO_FREE) {
            continue;
        }
        if (wantRead) {
            events |= POLLIN;
        }
        if (wantWrite) {
            events |= POLLOUT;
        }
        descriptors[count].fd = convexIOHandles[index].fd;
        descriptors[count].events = events;
        descriptors[count].revents = 0;
        handleForDescriptor[count] = index;
        count++;
    }

    if (count == 0) {
        /*
         * Nothing to watch. Sleeping the full timeout is still correct and
         * keeps a caller's deadline loop from spinning.
         */
        struct timespec request;

        request.tv_sec = (time_t)(timeoutMs / 1000.0);
        request.tv_nsec =
            (long)((timeoutMs - (double)request.tv_sec * 1000.0) * 1000000.0);
        nanosleep(&request, NULL);
        return IONUMBER(0);
    }

    ready = poll(descriptors, (nfds_t)count, (int)timeoutMs);
    if (ready < 0) {
        if (errno == EINTR) {
            return IONUMBER(0);
        }
        convexIO_setError("poll failed", strerror(errno));
        IoState_error_(IOSTATE, m, "ConvexIO poll failed");
        return IONIL(self);
    }

    for (index = 0; index < count; index++) {
        double bit = (double)(1u << handleForDescriptor[index]);
        short revents = descriptors[index].revents;

        /*
         * Report an error or hangup as readability. The reader then observes
         * the real end-of-stream through read(), so there is exactly one place
         * that decides a connection is finished.
         */
        if (revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) {
            convexIOReadyRead += bit;
        }
        if (revents & POLLOUT) {
            convexIOReadyWrite += bit;
        }
    }

    return IONUMBER(convexIOReadyRead);
}

static IoObject *IoConvexIO_readyRead(IoObject *self, IoObject *locals,
                                      IoMessage *m) {
    return IONUMBER(convexIOReadyRead);
}

static IoObject *IoConvexIO_readyWrite(IoObject *self, IoObject *locals,
                                       IoMessage *m) {
    return IONUMBER(convexIOReadyWrite);
}

static IoObject *IoConvexIO_close(IoObject *self, IoObject *locals,
                                  IoMessage *m) {
    int index = IoMessage_locals_intArgAt_(m, locals, 0);
    ConvexIOHandle *handle = convexIO_at(index);

    if (handle != NULL) {
        convexIO_release(handle);
    }
    return IONUMBER(0);
}

/*
 * How many handles this table is currently holding. The bounded-teardown tests
 * use it to prove that closing a client really released its sockets rather
 * than returning early and leaving them behind.
 */
static IoObject *IoConvexIO_openHandleCount(IoObject *self, IoObject *locals,
                                            IoMessage *m) {
    int index;
    int total = 0;

    convexIO_initTable();
    for (index = 0; index < CONVEXIO_MAX_HANDLES; index++) {
        if (convexIOHandles[index].state != CONVEXIO_FREE) {
            total++;
        }
    }
    return IONUMBER(total);
}

/* ------------------------------------------------------------------ */
/* Registration                                                        */
/* ------------------------------------------------------------------ */

IoObject *IoConvexIO_proto(void *state) {
    IoMethodTable methodTable[] = {
        {"version", IoConvexIO_version},
        {"tlsVersion", IoConvexIO_tlsVersion},
        {"errorText", IoConvexIO_errorText},
        {"monotonicMs", IoConvexIO_monotonicMs},
        {"randomBytes", IoConvexIO_randomBytes},
        {"adoptDescriptor", IoConvexIO_adoptDescriptor},
        {"connect", IoConvexIO_connect},
        {"handshake", IoConvexIO_handshake},
        {"read", IoConvexIO_read},
        {"write", IoConvexIO_write},
        {"bufferedBytes", IoConvexIO_bufferedBytes},
        {"listen", IoConvexIO_listen},
        {"localPort", IoConvexIO_localPort},
        {"accept", IoConvexIO_accept},
        {"wait", IoConvexIO_wait},
        {"readyRead", IoConvexIO_readyRead},
        {"readyWrite", IoConvexIO_readyWrite},
        {"close", IoConvexIO_close},
        {"openHandleCount", IoConvexIO_openHandleCount},
        {NULL, NULL},
    };
    IoObject *self = IoObject_new(state);

    convexIO_initTable();
    IoState_registerProtoWithId_((IoState *)state, self, protoId);
    /*
     * Tagless methods work on the proto and on anything cloned from it, so a
     * caller never trips the CFunction receiver-type check.
     */
    IoObject_addTaglessMethodTable_(self, methodTable);
    return self;
}

/*
 * DynLib entry point. `context` is the object the caller wants the proto
 * installed on, matching Io's own AddonLoader convention.
 */
void IoConvexIOInit(IoObject *context) {
    IoState *state = IoObject_state(context);

    IoObject_setSlot_to_(context, IoState_symbolWithCString_(state, protoId),
                         IoConvexIO_proto(state));
}
