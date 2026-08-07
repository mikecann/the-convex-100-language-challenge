/*
 * native.c - the only native code in this client.
 *
 * Standard VHDL has no sockets, no TLS, no monotonic clock, no entropy
 * source, no environment access and no process exit status. This file
 * supplies exactly those primitives, as two VHPIDIRECT-callable C
 * functions, and nothing else: no HTTP, no WebSocket framing, no JSON
 * and no Convex knowledge. Every deadline, retry and byte of protocol
 * text lives in the VHDL packages under client/.
 *
 * The whole foreign boundary is deliberately two scalar functions:
 *
 *   int32_t cx_dispatch(int32_t cmd, int32_t a0, int32_t a1);
 *   double  cx_now_ms(void);
 *
 * GHDL's VHPIDIRECT convention maps every VHDL scalar type (integer,
 * real) to its obvious C counterpart directly, but marshaling a VHDL
 * array across the same boundary needs a fat-pointer/dope-vector
 * convention that is easy to get subtly wrong. This client avoids that
 * question entirely: no array, record or string ever crosses into C.
 * Every buffer - a hostname, an environment variable, a socket's bytes,
 * even stdin and stdout - crosses one byte at a time through cmd/a0/a1,
 * exactly like a real hardware peripheral exposes a byte-wide data
 * register behind a command register rather than a burst DMA channel.
 * client/convex_transport.vhdl is the only VHDL file that calls either
 * function; every other file reaches the outside world only through the
 * clocked request/acknowledge bus that entity drives.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netdb.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/rand.h>

/* ------------------------------------------------------------------ */
/* Opcodes. Kept in sync with the CMD_* constants in convex_native.vhdl. */
/* ------------------------------------------------------------------ */
enum {
    CMD_NOP = 0,
    CMD_HOST_RESET = 1,
    CMD_HOST_PUSH = 2,
    CMD_CONNECT = 3,
    CMD_CLOSE = 4,
    CMD_WRITE_BYTE = 5,
    CMD_WRITE_FLUSH = 6,
    CMD_READ_BYTE = 7,
    CMD_RANDOM_BYTE = 8,
    CMD_GETENV_RESET = 9,
    CMD_GETENV_PUSH = 10,
    CMD_GETENV_LOOKUP = 11,
    CMD_GETENV_BYTE = 12,
    CMD_WAIT_READY = 13,
    CMD_WAIT_READY_STDIN = 14,
    CMD_STDIN_READ_BYTE = 15,
    CMD_STDOUT_WRITE_BYTE = 16,
    CMD_STDOUT_FLUSH = 17,
    CMD_STDERR_WRITE_BYTE = 18,
    CMD_EXIT = 19
};

/* ------------------------------------------------------------------ */
/* Connection table. A handle is an index into this table, matching the */
/* handle-table pattern this project's other native-C-boundary clients */
/* use for the same reason: fixed, bounded, no dynamic allocation.     */
/* ------------------------------------------------------------------ */
#define MAX_CONN 8
#define RBUF_CAP 16384
#define WBUF_CAP 16384

typedef struct {
    int in_use;
    int fd;
    SSL *ssl; /* NULL when this connection is plain TCP */
    unsigned char rbuf[RBUF_CAP];
    int rbuf_pos;
    int rbuf_len;
    unsigned char wbuf[WBUF_CAP];
    int wbuf_len;
} conn_t;

static conn_t g_conn[MAX_CONN];
static SSL_CTX *g_ssl_ctx = NULL;

/* Accumulator for the hostname the next CONNECT will resolve and, when */
/* TLS is requested, also verify SNI/hostname against.                 */
#define HOST_CAP 256
static char g_host[HOST_CAP];
static int g_host_len = 0;

/* Accumulator for the environment variable name the next lookup reads, */
/* and the buffered value of the most recent successful lookup.        */
#define ENV_NAME_CAP 128
#define ENV_VALUE_CAP 4096
static char g_env_name[ENV_NAME_CAP];
static int g_env_name_len = 0;
static char g_env_value[ENV_VALUE_CAP];
static int g_env_value_len = 0;

