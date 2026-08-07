/*
 * convexext - an in-process gawk extension for the Convex Awk client.
 *
 * Awk has no sockets, no TLS, no monotonic clock, and no binary framing.
 * Rather than shell out to curl, websocat, Node, or Python - which would make
 * the demonstration a bridge instead of a native client - this extension gives
 * gawk the smallest set of transport primitives an ordinary language runtime
 * would already provide:
 *
 *   - deadline-bounded TCP and TLS client sockets, plus a loopback listener
 *     the conformance adapter uses for its controller connection,
 *   - a monotonic clock,
 *   - SHA-1/base64/randomness (the RFC6455 handshake and mutation run IDs),
 *   - RFC6455 frame encode/decode, including fragment reassembly and an
 *     incremental parser whose state survives a read timeout,
 *   - unsigned 64-bit comparison of Convex's base64 sync timestamps, which do
 *     not fit in an Awk double.
 *
 * Everything Convex-specific - the HTTP envelope, JSON, the Live owner and its
 * state machine, replay after reconnect, the NDJSON adapter, and the example -
 * stays in Awk in client/convex.awk.
 *
 * Test-only helpers (a TLS *server* used by the language-local TLS test) are
 * compiled only when CONVEX_TEST_HOOKS is defined, so the shipped runtime
 * extension carries no fixture surface.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509_vfy.h>
#include <openssl/x509v3.h>

#include "gawkapi.h"

static const gawk_api_t *api;
static awk_ext_id_t ext_id;
static const char *ext_version = "convexext 0.1.0";

int plugin_is_GPL_compatible;

/* Conservative bounds. The Awk client charges its own budgets on top of these;
 * these exist so a hostile or broken peer cannot grow the process before Awk
 * ever sees the bytes. */
#define CONVEX_MAX_CONNECTIONS 16
#define CONVEX_MAX_MESSAGE (1024L * 1024L)
#define CONVEX_READ_CHUNK 65536
#define CONVEX_MAX_BUFFER ((size_t) CONVEX_MAX_MESSAGE + CONVEX_READ_CHUNK + 14U)
#define CONVEX_FRAME_DEADLINE_MS 5000.0

/* Status codes shared with convex.awk. Keep these in sync with the
 * CONVEX_IO_* constants there. */
#define CONVEX_OK 1
#define CONVEX_TIMEOUT 0
#define CONVEX_EOF (-1)
#define CONVEX_ERROR (-2)

typedef struct convex_conn {
    int in_use;
    int fd;
    int borrowed; /* attached to an existing descriptor; never close it */
    int listening;
    int failed;
    int saw_eof;
    SSL *ssl;
    SSL_CTX *ctx;

    /* Raw bytes received but not yet consumed by the frame parser. A read
     * timeout leaves this untouched, so a half-delivered frame resumes rather
     * than restarting at a false boundary. */
    char *rbuf;
    size_t rlen;
    size_t rcap;

    /* Reassembly buffer for a fragmented data message. */
    char *frag;
    size_t frag_len;
    size_t frag_cap;
    int frag_opcode; /* 0 when no fragmented message is in progress */
    double frame_started_ms; /* absolute deadline survives caller time slices */

    /* Server endpoints mask nothing outbound and require masked inbound
     * frames. Only the language-local fixtures set this; the Convex client is
     * always the RFC6455 client half. */
    int server_role;
} convex_conn;

static convex_conn connections[CONVEX_MAX_CONNECTIONS];
static char last_error[512];

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static void set_error(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(last_error, sizeof(last_error), format, arguments);
    va_end(arguments);
}

static void set_ssl_error(const char *prefix)
{
    unsigned long code = ERR_get_error();
    char text[256];

    if (code == 0) {
        set_error("%s: %s", prefix, strerror(errno));
        return;
    }
    ERR_error_string_n(code, text, sizeof(text));
    ERR_clear_error();
    set_error("%s: %s", prefix, text);
}

static double monotonic_ms(void)
{
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0.0;
    }
    return (double) now.tv_sec * 1000.0 + (double) now.tv_nsec / 1000000.0;
}

static int remaining_ms(double deadline)
{
    double remaining = deadline - monotonic_ms();

    if (remaining <= 0.0) {
        return 0;
    }
    if (remaining > 60000.0) {
        return 60000;
    }
    return (int) remaining;
}

static int buffer_reserve(char **buffer, size_t *capacity, size_t needed)
{
    size_t next = *capacity == 0 ? 4096 : *capacity;
    char *grown;

    if (needed > CONVEX_MAX_BUFFER) {
        return 0;
    }
    if (needed <= *capacity) {
        return 1;
    }
    while (next < needed) {
        if (next > CONVEX_MAX_BUFFER / 2) {
            next = CONVEX_MAX_BUFFER;
            break;
        }
        next *= 2;
    }
    grown = realloc(*buffer, next);
    if (grown == NULL) {
        return 0;
    }
    *buffer = grown;
    *capacity = next;
    return 1;
}

static convex_conn *slot_for(double handle)
{
    int index = (int) handle;

    if (index < 0 || index >= CONVEX_MAX_CONNECTIONS) {
        set_error("connection handle %d is out of range", index);
        return NULL;
    }
    if (!connections[index].in_use) {
        set_error("connection handle %d is not open", index);
        return NULL;
    }
    return &connections[index];
}

static int allocate_slot(void)
{
    int index;

    for (index = 0; index < CONVEX_MAX_CONNECTIONS; index++) {
        if (!connections[index].in_use) {
            memset(&connections[index], 0, sizeof(convex_conn));
            connections[index].in_use = 1;
            connections[index].fd = -1;
            return index;
        }
    }
    set_error("no free connection slots (limit %d)", CONVEX_MAX_CONNECTIONS);
    return -1;
}

static void release_slot(convex_conn *conn)
{
    if (conn->ssl != NULL) {
        SSL_free(conn->ssl);
    }
    if (conn->ctx != NULL) {
        SSL_CTX_free(conn->ctx);
    }
    if (conn->fd >= 0 && !conn->borrowed) {
        close(conn->fd);
    }
    free(conn->rbuf);
    free(conn->frag);
    memset(conn, 0, sizeof(convex_conn));
    conn->fd = -1;
}

static int set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);

    if (flags < 0) {
        return 0;
    }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

/* Wait for one readiness event or the deadline. Returns 1 ready, 0 timeout,
 * -1 error. */
static int wait_ready(int fd, short events, double deadline)
{
    struct pollfd descriptor;
    int ready;

    for (;;) {
        descriptor.fd = fd;
        descriptor.events = events;
        descriptor.revents = 0;
        ready = poll(&descriptor, 1, remaining_ms(deadline));
        if (ready > 0) {
            return 1;
        }
        if (ready == 0) {
            return 0;
        }
        if (errno != EINTR) {
            return -1;
        }
        if (remaining_ms(deadline) == 0) {
            return 0;
        }
    }
}

/* ------------------------------------------------------------------ */
/* gawk value helpers                                                  */
/* ------------------------------------------------------------------ */

static void array_set_string(awk_array_t array, const char *key,
                             const char *value, size_t length)
{
    awk_value_t index;
    awk_value_t element;

    set_array_element(array,
                      make_const_string(key, strlen(key), &index),
                      make_const_string(value, length, &element));
}

static void array_set_number(awk_array_t array, const char *key, double value)
{
    awk_value_t index;
    awk_value_t element;

    set_array_element(array,
                      make_const_string(key, strlen(key), &index),
                      make_number(value, &element));
}

static int string_argument(int position, awk_value_t *value, const char *who)
{
    if (!get_argument(position, AWK_STRING, value)) {
        set_error("%s: argument %d must be a string", who, position + 1);
        return 0;
    }
    return 1;
}

static int number_argument(int position, double *out, const char *who)
{
    awk_value_t value;

    if (!get_argument(position, AWK_NUMBER, &value)) {
        set_error("%s: argument %d must be a number", who, position + 1);
        return 0;
    }
    *out = value.num_value;
    return 1;
}

