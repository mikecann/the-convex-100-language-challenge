/*
 * native.c - the only native code in this client.
 *
 * Standard Verilog has no sockets, no TLS, no monotonic clock, no entropy
 * source and no environment access. This file supplies exactly those
 * primitives, as an Icarus Verilog VPI module, and nothing else: no HTTP,
 * no WebSocket framing, no JSON and no Convex knowledge. Every deadline,
 * retry and byte of protocol text lives in the Verilog source under
 * client/.
 *
 * The whole foreign boundary is deliberately two system functions:
 *
 *   function integer $cx_dispatch(integer cmd, integer a0, integer a1);
 *   function real    $cx_now_ms();
 *
 * This is the same "no array, record or string ever crosses the boundary"
 * discipline the vhdl/ client's VHPIDIRECT boundary (client/native.c on
 * branch codex/vhdl-client) uses for the same reason: marshaling anything
 * richer than a scalar across a foreign-function boundary is easy to get
 * subtly wrong, so every buffer here - a hostname, a socket's bytes, even
 * stdout - crosses one byte at a time through cmd/a0/a1, exactly like a
 * real hardware peripheral exposes a byte-wide data register behind a
 * command register rather than a burst DMA channel.
 *
 * client/convex_transport.v is the only Verilog file that calls either
 * system function; every other file reaches the outside world only
 * through the clocked request/acknowledge bus that module drives. That
 * module toggles a req register, this VPI module notices it on the next
 * $cx_dispatch call from the transport process's clocked always block,
 * performs exactly one blocking C call, and returns the result - the
 * blocking happens inside this C call, not inside simulated time, exactly
 * where AGENTS.md says a read deadline belongs: on the layer the bytes
 * actually travel through, not a field a wrapper merely consults.
 *
 * VPI vs. VHPIDIRECT: GHDL's VHPIDIRECT binds a VHDL function declaration
 * directly to a C symbol of a matching calling convention. Icarus has no
 * such direct-bind mechanism for compiled simulation; instead a VPI
 * module registers Verilog system functions ($cx_dispatch, $cx_now_ms)
 * with vpi_register_systf, and Icarus calls this module's calltf callback
 * whenever simulated Verilog code evaluates that system function. The
 * effect at the Verilog call site is the same as VHDL's foreign function
 * call - a normal-looking function call that secretly reaches out past
 * the simulator - but the wiring underneath differs: VPI is a callback
 * table Icarus consults, not a linked symbol reference.
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

#include <vpi_user.h>

/* ------------------------------------------------------------------ */
/* Opcodes. Kept in sync with the CMD_* constants in convex_transport.v */
/* and any file that issues a transport.xport_call request.            */
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
    CMD_STDOUT_WRITE_BYTE = 16,
    CMD_STDOUT_FLUSH = 17,
    CMD_STDERR_WRITE_BYTE = 18
    /* GETENV_*, WAIT_READY*, STDIN_READ_BYTE, EXIT, LISTEN and ACCEPT are
       not implemented yet - this gate stage only has to prove a real TCP
       connection and a real TLS handshake through this boundary. They
       will be added, matching vhdl/client/native.c's set, when the
       sync layer above needs them. CMD_RANDOM_BYTE was added now,
       ahead of that set, because the RFC 6455 WebSocket layer needs a
       source of entropy for the Sec-WebSocket-Key nonce and each
       frame's client-to-server masking key (RFC 6455 SS5.3) - the same
       "no array ever crosses the boundary" byte-at-a-time shape as
       every other opcode here: one call returns one random byte. */
};

/* ------------------------------------------------------------------ */
/* Connection table. A handle is an index into this table: fixed,      */
/* bounded, no dynamic allocation - matching this project's other      */
/* native-C-boundary clients (see vhdl/client/native.c) for the same   */
/* reason.                                                              */
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
           text the client asked to connect to, switched on together
           here rather than left to a separate step a caller could
           forget - the same discipline vhdl/client/native.c uses. */
        SSL_set1_host(ssl, g_host);
        SSL_set_tlsext_host_name(ssl, g_host);
        if (SSL_connect(ssl) != 1 || SSL_get_verify_result(ssl) != X509_V_OK) {
            unsigned long e = ERR_get_error();
            char ebuf[256];
            ERR_error_string_n(e, ebuf, sizeof(ebuf));
            fprintf(stderr, "native.c: TLS handshake failed: %s\n", ebuf);
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
   byte at a time in Verilog does not become one syscall per byte; the
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

/* Returns one cryptographically strong random byte (0-255) using
   OpenSSL's RAND_bytes, the same TLS-grade entropy source already
   linked in for handle_connect's SSL_CTX above - not rand()/time(),
   which would make masking keys and the Sec-WebSocket-Key nonce
   predictable. RAND_bytes' own failure (exhausted entropy, extremely
   rare on a real OS) is reported as -1 so a caller building a key or
   mask can fail loudly instead of silently using an unseeded byte. */
static int handle_random_byte(void) {
    unsigned char b;
    if (RAND_bytes(&b, 1) != 1) return -1;
    return (int)b;
}

/* ------------------------------------------------------------------ */
/* The single dispatcher. Verilog never reaches the outside world any   */
/* other way.                                                           */
/* ------------------------------------------------------------------ */
static int32_t cx_dispatch(int32_t cmd, int32_t a0, int32_t a1) {
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
        case CMD_RANDOM_BYTE:
            return handle_random_byte();

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

        default:
            return -100; /* unknown opcode */
    }
}