/* Buffered stdout. Flushed explicitly by CMD_STDOUT_FLUSH and again by */
/* CMD_EXIT, so a client that reaches EXIT without an explicit flush    */
/* still prints everything it wrote - see AGENTS.md's buffered-stdout   */
/* defect class this guards against.                                   */
#define STDOUT_BUF_CAP 8192
static unsigned char g_stdout_buf[STDOUT_BUF_CAP];
static int g_stdout_len = 0;

static void stdout_flush(void) {
    int off = 0;
    while (off < g_stdout_len) {
        ssize_t n = write(1, g_stdout_buf + off, (size_t)(g_stdout_len - off));
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            break;
        }
        off += (int)n;
    }
    g_stdout_len = 0;
}

/* ------------------------------------------------------------------ */
/* Connect: resolve the accumulated hostname, connect a TCP socket, and */
/* optionally perform a certificate- and hostname-verified TLS         */
/* handshake using the SAME accumulated hostname for SNI and           */
/* SSL_set1_host. Returns a handle >= 0, or a negative error code.     */
/* ------------------------------------------------------------------ */
static int handle_connect(int port, int use_tls) {
    int slot = -1;
    for (int i = 0; i < MAX_CONN; i++) {
        if (!g_conn[i].in_use) { slot = i; break; }
    }
    if (slot < 0) return -4; /* table full */
    if (g_host_len <= 0 || g_host_len >= HOST_CAP) return -5;
    g_host[g_host_len] = '\0';

    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(g_host, portstr, &hints, &res) != 0 || res == NULL) {
        return -1; /* DNS failure */
    }

    int fd = -1;
    struct addrinfo *rp;
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) return -2; /* connect failure */

    conn_t *c = &g_conn[slot];
    memset(c, 0, sizeof(*c));
    c->in_use = 1;
    c->fd = fd;

    if (use_tls) {
        if (!g_ssl_ctx) {
            g_ssl_ctx = SSL_CTX_new(TLS_client_method());
            if (!g_ssl_ctx) { close(fd); c->in_use = 0; return -3; }
            SSL_CTX_set_default_verify_paths(g_ssl_ctx);
            SSL_CTX_set_verify(g_ssl_ctx, SSL_VERIFY_PEER, NULL);
        }
        SSL *ssl = SSL_new(g_ssl_ctx);
        if (!ssl) { close(fd); c->in_use = 0; return -3; }
        SSL_set_fd(ssl, fd);
        /* Hostname verification (RFC 6125) and SNI both use the exact
           text the client asked to connect to; switched on together
           here rather than left to a separate step a caller could
           forget, per this project's stated TLS-mistake pattern. */
        SSL_set1_host(ssl, g_host);
        SSL_set_tlsext_host_name(ssl, g_host);
        if (SSL_connect(ssl) != 1 || SSL_get_verify_result(ssl) != X509_V_OK) {
            SSL_free(ssl);
            close(fd);
            c->in_use = 0;
            return -3; /* TLS failure */
        }
        c->ssl = ssl;
    }
    return slot;
}

static void handle_close(int h) {
    if (h < 0 || h >= MAX_CONN || !g_conn[h].in_use) return;
    conn_t *c = &g_conn[h];
    if (c->ssl) {
        SSL_shutdown(c->ssl);
        SSL_free(c->ssl);
    }
    close(c->fd);
    memset(c, 0, sizeof(*c));
}

/* Writes are staged in a per-connection buffer so a request built one
   byte at a time in VHDL does not become one syscall per byte; the
   buffer is only actually sent on WRITE_FLUSH. */
static int handle_write_byte(int h, int b) {
    if (h < 0 || h >= MAX_CONN || !g_conn[h].in_use) return -1;
    conn_t *c = &g_conn[h];
    if (c->wbuf_len >= WBUF_CAP) return -2; /* caller must flush sooner */
    c->wbuf[c->wbuf_len++] = (unsigned char)(b & 0xff);
    return 1;
}