static int array_argument(int position, awk_array_t *out, const char *who)
{
    awk_value_t value;

    if (!get_argument(position, AWK_ARRAY, &value)) {
        set_error("%s: argument %d must be an array", who, position + 1);
        return 0;
    }
    *out = value.array_cookie;
    clear_array(*out);
    return 1;
}

/* ------------------------------------------------------------------ */
/* Transport                                                           */
/* ------------------------------------------------------------------ */

static int tcp_connect(const char *host, int port, double deadline)
{
    struct addrinfo hints;
    struct addrinfo *candidates = NULL;
    struct addrinfo *candidate;
    char service[16];
    int fd = -1;
    int status;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(service, sizeof(service), "%d", port);

    /* getaddrinfo is the one blocking step; the container resolver's own
     * timeout bounds it. Every later step honours the caller's deadline. */
    status = getaddrinfo(host, service, &hints, &candidates);
    if (status != 0) {
        set_error("cannot resolve %s: %s", host, gai_strerror(status));
        return -1;
    }

    for (candidate = candidates; candidate != NULL; candidate = candidate->ai_next) {
        int flag = 1;
        int error = 0;
        socklen_t error_length = sizeof(error);

        fd = socket(candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol);
        if (fd < 0) {
            continue;
        }
        if (!set_nonblocking(fd)) {
            close(fd);
            fd = -1;
            continue;
        }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));

        if (connect(fd, candidate->ai_addr, candidate->ai_addrlen) == 0) {
            break;
        }
        if (errno != EINPROGRESS) {
            close(fd);
            fd = -1;
            continue;
        }
        if (wait_ready(fd, POLLOUT, deadline) != 1) {
            set_error("connect to %s:%d timed out", host, port);
            close(fd);
            fd = -1;
            continue;
        }
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_length) != 0 || error != 0) {
            set_error("connect to %s:%d failed: %s", host, port,
                      strerror(error != 0 ? error : errno));
            close(fd);
            fd = -1;
            continue;
        }
        break;
    }

    freeaddrinfo(candidates);
    if (fd < 0 && last_error[0] == '\0') {
        set_error("cannot connect to %s:%d", host, port);
    }
    return fd;
}

/* Load the CA bundle the container actually ships. SSL_CERT_FILE is the
 * convention every runtime image in this repository already sets. */
static int load_trust_store(SSL_CTX *ctx)
{
    const char *bundle = getenv("SSL_CERT_FILE");

    if (bundle != NULL && bundle[0] != '\0') {
        if (SSL_CTX_load_verify_locations(ctx, bundle, NULL) != 1) {
            set_ssl_error("cannot load SSL_CERT_FILE");
            return 0;
        }
        return 1;
    }
    if (SSL_CTX_set_default_verify_paths(ctx) != 1) {
        set_ssl_error("cannot load the default trust store");
        return 0;
    }
    return 1;
}

static int start_tls(convex_conn *conn, const char *host, double deadline)
{
    struct in6_addr scratch;
    int numeric_host;

    conn->ctx = SSL_CTX_new(TLS_client_method());
    if (conn->ctx == NULL) {
        set_ssl_error("cannot create a TLS context");
        return 0;
    }
    SSL_CTX_set_min_proto_version(conn->ctx, TLS1_2_VERSION);
    if (!load_trust_store(conn->ctx)) {
        return 0;
    }

    conn->ssl = SSL_new(conn->ctx);
    if (conn->ssl == NULL) {
        set_ssl_error("cannot create a TLS session");
        return 0;
    }
    if (SSL_set_fd(conn->ssl, conn->fd) != 1) {
        set_ssl_error("cannot attach the socket to TLS");
        return 0;
    }

    numeric_host = inet_pton(AF_INET, host, &scratch) == 1 ||
                   inet_pton(AF_INET6, host, &scratch) == 1;
    if (numeric_host) {
        /* SSL_set1_host applies DNS-name matching. Numeric deployment hosts
         * instead need OpenSSL's IP-address SAN verifier. */
        if (X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(conn->ssl), host) != 1) {
            set_ssl_error("cannot pin the peer address");
            return 0;
        }
    } else {
        /* SNI plus verified hostname matching. Without both, a valid
         * certificate for some other name would be accepted. */
        if (SSL_set_tlsext_host_name(conn->ssl, host) != 1) {
            set_ssl_error("cannot set the TLS server name");
            return 0;
        }
        if (SSL_set1_host(conn->ssl, host) != 1) {
            set_ssl_error("cannot pin the peer hostname");
            return 0;
        }
    }
    SSL_set_verify(conn->ssl, SSL_VERIFY_PEER, NULL);

    for (;;) {
        int result = SSL_connect(conn->ssl);
        int reason;

        if (result == 1) {
            return 1;
        }
        reason = SSL_get_error(conn->ssl, result);
        if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
            short events = reason == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT;
            if (wait_ready(conn->fd, events, deadline) != 1) {
                set_error("TLS handshake with %s timed out", host);
                return 0;
            }
            continue;
        }
        set_ssl_error("TLS handshake failed");
        return 0;
    }
}

/* One read attempt. Returns bytes read, or a CONVEX_* status. */
static long connection_read(convex_conn *conn, char *target, size_t capacity,
                            double deadline)
{
    for (;;) {
        if (conn->ssl != NULL) {
            int result = SSL_read(conn->ssl, target, (int) capacity);
            int reason;

            if (result > 0) {
                return result;
            }
            reason = SSL_get_error(conn->ssl, result);
            if (reason == SSL_ERROR_ZERO_RETURN) {
                conn->saw_eof = 1;
                return CONVEX_EOF;
            }
            if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
                short events = reason == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT;
                int ready = wait_ready(conn->fd, events, deadline);
                if (ready == 0) {
                    return CONVEX_TIMEOUT;
                }
                if (ready < 0) {
                    set_error("poll failed: %s", strerror(errno));
                    conn->failed = 1;
                    return CONVEX_ERROR;
                }
                continue;
            }
            if (reason == SSL_ERROR_SYSCALL && ERR_peek_error() == 0) {
                /* An abrupt close without close_notify still ends the stream;
                 * the caller decides whether that is an error in context. */
                conn->saw_eof = 1;
                return CONVEX_EOF;
            }
            set_ssl_error("TLS read failed");
            conn->failed = 1;
            return CONVEX_ERROR;
        } else {
            ssize_t result;
            int ready = wait_ready(conn->fd, POLLIN, deadline);

            if (ready == 0) {
                return CONVEX_TIMEOUT;
            }
            if (ready < 0) {
                set_error("poll failed: %s", strerror(errno));
                conn->failed = 1;
                return CONVEX_ERROR;
            }
            result = read(conn->fd, target, capacity);
            if (result > 0) {
                return (long) result;
            }
            if (result == 0) {
                conn->saw_eof = 1;
                return CONVEX_EOF;
            }
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            set_error("read failed: %s", strerror(errno));
            conn->failed = 1;
            return CONVEX_ERROR;
        }
    }
}

/* Write every byte or fail. A timeout after a partial write poisons the
 * connection: resuming mid-frame would corrupt the peer's parser. */