static double cx_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}

/* ------------------------------------------------------------------ */
/* VPI wiring: register $cx_dispatch and $cx_now_ms as Verilog system   */
/* functions. This section is the only VPI-specific code in the file;  */
/* everything above is ordinary C that never mentions vpi_user.h.      */
/* ------------------------------------------------------------------ */
static PLI_INT32 cx_dispatch_calltf(PLI_BYTE8 *user_data) {
    (void)user_data;
    vpiHandle systf_handle = vpi_handle(vpiSysTfCall, NULL);
    vpiHandle arg_iter = vpi_iterate(vpiArgument, systf_handle);
    s_vpi_value value;
    value.format = vpiIntVal;

    vpiHandle a_cmd = vpi_scan(arg_iter);
    vpi_get_value(a_cmd, &value);
    int32_t cmd = value.value.integer;

    vpiHandle a_a0 = vpi_scan(arg_iter);
    vpi_get_value(a_a0, &value);
    int32_t a0 = value.value.integer;

    vpiHandle a_a1 = vpi_scan(arg_iter);
    vpi_get_value(a_a1, &value);
    int32_t a1 = value.value.integer;
    /* Three arguments scanned from a three-argument system function:
       vpi_scan returns NULL and frees arg_iter itself once exhausted. */

    int32_t result = cx_dispatch(cmd, a0, a1);

    s_vpi_value ret_value;
    ret_value.format = vpiIntVal;
    ret_value.value.integer = result;
    vpi_put_value(systf_handle, &ret_value, NULL, vpiNoDelay);
    return 0;
}

static PLI_INT32 cx_dispatch_compiletf(PLI_BYTE8 *user_data) {
    (void)user_data;
    vpiHandle systf_handle = vpi_handle(vpiSysTfCall, NULL);
    vpiHandle arg_iter = vpi_iterate(vpiArgument, systf_handle);
    int argc = 0;
    if (arg_iter != NULL) {
        while (vpi_scan(arg_iter) != NULL) argc++;
    }
    if (argc != 3) {
        vpi_printf("ERROR: $cx_dispatch requires exactly 3 arguments (cmd, a0, a1), got %d\n", argc);
        vpi_control(vpiFinish, 1);
    }
    return 0;
}

static PLI_INT32 cx_now_ms_calltf(PLI_BYTE8 *user_data) {
    (void)user_data;
    vpiHandle systf_handle = vpi_handle(vpiSysTfCall, NULL);
    s_vpi_value ret_value;
    ret_value.format = vpiRealVal;
    ret_value.value.real = cx_now_ms();
    vpi_put_value(systf_handle, &ret_value, NULL, vpiNoDelay);
    return 0;
}

static void register_systfs(void) {
    s_vpi_systf_data tf_data;

    tf_data.type = vpiSysFunc;
    tf_data.sysfunctype = vpiSysFuncInt;
    tf_data.tfname = "$cx_dispatch";
    tf_data.calltf = cx_dispatch_calltf;
    tf_data.compiletf = cx_dispatch_compiletf;
    tf_data.sizetf = 0;
    tf_data.user_data = 0;
    vpi_register_systf(&tf_data);

    tf_data.type = vpiSysFunc;
    tf_data.sysfunctype = vpiSysFuncReal;
    tf_data.tfname = "$cx_now_ms";
    tf_data.calltf = cx_now_ms_calltf;
    tf_data.compiletf = 0;
    tf_data.sizetf = 0;
    tf_data.user_data = 0;
    vpi_register_systf(&tf_data);
}

void (*vlog_startup_routines[])(void) = {
    register_systfs,
    0
};