static int handle_write_flush(int h) {
    if (h < 0 || h >= MAX_CONN || !g_conn[h].in_use) return -1;
    conn_t *c = &g_conn[h];
    int off = 0;
    while (off < c->wbuf_len) {
        int n;
        if (c->ssl) {
            n = SSL_write(c->ssl, c->wbuf + off, c->wbuf_len - off);
            if (n <= 0) {
                int err = SSL_get_error(c->ssl, n);
                if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) continue;
                return -3;
            }
        } else {
            n = (int)write(c->fd, c->wbuf + off, (size_t)(c->wbuf_len - off));
            if (n < 0) {
                if (errno == EINTR) continue;
                return -3;
            }
            if (n == 0) return -3;
        }
        off += n;
    }
    int sent = c->wbuf_len;
    c->wbuf_len = 0;
    return sent;
}

/* Waits up to timeout_ms, using poll(2) on the raw fd, for the given
   handle to become readable or reach end-of-file/error. Set on the
   socket itself so the deadline covers the layer bytes actually travel
   through - not a field a higher wrapper merely consults. */
static int poll_readable(int fd, int timeout_ms) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int rc = poll(&pfd, 1, timeout_ms);
    if (rc < 0) return -1;
    if (rc == 0) return 0;
    return (pfd.revents & (POLLIN | POLLHUP | POLLERR)) ? 1 : 0;
}

/* Reads the next byte from the connection's buffer, refilling it with a
   real recv()/SSL_read() only when empty, bounded by timeout_ms. */
static int handle_read_byte(int h, int timeout_ms) {
    if (h < 0 || h >= MAX_CONN || !g_conn[h].in_use) return -3;
    conn_t *c = &g_conn[h];
    if (c->rbuf_pos < c->rbuf_len) {
        return c->rbuf[c->rbuf_pos++];
    }
    c->rbuf_pos = 0;
    c->rbuf_len = 0;

    if (c->ssl) {
        /* A buffered TLS record may already hold decrypted bytes even
           when the raw fd has nothing new to offer, so check that
           first before waiting on the fd at all. */
        if (SSL_pending(c->ssl) <= 0) {
            int ready = poll_readable(c->fd, timeout_ms);
            if (ready < 0) return -3;
            if (ready == 0) return -1; /* timeout */
        }
        int n = SSL_read(c->ssl, c->rbuf, RBUF_CAP);
        if (n < 0) {
            int err = SSL_get_error(c->ssl, n);
            if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) return -1;
            return -3;
        }
        if (n == 0) return -2; /* clean close */
        c->rbuf_len = n;
        return c->rbuf[c->rbuf_pos++];
    } else {
        int ready = poll_readable(c->fd, timeout_ms);
        if (ready < 0) return -3;
        if (ready == 0) return -1;
        ssize_t n = read(c->fd, c->rbuf, RBUF_CAP);
        if (n < 0) return -3;
        if (n == 0) return -2;
        c->rbuf_len = (int)n;
        return c->rbuf[c->rbuf_pos++];
    }
}

static int wait_ready(int h, int timeout_ms, int include_stdin) {
    struct pollfd pfds[2];
    int nfds = 0;
    int hidx = -1, sidx = -1;
    if (h >= 0 && h < MAX_CONN && g_conn[h].in_use) {
        /* A TLS connection may already have a decoded record sitting in
           OpenSSL's buffer with nothing new on the raw fd; report ready
           immediately rather than polling a socket that will not wake
           up until more ciphertext arrives. */
        if (g_conn[h].ssl && SSL_pending(g_conn[h].ssl) > 0) {
            return include_stdin ? 1 : 1;
        }
        pfds[nfds].fd = g_conn[h].fd;
        pfds[nfds].events = POLLIN;
        pfds[nfds].revents = 0;
        hidx = nfds;
        nfds++;
    }
    if (include_stdin) {
        pfds[nfds].fd = 0;
        pfds[nfds].events = POLLIN;
        pfds[nfds].revents = 0;
        sidx = nfds;
        nfds++;
    }
    if (nfds == 0) return 0;
    int rc = poll(pfds, nfds, timeout_ms);
    if (rc < 0) return -1;
    int mask = 0;
    if (hidx >= 0 && (pfds[hidx].revents & (POLLIN | POLLHUP | POLLERR))) mask |= 1;
    if (sidx >= 0 && (pfds[sidx].revents & (POLLIN | POLLHUP | POLLERR))) mask |= 2;
    return mask;
}