static int connection_write(convex_conn *conn, const char *data, size_t length,
                            double deadline)
{
    size_t written = 0;

    while (written < length) {
        if (conn->ssl != NULL) {
            int result = SSL_write(conn->ssl, data + written, (int) (length - written));
            int reason;

            if (result > 0) {
                written += (size_t) result;
                continue;
            }
            reason = SSL_get_error(conn->ssl, result);
            if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
                short events = reason == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT;
                int ready = wait_ready(conn->fd, events, deadline);
                if (ready == 1) {
                    continue;
                }
                set_error("TLS write timed out after %lu of %lu bytes",
                          (unsigned long) written, (unsigned long) length);
                if (written > 0) {
                    conn->failed = 1;
                }
                /* Retrying a partially written frame/request from byte zero
                 * would duplicate its prefix and corrupt the peer's parser. */
                return ready == 0 && written == 0 ? CONVEX_TIMEOUT : CONVEX_ERROR;
            }
            set_ssl_error("TLS write failed");
            conn->failed = 1;
            return CONVEX_ERROR;
        } else {
            ssize_t result;
            int ready = wait_ready(conn->fd, POLLOUT, deadline);

            if (ready != 1) {
                set_error("write timed out after %lu of %lu bytes",
                          (unsigned long) written, (unsigned long) length);
                if (written > 0) {
                    conn->failed = 1;
                }
                return ready == 0 && written == 0 ? CONVEX_TIMEOUT : CONVEX_ERROR;
            }
            result = write(conn->fd, data + written, length - written);
            if (result > 0) {
                written += (size_t) result;
                continue;
            }
            if (result < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
                continue;
            }
            set_error("write failed: %s", strerror(errno));
            conn->failed = 1;
            return CONVEX_ERROR;
        }
    }
    return CONVEX_OK;
}

/* ------------------------------------------------------------------ */
/* RFC6455 framing                                                     */
/* ------------------------------------------------------------------ */

/* Pull more bytes into the pending buffer. The buffer is never rewound on a
 * timeout, which is what keeps a half-read frame resumable. */
static int fill_pending(convex_conn *conn, double deadline)
{
    long result;

    if (!buffer_reserve(&conn->rbuf, &conn->rcap, conn->rlen + CONVEX_READ_CHUNK)) {
        set_error("receive buffer exhausted");
        conn->failed = 1;
        return CONVEX_ERROR;
    }
    result = connection_read(conn, conn->rbuf + conn->rlen, CONVEX_READ_CHUNK, deadline);
    if (result > 0) {
        conn->rlen += (size_t) result;
        return CONVEX_OK;
    }
    return (int) result;
}

static void consume_pending(convex_conn *conn, size_t count)
{
    if (count >= conn->rlen) {
        conn->rlen = 0;
        return;
    }
    memmove(conn->rbuf, conn->rbuf + count, conn->rlen - count);
    conn->rlen -= count;
}

/* Decode one frame header out of the pending buffer.
 * Returns 1 on a complete frame, 0 when more bytes are needed, -1 on a
 * protocol violation. */
static int parse_frame(convex_conn *conn, int *fin, int *opcode,
                       size_t *payload_offset, size_t *payload_length)
{
    unsigned char first;
    unsigned char second;
    size_t header = 2;
    size_t length;
    int masked;

    if (conn->rlen < 2) {
        return 0;
    }
    first = (unsigned char) conn->rbuf[0];
    second = (unsigned char) conn->rbuf[1];

    if ((first & 0x70) != 0) {
        set_error("peer set a reserved WebSocket bit");
        return -1;
    }
    masked = (second & 0x80) != 0;
    if (masked != conn->server_role) {
        set_error(conn->server_role ? "client WebSocket frame was not masked"
                                    : "server WebSocket frame was masked");
        return -1;
    }

    *fin = (first & 0x80) != 0;
    *opcode = first & 0x0f;
    length = second & 0x7f;

    if (length == 126) {
        if (conn->rlen < 4) {
            return 0;
        }
        length = ((size_t) (unsigned char) conn->rbuf[2] << 8) |
                 (size_t) (unsigned char) conn->rbuf[3];
        if (length < 126) {
            set_error("WebSocket length was not minimally encoded");
            return -1;
        }
        header = 4;
    } else if (length == 127) {
        int index;
        unsigned long long wide = 0;

        if (conn->rlen < 10) {
            return 0;
        }
        for (index = 0; index < 8; index++) {
            wide = (wide << 8) | (unsigned long long) (unsigned char) conn->rbuf[2 + index];
        }
        if ((wide >> 63) != 0) {
            set_error("WebSocket length has the reserved high bit set");
            return -1;
        }
        if (wide < 65536ULL) {
            set_error("WebSocket length was not minimally encoded");
            return -1;
        }
        if (wide > (unsigned long long) CONVEX_MAX_MESSAGE) {
            set_error("WebSocket frame exceeds the %ld byte limit",
                      (long) CONVEX_MAX_MESSAGE);
            return -1;
        }
        length = (size_t) wide;
        header = 10;
    }

    if (length > (size_t) CONVEX_MAX_MESSAGE) {
        set_error("WebSocket frame exceeds the %ld byte limit", (long) CONVEX_MAX_MESSAGE);
        return -1;
    }
    if (*opcode == 8 || *opcode == 9 || *opcode == 10) {
        if (!*fin || length > 125) {
            set_error("invalid WebSocket control frame");
            return -1;
        }
    } else if (*opcode != 0 && *opcode != 1 && *opcode != 2) {
        set_error("unsupported WebSocket opcode %d", *opcode);
        return -1;
    }

    if (conn->server_role) {
        size_t position;
        unsigned char mask[4];

        if (conn->rlen < header + 4) {
            return 0;
        }
        memcpy(mask, conn->rbuf + header, 4);
        header += 4;
        if (conn->rlen < header + length) {
            return 0;
        }
        /* Unmask in place. The bytes are consumed by this call either way, so
         * the payload can never be unmasked twice. */
        for (position = 0; position < length; position++) {
            conn->rbuf[header + position] =
                (char) ((unsigned char) conn->rbuf[header + position] ^ mask[position % 4]);
        }
    }

    if (conn->rlen < header + length) {
        return 0;
    }
    *payload_offset = header;
    *payload_length = length;
    return 1;
}

/* ------------------------------------------------------------------ */
/* Extension functions                                                 */
/* ------------------------------------------------------------------ */

static awk_value_t *do_now_ms(int nargs, awk_value_t *result,
                              struct awk_ext_func *unused)
{
    (void) nargs;
    (void) unused;
    return make_number(monotonic_ms(), result);
}

/* Construct one arbitrary byte. GNU Awk cannot spell NUL with source-level
 * text reliably, but the independent fixture needs it in RFC6455 headers and
 * masked payloads. This is a byte primitive, not a framing implementation. */
static awk_value_t *do_byte(int nargs, awk_value_t *result,
                            struct awk_ext_func *unused)
{
    double value;
    char byte;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &value, "convex_byte") || value < 0.0 || value > 255.0 ||
        value != (double) (int) value) {
        set_error("convex_byte: value must be an integer from 0 through 255");
        return make_const_string("", 0, result);
    }
    byte = (char) (unsigned char) value;
    return make_const_string(&byte, 1, result);
}

/* Wait without spinning. The Awk owner has nothing to poll while it is waiting
 * out a reconnect backoff, and a busy loop there would burn a whole CPU. */
static awk_value_t *do_sleep(int nargs, awk_value_t *result,
                             struct awk_ext_func *unused)
{
    double milliseconds;
    struct timespec request;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &milliseconds, "convex_sleep")) {
        return make_number(0, result);
    }
    if (milliseconds <= 0) {
        return make_number(0, result);
    }
    if (milliseconds > 60000) {
        milliseconds = 60000;
    }
    request.tv_sec = (time_t) (milliseconds / 1000.0);
    request.tv_nsec = (long) ((milliseconds - (double) request.tv_sec * 1000.0) * 1000000.0);
    nanosleep(&request, NULL);
    return make_number(1, result);
}

static awk_value_t *do_last_error(int nargs, awk_value_t *result,
                                  struct awk_ext_func *unused)
{
    (void) nargs;
    (void) unused;
    return make_const_string(last_error, strlen(last_error), result);
}

static awk_value_t *do_version(int nargs, awk_value_t *result,
                               struct awk_ext_func *unused)
{
    char text[256];

    (void) nargs;
    (void) unused;
    snprintf(text, sizeof(text), "%s; %s", ext_version, OpenSSL_version(OPENSSL_VERSION));
    return make_const_string(text, strlen(text), result);
}

static awk_value_t *do_connect(int nargs, awk_value_t *result,
                               struct awk_ext_func *unused)
{
    awk_value_t host;
    double port;
    double secure;
    double timeout;
    double deadline;
    int index;
    convex_conn *conn;
    char hostname[256];

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!string_argument(0, &host, "convex_connect") ||
        !number_argument(1, &port, "convex_connect") ||
        !number_argument(2, &secure, "convex_connect") ||
        !number_argument(3, &timeout, "convex_connect")) {
        return make_number(-1, result);
    }
    if (host.str_value.len == 0 || host.str_value.len >= sizeof(hostname)) {
        set_error("convex_connect: host name length %lu is unusable",
                  (unsigned long) host.str_value.len);
        return make_number(-1, result);
    }
    memcpy(hostname, host.str_value.str, host.str_value.len);
    hostname[host.str_value.len] = '\0';

    index = allocate_slot();
    if (index < 0) {
        return make_number(-1, result);
    }
    conn = &connections[index];
    deadline = monotonic_ms() + timeout;

    conn->fd = tcp_connect(hostname, (int) port, deadline);
    if (conn->fd < 0) {
        release_slot(conn);
        return make_number(-1, result);
    }
    if (secure != 0.0 && !start_tls(conn, hostname, deadline)) {
        release_slot(conn);
        return make_number(-1, result);
    }
    return make_number(index, result);
}

static awk_value_t *do_attach(int nargs, awk_value_t *result,
                              struct awk_ext_func *unused)
{
    double descriptor;
    int index;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &descriptor, "convex_attach")) {
        return make_number(-1, result);
    }
    index = allocate_slot();
    if (index < 0) {
        return make_number(-1, result);
    }
    connections[index].fd = (int) descriptor;
    connections[index].borrowed = 1;
    if (!set_nonblocking(connections[index].fd)) {
        set_error("cannot make descriptor %d non-blocking: %s",
                  (int) descriptor, strerror(errno));
        release_slot(&connections[index]);
        return make_number(-1, result);
    }
    return make_number(index, result);
}

static awk_value_t *do_listen(int nargs, awk_value_t *result,
                              struct awk_ext_func *unused)
{
    awk_value_t host;
    double port;
    struct sockaddr_in address;
    char hostname[256];
    int index;
    int fd;
    int reuse = 1;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!string_argument(0, &host, "convex_listen") ||
        !number_argument(1, &port, "convex_listen")) {
        return make_number(-1, result);
    }
    if (host.str_value.len == 0 || host.str_value.len >= sizeof(hostname)) {
        set_error("convex_listen: bind address is unusable");
        return make_number(-1, result);
    }
    memcpy(hostname, host.str_value.str, host.str_value.len);
    hostname[host.str_value.len] = '\0';

    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short) port);
    if (inet_pton(AF_INET, hostname, &address.sin_addr) != 1) {
        set_error("convex_listen: %s is not an IPv4 address", hostname);
        return make_number(-1, result);
    }

    index = allocate_slot();
    if (index < 0) {
        return make_number(-1, result);
    }
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        set_error("cannot create a listening socket: %s", strerror(errno));
        release_slot(&connections[index]);
        return make_number(-1, result);
    }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    connections[index].fd = fd;
    connections[index].listening = 1;
    if (bind(fd, (struct sockaddr *) &address, sizeof(address)) != 0 ||
        listen(fd, 4) != 0 || !set_nonblocking(fd)) {
        set_error("cannot listen on %s:%d: %s", hostname, (int) port, strerror(errno));
        release_slot(&connections[index]);
        return make_number(-1, result);
    }
    return make_number(index, result);
}

static awk_value_t *do_port(int nargs, awk_value_t *result,
                            struct awk_ext_func *unused)
{
    double handle;
    convex_conn *conn;
    struct sockaddr_in address;
    socklen_t length = sizeof(address);

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_port")) {
        return make_number(-1, result);
    }
    conn = slot_for(handle);
    if (conn == NULL) {
        return make_number(-1, result);
    }
    if (getsockname(conn->fd, (struct sockaddr *) &address, &length) != 0) {
        set_error("cannot read the local port: %s", strerror(errno));
        return make_number(-1, result);
    }
    return make_number(ntohs(address.sin_port), result);
}

static awk_value_t *do_accept(int nargs, awk_value_t *result,
                              struct awk_ext_func *unused)
{
    double handle;
    double timeout;
    convex_conn *listener;
    int index;
    int fd;
    int ready;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_accept") ||
        !number_argument(1, &timeout, "convex_accept")) {
        return make_number(-1, result);
    }
    listener = slot_for(handle);
    if (listener == NULL || !listener->listening) {
        set_error("convex_accept: handle is not a listening socket");
        return make_number(-1, result);
    }
    ready = wait_ready(listener->fd, POLLIN, monotonic_ms() + timeout);
    if (ready == 0) {
        set_error("no controller connection arrived before the deadline");
        return make_number(-2, result);
    }
    if (ready < 0) {
        set_error("poll failed while accepting: %s", strerror(errno));
        return make_number(-1, result);
    }
    fd = accept(listener->fd, NULL, NULL);
    if (fd < 0) {
        set_error("accept failed: %s", strerror(errno));
        return make_number(-1, result);
    }
    index = allocate_slot();
    if (index < 0) {
        close(fd);
        return make_number(-1, result);
    }
    connections[index].fd = fd;
    if (!set_nonblocking(fd)) {
        set_error("cannot make the accepted socket non-blocking: %s", strerror(errno));
        release_slot(&connections[index]);
        return make_number(-1, result);
    }
    return make_number(index, result);
}

static awk_value_t *do_send(int nargs, awk_value_t *result,
                            struct awk_ext_func *unused)
{
    awk_value_t data;
    double handle;
    double timeout;
    convex_conn *conn;
    int status;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_send") ||
        !string_argument(1, &data, "convex_send") ||
        !number_argument(2, &timeout, "convex_send")) {
        return make_number(CONVEX_ERROR, result);
    }
    conn = slot_for(handle);
    if (conn == NULL) {
        return make_number(CONVEX_ERROR, result);
    }
    if (conn->failed) {
        set_error("connection is unusable after a partial or failed write");
        return make_number(CONVEX_ERROR, result);
    }
    status = connection_write(conn, data.str_value.str, data.str_value.len,
                              monotonic_ms() + timeout);
    return make_number(status, result);
}

static awk_value_t *do_recv(int nargs, awk_value_t *result,
                            struct awk_ext_func *unused)
{
    double handle;
    double maximum;
    double timeout;
    awk_array_t out;
    convex_conn *conn;
    char *buffer;
    long received;
    size_t capacity;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_recv") ||
        !number_argument(1, &maximum, "convex_recv") ||
        !number_argument(2, &timeout, "convex_recv") ||
        !array_argument(3, &out, "convex_recv")) {
        return make_number(CONVEX_ERROR, result);
    }
    conn = slot_for(handle);
    if (conn == NULL) {
        return make_number(CONVEX_ERROR, result);
    }
    if (conn->failed) {
        set_error("connection is unusable after a protocol or transport failure");
        array_set_string(out, "data", "", 0);
        array_set_string(out, "error", last_error, strlen(last_error));
        return make_number(CONVEX_ERROR, result);
    }
    capacity = (size_t) maximum;
    if (capacity == 0 || capacity > (size_t) CONVEX_MAX_MESSAGE) {
        capacity = (size_t) CONVEX_MAX_MESSAGE;
    }
    buffer = malloc(capacity);
    if (buffer == NULL) {
        set_error("cannot allocate a %lu byte receive buffer", (unsigned long) capacity);
        return make_number(CONVEX_ERROR, result);
    }
    received = connection_read(conn, buffer, capacity, monotonic_ms() + timeout);
    if (received > 0) {
        array_set_string(out, "data", buffer, (size_t) received);
        free(buffer);
        return make_number(CONVEX_OK, result);
    }
    free(buffer);
    array_set_string(out, "data", "", 0);
    if (received == CONVEX_ERROR) {
        array_set_string(out, "error", last_error, strlen(last_error));
    }
    return make_number((double) received, result);
}