/* Unbuffered stdin reader; buffered internally per call is unnecessary
   because the adapter reads a full NDJSON line at a time and the OS
   pipe buffer already absorbs bursts. */
static int stdin_read_byte(int timeout_ms) {
    int ready = poll_readable(0, timeout_ms);
    if (ready < 0) return -3;
    if (ready == 0) return -1;
    unsigned char b;
    ssize_t n = read(0, &b, 1);
    if (n < 0) return -3;
    if (n == 0) return -2;
    return b;
}

/* ------------------------------------------------------------------ */
/* The single dispatcher. VHDL never calls anything else.              */
/* ------------------------------------------------------------------ */
int32_t cx_dispatch(int32_t cmd, int32_t a0, int32_t a1) {
    switch (cmd) {
        case CMD_NOP:
            return 0;

        case CMD_HOST_RESET:
            g_host_len = 0;
            return 0;
        case CMD_HOST_PUSH:
            if (g_host_len < HOST_CAP - 1) g_host[g_host_len++] = (char)a0;
            return 0;
        case CMD_CONNECT:
            return handle_connect(a0, a1);
        case CMD_CLOSE:
            handle_close(a0);
            return 0;
        case CMD_WRITE_BYTE:
            return handle_write_byte(a0, a1);
        case CMD_WRITE_FLUSH:
            return handle_write_flush(a0);
        case CMD_READ_BYTE:
            return handle_read_byte(a0, a1);

        case CMD_RANDOM_BYTE: {
            unsigned char b;
            if (RAND_bytes(&b, 1) != 1) return -1;
            return b;
        }

        case CMD_GETENV_RESET:
            g_env_name_len = 0;
            return 0;
        case CMD_GETENV_PUSH:
            if (g_env_name_len < ENV_NAME_CAP - 1) g_env_name[g_env_name_len++] = (char)a0;
            return 0;
        case CMD_GETENV_LOOKUP: {
            g_env_name[g_env_name_len] = '\0';
            const char *v = getenv(g_env_name);
            if (!v) { g_env_value_len = 0; return -1; }
            size_t vlen = strlen(v);
            if (vlen > ENV_VALUE_CAP) vlen = ENV_VALUE_CAP;
            memcpy(g_env_value, v, vlen);
            g_env_value_len = (int)vlen;
            return g_env_value_len;
        }
        case CMD_GETENV_BYTE:
            if (a0 < 0 || a0 >= g_env_value_len) return -1;
            return (unsigned char)g_env_value[a0];

        case CMD_WAIT_READY:
            return wait_ready(a0, a1, 0);
        case CMD_WAIT_READY_STDIN:
            return wait_ready(a0, a1, 1);
        case CMD_STDIN_READ_BYTE:
            return stdin_read_byte(a0);

        case CMD_STDOUT_WRITE_BYTE:
            if (g_stdout_len >= STDOUT_BUF_CAP) stdout_flush();
            g_stdout_buf[g_stdout_len++] = (unsigned char)(a0 & 0xff);
            return 1;
        case CMD_STDOUT_FLUSH:
            stdout_flush();
            return 0;
        case CMD_STDERR_WRITE_BYTE: {
            unsigned char b = (unsigned char)(a0 & 0xff);
            ssize_t rc = write(2, &b, 1);
            (void)rc;
            return 1;
        }

        case CMD_EXIT:
            stdout_flush();
            exit(a0);
            return 0; /* unreachable */

        default:
            return -100; /* unknown opcode */
    }
}

double cx_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}