static awk_value_t *do_close(int nargs, awk_value_t *result,
                             struct awk_ext_func *unused)
{
    double handle;
    convex_conn *conn;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_close")) {
        return make_number(0, result);
    }
    conn = slot_for(handle);
    if (conn == NULL) {
        return make_number(0, result);
    }
    if (conn->ssl != NULL) {
        /* One non-blocking attempt only. A stalled peer must never make close
         * unbounded, so the descriptor closes either way. */
        SSL_shutdown(conn->ssl);
    }
    release_slot(conn);
    return make_number(1, result);
}

/* Frame and write one WebSocket frame. `fin` is separate from the opcode so
 * that the language-local fixtures can emit a genuinely fragmented message;
 * the Convex client itself only ever sends complete frames. */
static int ws_write_frame(convex_conn *conn, int fin, int opcode,
                          const char *payload, size_t length, double timeout)
{
    unsigned char header[14];
    unsigned char mask[4];
    int mask_flag;
    size_t header_length = 0;
    size_t index;
    char *frame;
    int status;

    if (opcode != 0 && opcode != 1 && opcode != 2 && opcode != 8 &&
        opcode != 9 && opcode != 10) {
        set_error("WebSocket opcode %d is not supported", opcode);
        return CONVEX_ERROR;
    }
    if (length > (size_t) CONVEX_MAX_MESSAGE) {
        set_error("outgoing WebSocket message exceeds the %ld byte limit",
                  (long) CONVEX_MAX_MESSAGE);
        return CONVEX_ERROR;
    }
    if ((opcode == 8 || opcode == 9 || opcode == 10) && (length > 125 || !fin)) {
        set_error("a WebSocket control frame must be final and at most 125 bytes");
        return CONVEX_ERROR;
    }

    /* A client always masks; a server never does. */
    mask_flag = conn->server_role ? 0x00 : 0x80;
    if (!conn->server_role && RAND_bytes(mask, sizeof(mask)) != 1) {
        set_ssl_error("cannot generate a WebSocket mask");
        return CONVEX_ERROR;
    }

    header[header_length++] = (unsigned char) ((fin ? 0x80 : 0x00) | (opcode & 0x0f));
    if (length < 126) {
        header[header_length++] = (unsigned char) (mask_flag | length);
    } else if (length < 65536) {
        header[header_length++] = (unsigned char) (mask_flag | 126);
        header[header_length++] = (unsigned char) ((length >> 8) & 0xff);
        header[header_length++] = (unsigned char) (length & 0xff);
    } else {
        int shift;

        header[header_length++] = (unsigned char) (mask_flag | 127);
        for (shift = 56; shift >= 0; shift -= 8) {
            header[header_length++] = (unsigned char) ((length >> shift) & 0xff);
        }
    }
    if (!conn->server_role) {
        memcpy(header + header_length, mask, sizeof(mask));
        header_length += sizeof(mask);
    }

    frame = malloc(header_length + length + 1);
    if (frame == NULL) {
        set_error("cannot allocate an outgoing WebSocket frame");
        return CONVEX_ERROR;
    }
    memcpy(frame, header, header_length);
    for (index = 0; index < length; index++) {
        unsigned char byte = (unsigned char) payload[index];

        frame[header_length + index] =
            (char) (conn->server_role ? byte : (byte ^ mask[index % 4]));
    }
    status = connection_write(conn, frame, header_length + length,
                              monotonic_ms() + timeout);
    free(frame);
    return status;
}

static awk_value_t *do_ws_send(int nargs, awk_value_t *result,
                               struct awk_ext_func *unused)
{
    awk_value_t payload;
    double handle;
    double opcode;
    double timeout;
    convex_conn *conn;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_ws_send") ||
        !number_argument(1, &opcode, "convex_ws_send") ||
        !string_argument(2, &payload, "convex_ws_send") ||
        !number_argument(3, &timeout, "convex_ws_send")) {
        return make_number(CONVEX_ERROR, result);
    }
    conn = slot_for(handle);
    if (conn == NULL) {
        return make_number(CONVEX_ERROR, result);
    }
    if (conn->failed) {
        set_error("connection is unusable after a protocol or transport failure");
        return make_number(CONVEX_ERROR, result);
    }
    if ((int) opcode == 0) {
        set_error("convex_ws_send cannot send a continuation frame");
        return make_number(CONVEX_ERROR, result);
    }
    return make_number(ws_write_frame(conn, 1, (int) opcode, payload.str_value.str,
                                      payload.str_value.len, timeout), result);
}

/* Fixture-facing: send one frame with an explicit FIN bit and opcode. */
static awk_value_t *do_ws_send_frame(int nargs, awk_value_t *result,
                                     struct awk_ext_func *unused)
{
    awk_value_t payload;
    double handle;
    double fin;
    double opcode;
    double timeout;
    convex_conn *conn;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_ws_send_frame") ||
        !number_argument(1, &fin, "convex_ws_send_frame") ||
        !number_argument(2, &opcode, "convex_ws_send_frame") ||
        !string_argument(3, &payload, "convex_ws_send_frame") ||
        !number_argument(4, &timeout, "convex_ws_send_frame")) {
        return make_number(CONVEX_ERROR, result);
    }
    conn = slot_for(handle);
    if (conn == NULL) {
        return make_number(CONVEX_ERROR, result);
    }
    if (conn->failed) {
        set_error("connection is unusable after a protocol or transport failure");
        return make_number(CONVEX_ERROR, result);
    }
    return make_number(ws_write_frame(conn, fin != 0.0, (int) opcode,
                                      payload.str_value.str, payload.str_value.len,
                                      timeout), result);
}

static awk_value_t *do_ws_recv(int nargs, awk_value_t *result,
                               struct awk_ext_func *unused)
{
    double handle;
    double timeout;
    awk_array_t out;
    convex_conn *conn;
    double deadline;
    double read_deadline;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_ws_recv") ||
        !number_argument(1, &timeout, "convex_ws_recv") ||
        !array_argument(2, &out, "convex_ws_recv")) {
        return make_number(CONVEX_ERROR, result);
    }
    conn = slot_for(handle);
    if (conn == NULL) {
        array_set_string(out, "kind", "error", 5);
        array_set_string(out, "error", last_error, strlen(last_error));
        return make_number(CONVEX_ERROR, result);
    }
    if (conn->failed) {
        set_error("connection is unusable after a protocol or transport failure");
        array_set_string(out, "kind", "error", 5);
        array_set_string(out, "error", last_error, strlen(last_error));
        return make_number(CONVEX_ERROR, result);
    }
    array_set_string(out, "payload", "", 0);
    if (conn->frame_started_ms == 0.0 && conn->rlen > 0) {
        conn->frame_started_ms = monotonic_ms();
    }
    if (conn->frame_started_ms > 0.0 &&
        monotonic_ms() - conn->frame_started_ms >= CONVEX_FRAME_DEADLINE_MS) {
        set_error("WebSocket frame did not complete within %.0f ms",
                  CONVEX_FRAME_DEADLINE_MS);
        conn->failed = 1;
        array_set_string(out, "kind", "error", 5);
        array_set_string(out, "error", last_error, strlen(last_error));
        return make_number(CONVEX_ERROR, result);
    }
    deadline = monotonic_ms() + timeout;

    for (;;) {
        int fin = 0;
        int opcode = 0;
        size_t offset = 0;
        size_t length = 0;
        int parsed = parse_frame(conn, &fin, &opcode, &offset, &length);
        int status;

        if (parsed < 0) {
            conn->failed = 1;
            array_set_string(out, "kind", "error", 5);
            array_set_string(out, "class", "protocol", 8);
            array_set_string(out, "error", last_error, strlen(last_error));
            return make_number(CONVEX_ERROR, result);
        }
        if (parsed == 0) {
            read_deadline = deadline;
            if (conn->frame_started_ms > 0.0 &&
                conn->frame_started_ms + CONVEX_FRAME_DEADLINE_MS < read_deadline) {
                read_deadline = conn->frame_started_ms + CONVEX_FRAME_DEADLINE_MS;
            }
            status = fill_pending(conn, read_deadline);
            if (status == CONVEX_OK) {
                if (conn->frame_started_ms == 0.0) {
                    conn->frame_started_ms = monotonic_ms();
                }
                continue;
            }
            if (status == CONVEX_TIMEOUT) {
                if (conn->frame_started_ms > 0.0 &&
                    monotonic_ms() - conn->frame_started_ms >= CONVEX_FRAME_DEADLINE_MS) {
                    set_error("WebSocket frame did not complete within %.0f ms",
                              CONVEX_FRAME_DEADLINE_MS);
                    conn->failed = 1;
                    array_set_string(out, "kind", "error", 5);
                    array_set_string(out, "error", last_error, strlen(last_error));
                    return make_number(CONVEX_ERROR, result);
                }
                /* Partial frame bytes stay buffered for the next call. */
                array_set_string(out, "kind", "timeout", 7);
                return make_number(CONVEX_TIMEOUT, result);
            }
            if (status == CONVEX_EOF) {
                array_set_string(out, "kind", "eof", 3);
                return make_number(CONVEX_EOF, result);
            }
            array_set_string(out, "kind", "error", 5);
            array_set_string(out, "error", last_error, strlen(last_error));
            return make_number(CONVEX_ERROR, result);
        }

        if (opcode == 9 || opcode == 10) {
            const char *kind = opcode == 9 ? "ping" : "pong";

            array_set_string(out, "kind", kind, strlen(kind));
            array_set_string(out, "payload", conn->rbuf + offset, length);
            consume_pending(conn, offset + length);
            if (conn->frag_opcode == 0) {
                conn->frame_started_ms = conn->rlen > 0 ? monotonic_ms() : 0.0;
            }
            return make_number(CONVEX_OK, result);
        }
        if (opcode == 8) {
            double code = 1005;

            if (length == 1 || length > 125) {
                set_error("invalid WebSocket close payload");
                conn->failed = 1;
                consume_pending(conn, offset + length);
                array_set_string(out, "kind", "error", 5);
                array_set_string(out, "class", "protocol", 8);
                array_set_string(out, "error", last_error, strlen(last_error));
                return make_number(CONVEX_ERROR, result);
            }
            if (length >= 2) {
                code = (double) (((unsigned char) conn->rbuf[offset] << 8) |
                                 (unsigned char) conn->rbuf[offset + 1]);
                if (code < 1000 || code >= 5000 || code == 1004 || code == 1005 ||
                    code == 1006 || code == 1015) {
                    set_error("invalid WebSocket close code %.0f", code);
                    conn->failed = 1;
                    consume_pending(conn, offset + length);
                    array_set_string(out, "kind", "error", 5);
                    array_set_string(out, "class", "protocol", 8);
                    array_set_string(out, "error", last_error, strlen(last_error));
                    return make_number(CONVEX_ERROR, result);
                }
                array_set_string(out, "payload", conn->rbuf + offset + 2, length - 2);
            }
            array_set_string(out, "kind", "close", 5);
            array_set_number(out, "code", code);
            consume_pending(conn, offset + length);
            conn->frame_started_ms = conn->rlen > 0 ? monotonic_ms() : 0.0;
            return make_number(CONVEX_OK, result);
        }

        if (opcode == 1 || opcode == 2) {
            if (conn->frag_opcode != 0) {
                set_error("a new WebSocket data frame interrupted a fragmented message");
                conn->failed = 1;
                array_set_string(out, "kind", "error", 5);
                array_set_string(out, "class", "protocol", 8);
                array_set_string(out, "error", last_error, strlen(last_error));
                return make_number(CONVEX_ERROR, result);
            }
            if (fin) {
                array_set_string(out, "kind", opcode == 1 ? "text" : "binary",
                                 opcode == 1 ? 4 : 6);
                array_set_string(out, "payload", conn->rbuf + offset, length);
                consume_pending(conn, offset + length);
                conn->frame_started_ms = conn->rlen > 0 ? monotonic_ms() : 0.0;
                return make_number(CONVEX_OK, result);
            }
            conn->frag_opcode = opcode;
            conn->frag_len = 0;
        } else if (conn->frag_opcode == 0) {
            set_error("a WebSocket continuation frame has no start");
            conn->failed = 1;
            array_set_string(out, "kind", "error", 5);
            array_set_string(out, "class", "protocol", 8);
            array_set_string(out, "error", last_error, strlen(last_error));
            return make_number(CONVEX_ERROR, result);
        }

        if (conn->frag_len + length > (size_t) CONVEX_MAX_MESSAGE) {
            set_error("fragmented WebSocket message exceeds the %ld byte limit",
                      (long) CONVEX_MAX_MESSAGE);
            conn->failed = 1;
            array_set_string(out, "kind", "error", 5);
            array_set_string(out, "class", "protocol", 8);
            array_set_string(out, "error", last_error, strlen(last_error));
            return make_number(CONVEX_ERROR, result);
        }
        if (!buffer_reserve(&conn->frag, &conn->frag_cap, conn->frag_len + length + 1)) {
            set_error("cannot grow the WebSocket reassembly buffer");
            conn->failed = 1;
            array_set_string(out, "kind", "error", 5);
            array_set_string(out, "error", last_error, strlen(last_error));
            return make_number(CONVEX_ERROR, result);
        }
        memcpy(conn->frag + conn->frag_len, conn->rbuf + offset, length);
        conn->frag_len += length;
        consume_pending(conn, offset + length);

        if (fin) {
            int completed = conn->frag_opcode;

            array_set_string(out, "kind", completed == 1 ? "text" : "binary",
                             completed == 1 ? 4 : 6);
            array_set_string(out, "payload", conn->frag, conn->frag_len);
            conn->frag_opcode = 0;
            conn->frag_len = 0;
            conn->frame_started_ms = conn->rlen > 0 ? monotonic_ms() : 0.0;
            return make_number(CONVEX_OK, result);
        }
        /* Keep reading: more continuation frames are still to come. */
    }
}

/* Bytes still held by the incremental parser. The Live tests assert this is
 * non-zero across a timeout, which is the observable proof that parser state
 * survived. */
static awk_value_t *do_ws_pending(int nargs, awk_value_t *result,
                                  struct awk_ext_func *unused)
{
    double handle;
    convex_conn *conn;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_ws_pending")) {
        return make_number(-1, result);
    }
    conn = slot_for(handle);
    if (conn == NULL) {
        return make_number(-1, result);
    }
    return make_number((double) (conn->rlen + conn->frag_len), result);
}

/* Hand bytes back to the frame parser. The WebSocket handshake is read as
 * text, and a server is allowed to put the first frames in the same packet as
 * its 101 response; those bytes belong to the parser, not to the header read. */
static awk_value_t *do_ws_unread(int nargs, awk_value_t *result,
                                 struct awk_ext_func *unused)
{
    awk_value_t data;
    double handle;
    convex_conn *conn;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_ws_unread") ||
        !string_argument(1, &data, "convex_ws_unread")) {
        return make_number(CONVEX_ERROR, result);
    }
    conn = slot_for(handle);
    if (conn == NULL) {
        return make_number(CONVEX_ERROR, result);
    }
    if (data.str_value.len == 0) {
        return make_number(CONVEX_OK, result);
    }
    if (data.str_value.len > CONVEX_MAX_BUFFER - conn->rlen) {
        set_error("unread WebSocket bytes exceed the receive buffer limit");
        conn->failed = 1;
        return make_number(CONVEX_ERROR, result);
    }
    if (!buffer_reserve(&conn->rbuf, &conn->rcap, conn->rlen + data.str_value.len)) {
        set_error("cannot grow the receive buffer");
        conn->failed = 1;
        return make_number(CONVEX_ERROR, result);
    }
    memmove(conn->rbuf + data.str_value.len, conn->rbuf, conn->rlen);
    memcpy(conn->rbuf, data.str_value.str, data.str_value.len);
    conn->rlen += data.str_value.len;
    return make_number(CONVEX_OK, result);
}

/* Mark a handle as the server half of an RFC6455 connection. The Convex client
 * never calls this; the language-local fixtures do, so that the same framing
 * code both sends and receives in the tests. */
static awk_value_t *do_ws_server(int nargs, awk_value_t *result,
                                 struct awk_ext_func *unused)
{
    double handle;
    convex_conn *conn;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_ws_server")) {
        return make_number(0, result);
    }
    conn = slot_for(handle);
    if (conn == NULL) {
        return make_number(0, result);
    }
    conn->server_role = 1;
    return make_number(1, result);
}

static awk_value_t *do_random_base64(int nargs, awk_value_t *result,
                                     struct awk_ext_func *unused)
{
    unsigned char bytes[64];
    char encoded[128];
    double count;
    int encoded_length;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &count, "convex_random_base64")) {
        return make_const_string("", 0, result);
    }
    if (count < 1 || count > (double) sizeof(bytes)) {
        set_error("convex_random_base64: byte count must be 1..%lu",
                  (unsigned long) sizeof(bytes));
        return make_const_string("", 0, result);
    }
    if (RAND_bytes(bytes, (int) count) != 1) {
        set_ssl_error("cannot read random bytes");
        return make_const_string("", 0, result);
    }
    encoded_length = EVP_EncodeBlock((unsigned char *) encoded, bytes, (int) count);
    if (encoded_length <= 0) {
        set_error("base64 encoding failed");
        return make_const_string("", 0, result);
    }
    return make_const_string(encoded, (size_t) encoded_length, result);
}

static awk_value_t *do_sha1_base64(int nargs, awk_value_t *result,
                                   struct awk_ext_func *unused)
{
    awk_value_t data;
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int digest_length = 0;
    char encoded[64];
    int encoded_length;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!string_argument(0, &data, "convex_sha1_base64")) {
        return make_const_string("", 0, result);
    }
    if (EVP_Digest(data.str_value.str, data.str_value.len, digest, &digest_length,
                   EVP_sha1(), NULL) != 1) {
        set_ssl_error("SHA-1 failed");
        return make_const_string("", 0, result);
    }
    encoded_length = EVP_EncodeBlock((unsigned char *) encoded, digest, (int) digest_length);
    if (encoded_length <= 0) {
        set_error("base64 encoding failed");
        return make_const_string("", 0, result);
    }
    return make_const_string(encoded, (size_t) encoded_length, result);
}

static awk_value_t *do_random_hex(int nargs, awk_value_t *result,
                                  struct awk_ext_func *unused)
{
    static const char digits[] = "0123456789abcdef";
    unsigned char bytes[64];
    char text[129];
    double count;
    int index;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &count, "convex_random_hex")) {
        return make_const_string("", 0, result);
    }
    if (count < 1 || count > (double) sizeof(bytes)) {
        set_error("convex_random_hex: byte count must be 1..%lu",
                  (unsigned long) sizeof(bytes));
        return make_const_string("", 0, result);
    }
    if (RAND_bytes(bytes, (int) count) != 1) {
        set_ssl_error("cannot read random bytes");
        return make_const_string("", 0, result);
    }
    for (index = 0; index < (int) count; index++) {
        text[index * 2] = digits[bytes[index] >> 4];
        text[index * 2 + 1] = digits[bytes[index] & 0x0f];
    }
    return make_const_string(text, (size_t) count * 2, result);
}

static awk_value_t *do_utf8_valid(int nargs, awk_value_t *result,
                                  struct awk_ext_func *unused)
{
    awk_value_t data;
    const unsigned char *bytes;
    size_t index = 0;
    size_t length;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!string_argument(0, &data, "convex_utf8_valid")) {
        return make_number(0, result);
    }
    bytes = (const unsigned char *) data.str_value.str;
    length = data.str_value.len;

    while (index < length) {
        unsigned char lead = bytes[index];
        int extra;
        unsigned long code;
        int step;

        if (lead < 0x80) {
            index++;
            continue;
        }
        if (lead >= 0xc2 && lead <= 0xdf) {
            extra = 1;
            code = lead & 0x1f;
        } else if (lead >= 0xe0 && lead <= 0xef) {
            extra = 2;
            code = lead & 0x0f;
        } else if (lead >= 0xf0 && lead <= 0xf4) {
            extra = 3;
            code = lead & 0x07;
        } else {
            return make_number(0, result);
        }
        if (index + (size_t) extra >= length) {
            return make_number(0, result);
        }
        for (step = 1; step <= extra; step++) {
            unsigned char continuation = bytes[index + (size_t) step];

            if ((continuation & 0xc0) != 0x80) {
                return make_number(0, result);
            }
            code = (code << 6) | (continuation & 0x3f);
        }
        if (extra == 2 && code < 0x800) {
            return make_number(0, result);
        }
        if (extra == 3 && (code < 0x10000 || code > 0x10ffff)) {
            return make_number(0, result);
        }
        if (code >= 0xd800 && code <= 0xdfff) {
            return make_number(0, result);
        }
        index += (size_t) extra + 1;
    }
    return make_number(1, result);
}

/* Decode Convex's canonical little-endian uint64 sync timestamp. Awk doubles
 * lose the low bits of a nanosecond timestamp, so ordering has to be decided
 * here. Returns -2 when either operand is not canonical. */
static int decode_timestamp(const char *text, size_t length, unsigned char out[8])
{
    unsigned char decoded[16];
    int decoded_length;
    char padded[13];

    if (length != 12 || text[11] != '=') {
        return 0;
    }
    memcpy(padded, text, 12);
    padded[12] = '\0';
    decoded_length = EVP_DecodeBlock(decoded, (const unsigned char *) padded, 12);
    if (decoded_length != 9) {
        return 0;
    }
    /* EVP_DecodeBlock ignores padding, so re-encoding proves canonical form. */
    memcpy(out, decoded, 8);
    {
        char reencoded[32];
        int reencoded_length =
            EVP_EncodeBlock((unsigned char *) reencoded, out, 8);

        if (reencoded_length != 12 || memcmp(reencoded, text, 12) != 0) {
            return 0;
        }
    }
    return 1;
}

static awk_value_t *do_ts_cmp(int nargs, awk_value_t *result,
                              struct awk_ext_func *unused)
{
    awk_value_t left;
    awk_value_t right;
    unsigned char left_bytes[8];
    unsigned char right_bytes[8];
    int index;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!string_argument(0, &left, "convex_ts_cmp") ||
        !string_argument(1, &right, "convex_ts_cmp")) {
        return make_number(-2, result);
    }
    if (!decode_timestamp(left.str_value.str, left.str_value.len, left_bytes) ||
        !decode_timestamp(right.str_value.str, right.str_value.len, right_bytes)) {
        set_error("sync timestamp is not canonical base64 uint64");
        return make_number(-2, result);
    }
    for (index = 7; index >= 0; index--) {
        if (left_bytes[index] != right_bytes[index]) {
            return make_number(left_bytes[index] > right_bytes[index] ? 1 : -1, result);
        }
    }
    return make_number(0, result);
}

/* Prove, inside the final image, that the CA bundle and OpenSSL providers this
 * client will need actually load. It is not a handshake; the language-local
 * TLS test covers that in the build stage. */
static awk_value_t *do_tls_probe(int nargs, awk_value_t *result,
                                 struct awk_ext_func *unused)
{
    awk_array_t out;
    SSL_CTX *ctx;
    X509_STORE *store;
    STACK_OF(X509_OBJECT) *objects;
    const char *bundle = getenv("SSL_CERT_FILE");
    int count = 0;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!array_argument(0, &out, "convex_tls_probe")) {
        return make_number(0, result);
    }
    ctx = SSL_CTX_new(TLS_client_method());
    if (ctx == NULL) {
        set_ssl_error("cannot create a TLS context");
        array_set_string(out, "error", last_error, strlen(last_error));
        return make_number(0, result);
    }
    if (!load_trust_store(ctx)) {
        SSL_CTX_free(ctx);
        array_set_string(out, "error", last_error, strlen(last_error));
        return make_number(0, result);
    }
    store = SSL_CTX_get_cert_store(ctx);
    objects = X509_STORE_get0_objects(store);
    count = objects == NULL ? 0 : sk_X509_OBJECT_num(objects);
    array_set_number(out, "authorities", count);
    array_set_string(out, "bundle", bundle == NULL ? "" : bundle,
                     bundle == NULL ? 0 : strlen(bundle));
    array_set_string(out, "openssl", OpenSSL_version(OPENSSL_VERSION),
                     strlen(OpenSSL_version(OPENSSL_VERSION)));
    SSL_CTX_free(ctx);
    return make_number(count, result);
}

#ifdef CONVEX_TEST_HOOKS
/*
 * Test-only TLS server. The language-local TLS test needs a real peer to prove
 * that certificate verification, hostname matching, and handshake deadlines
 * behave. It is compiled out of the shipped runtime extension.
 */
static awk_value_t *do_test_tls_accept(int nargs, awk_value_t *result,
                                       struct awk_ext_func *unused)
{
    awk_value_t certificate;
    awk_value_t key;
    double handle;
    double timeout;
    convex_conn *listener;
    convex_conn *conn;
    char certificate_path[512];
    char key_path[512];
    double deadline;
    int index;
    int fd;

    (void) nargs;
    (void) unused;
    last_error[0] = '\0';
    if (!number_argument(0, &handle, "convex_test_tls_accept") ||
        !string_argument(1, &certificate, "convex_test_tls_accept") ||
        !string_argument(2, &key, "convex_test_tls_accept") ||
        !number_argument(3, &timeout, "convex_test_tls_accept")) {
        return make_number(-1, result);
    }
    if (certificate.str_value.len >= sizeof(certificate_path) ||
        key.str_value.len >= sizeof(key_path)) {
        set_error("convex_test_tls_accept: path is too long");
        return make_number(-1, result);
    }
    memcpy(certificate_path, certificate.str_value.str, certificate.str_value.len);
    certificate_path[certificate.str_value.len] = '\0';
    memcpy(key_path, key.str_value.str, key.str_value.len);
    key_path[key.str_value.len] = '\0';

    listener = slot_for(handle);
    if (listener == NULL || !listener->listening) {
        set_error("convex_test_tls_accept: handle is not a listening socket");
        return make_number(-1, result);
    }
    deadline = monotonic_ms() + timeout;
    if (wait_ready(listener->fd, POLLIN, deadline) != 1) {
        set_error("no TLS client arrived before the deadline");
        return make_number(-2, result);
    }
    fd = accept(listener->fd, NULL, NULL);
    if (fd < 0) {
        set_error("accept failed: %s", strerror(errno));
        return make_number(-1, result);
    }
    index = allocate_slot();
    if (index < 0) {
        close(fd);
        return make_number(-1, result);
    }
    conn = &connections[index];
    conn->fd = fd;
    if (!set_nonblocking(fd)) {
        set_error("cannot make the accepted socket non-blocking: %s", strerror(errno));
        release_slot(conn);
        return make_number(-1, result);
    }
    conn->ctx = SSL_CTX_new(TLS_server_method());
    if (conn->ctx == NULL ||
        SSL_CTX_use_certificate_chain_file(conn->ctx, certificate_path) != 1 ||
        SSL_CTX_use_PrivateKey_file(conn->ctx, key_path, SSL_FILETYPE_PEM) != 1) {
        set_ssl_error("cannot load the test server certificate");
        release_slot(conn);
        return make_number(-1, result);
    }
    conn->ssl = SSL_new(conn->ctx);
    if (conn->ssl == NULL || SSL_set_fd(conn->ssl, fd) != 1) {
        set_ssl_error("cannot create the test server session");
        release_slot(conn);
        return make_number(-1, result);
    }
    for (;;) {
        int status = SSL_accept(conn->ssl);
        int reason;

        if (status == 1) {
            return make_number(index, result);
        }
        reason = SSL_get_error(conn->ssl, status);
        if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) {
            short events = reason == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT;

            if (wait_ready(conn->fd, events, deadline) == 1) {
                continue;
            }
            set_error("the test TLS handshake timed out");
            release_slot(conn);
            return make_number(-2, result);
        }
        set_ssl_error("the test TLS handshake failed");
        release_slot(conn);
        return make_number(-1, result);
    }
}
#endif /* CONVEX_TEST_HOOKS */

static awk_ext_func_t func_table[] = {
    { "convex_now_ms", do_now_ms, 0, 0, awk_false, NULL },
    { "convex_byte", do_byte, 1, 1, awk_false, NULL },
    { "convex_sleep", do_sleep, 1, 1, awk_false, NULL },
    { "convex_last_error", do_last_error, 0, 0, awk_false, NULL },
    { "convex_version", do_version, 0, 0, awk_false, NULL },
    { "convex_connect", do_connect, 4, 4, awk_false, NULL },
    { "convex_attach", do_attach, 1, 1, awk_false, NULL },
    { "convex_listen", do_listen, 2, 2, awk_false, NULL },
    { "convex_port", do_port, 1, 1, awk_false, NULL },
    { "convex_accept", do_accept, 2, 2, awk_false, NULL },
    { "convex_send", do_send, 3, 3, awk_false, NULL },
    { "convex_recv", do_recv, 4, 4, awk_false, NULL },
    { "convex_close", do_close, 1, 1, awk_false, NULL },
    { "convex_ws_send", do_ws_send, 4, 4, awk_false, NULL },
    { "convex_ws_send_frame", do_ws_send_frame, 5, 5, awk_false, NULL },
    { "convex_ws_recv", do_ws_recv, 3, 3, awk_false, NULL },
    { "convex_ws_pending", do_ws_pending, 1, 1, awk_false, NULL },
    { "convex_ws_unread", do_ws_unread, 2, 2, awk_false, NULL },
    { "convex_ws_server", do_ws_server, 1, 1, awk_false, NULL },
    { "convex_sha1_base64", do_sha1_base64, 1, 1, awk_false, NULL },
    { "convex_random_hex", do_random_hex, 1, 1, awk_false, NULL },
    { "convex_random_base64", do_random_base64, 1, 1, awk_false, NULL },
    { "convex_utf8_valid", do_utf8_valid, 1, 1, awk_false, NULL },
    { "convex_ts_cmp", do_ts_cmp, 2, 2, awk_false, NULL },
    { "convex_tls_probe", do_tls_probe, 1, 1, awk_false, NULL },
#ifdef CONVEX_TEST_HOOKS
    { "convex_test_tls_accept", do_test_tls_accept, 4, 4, awk_false, NULL },
#endif
};

static awk_bool_t init_convexext(void)
{
    int index;

    for (index = 0; index < CONVEX_MAX_CONNECTIONS; index++) {
        connections[index].fd = -1;
    }
    last_error[0] = '\0';
    /* A peer that vanishes mid-write must surface as an ordinary write error
     * the Awk client can report, not as a signal that kills the adapter. */
    signal(SIGPIPE, SIG_IGN);
    if (OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS |
                         OPENSSL_INIT_LOAD_CRYPTO_STRINGS, NULL) != 1) {
        return awk_false;
    }
    return awk_true;
}

static awk_bool_t (*init_func)(void) = init_convexext;

dl_load_func(func_table, convexext, "")
