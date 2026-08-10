/*
 * Reviewed native extension for the educational COBOL Convex client.
 *
 * See convex-native.h for the scope rule. Nothing in this file understands
 * HTTP, WebSocket, JSON, or Convex. It moves bytes, measures time, and
 * produces randomness and one digest. Everything else is COBOL.
 */

#define _POSIX_C_SOURCE 200809L

#include "convex-native.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/types.h>

#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#define CVX_ERRTEXT 192

struct cvx_handle {
    int in_use;
    int fd;
    SSL *ssl;
    SSL_CTX *ctx;
    char error[CVX_ERRTEXT];
};

static struct cvx_handle g_handles[CVX_MAX_HANDLES];

/*
 * A Live peer is allowed to disappear at any point, including after the
 * controller has decided to send the next query-set update.  Linux otherwise
 * delivers SIGPIPE before write(2) can return EPIPE, which terminates the
 * COBOL process and prevents the Live owner from retiring and reconnecting
 * the socket.  TLS writes go through OpenSSL's BIO and cannot use
 * MSG_NOSIGNAL, so ignore the signal once and let both TLS and plain writes
 * report their normal, inspectable error status instead.
 */
static void ignore_sigpipe(void)
{
    static int configured;
    struct sigaction action;

    if (configured) {
        return;
    }
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_IGN;
    sigemptyset(&action.sa_mask);
    (void)sigaction(SIGPIPE, &action, NULL);
    configured = 1;
}

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static struct cvx_handle *slot_of(int handle)
{
    if (handle < 0 || handle >= CVX_MAX_HANDLES) {
        return NULL;
    }
    if (!g_handles[handle].in_use) {
        return NULL;
    }
    return &g_handles[handle];
}

static void set_error(struct cvx_handle *h, const char *text)
{
    if (h == NULL || text == NULL) {
        return;
    }
    strncpy(h->error, text, CVX_ERRTEXT - 1);
    h->error[CVX_ERRTEXT - 1] = '\0';
}

static void set_errno_error(struct cvx_handle *h)
{
    set_error(h, strerror(errno));
}

static void set_tls_error(struct cvx_handle *h, const char *prefix)
{
    unsigned long code = ERR_get_error();
    char detail[128];

    if (code == 0) {
        set_error(h, prefix);
        return;
    }
    ERR_error_string_n(code, detail, sizeof(detail));
    snprintf(h->error, CVX_ERRTEXT, "%s: %s", prefix, detail);
}

static int claim_slot(void)
{
    int i;

    for (i = 0; i < CVX_MAX_HANDLES; i++) {
        if (!g_handles[i].in_use) {
            memset(&g_handles[i], 0, sizeof(g_handles[i]));
            g_handles[i].in_use = 1;
            g_handles[i].fd = -1;
            return i;
        }
    }
    return CVX_LIMIT;
}

static void release_slot(struct cvx_handle *h)
{
    if (h->ssl != NULL) {
        SSL_free(h->ssl);
        h->ssl = NULL;
    }
    if (h->ctx != NULL) {
        SSL_CTX_free(h->ctx);
        h->ctx = NULL;
    }
    if (h->fd >= 0) {
        close(h->fd);
        h->fd = -1;
    }
    h->in_use = 0;
}

static int set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);

    if (flags < 0) {
        return CVX_ERR;
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        return CVX_ERR;
    }
    return CVX_OK;
}

/* Copy a COBOL PIC X field, which is space padded and never NUL
 * terminated, into a C string. */
static int copy_field(const char *in, int len, char *out, int cap)
{
    int n = len;

    if (in == NULL || out == NULL || cap <= 0) {
        return CVX_ERR;
    }
    while (n > 0 && (in[n - 1] == ' ' || in[n - 1] == '\0')) {
        n--;
    }
    if (n < 0 || n >= cap) {
        return CVX_LIMIT;
    }
    memcpy(out, in, (size_t)n);
    out[n] = '\0';
    return n;
}

int cvx_now_ms(long long *out_ms)
{
    struct timespec ts;

    if (out_ms == NULL) {
        return CVX_ERR;
    }
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return CVX_ERR;
    }
    *out_ms = (long long)ts.tv_sec * 1000LL
            + (long long)(ts.tv_nsec / 1000000L);
    return CVX_OK;
}

/* Milliseconds remaining until an absolute deadline, clamped for poll(). */
static int remaining_ms(long long deadline_ms)
{
    long long now = 0;
    long long left;

    if (cvx_now_ms(&now) != CVX_OK) {
        return -1;
    }
    left = deadline_ms - now;
    if (left <= 0) {
        return 0;
    }
    if (left > 60000LL) {
        return 60000;
    }
    return (int)left;
}

/* Wait for readability or writability, honouring the absolute deadline.
 * Returns 1 ready, CVX_TIMEOUT at the deadline, CVX_ERR on a poll fault. */
static int wait_fd(int fd, int for_write, long long deadline_ms)
{
    struct pollfd pfd;
    int rc;
    int wait;

    for (;;) {
        wait = remaining_ms(deadline_ms);
        if (wait <= 0) {
            return CVX_TIMEOUT;
        }
        pfd.fd = fd;
        pfd.events = (short)(for_write ? POLLOUT : POLLIN);
        pfd.revents = 0;
        rc = poll(&pfd, 1, wait);
        if (rc > 0) {
            return 1;
        }
        if (rc == 0) {
            return CVX_TIMEOUT;
        }
        if (errno != EINTR) {
            return CVX_ERR;
        }
    }
}

int cvx_random_bytes(unsigned char *out, int len)
{
    if (out == NULL || len <= 0) {
        return CVX_ERR;
    }
    if (RAND_bytes(out, len) != 1) {
        return CVX_ERR;
    }
    return CVX_OK;
}

int cvx_sha1(const unsigned char *in, int len, unsigned char *out20)
{
    if (in == NULL || out20 == NULL || len < 0) {
        return CVX_ERR;
    }
    if (SHA1(in, (size_t)len, out20) == NULL) {
        return CVX_ERR;
    }
    return CVX_OK;
}

/* ------------------------------------------------------------------ */
/* Connection setup                                                    */
/* ------------------------------------------------------------------ */

static int connect_socket(const char *host, int port, long long deadline_ms,
                          char *errbuf, int errcap)
{
    struct addrinfo hints;
    struct addrinfo *list = NULL;
    struct addrinfo *entry;
    char service[16];
    int fd = -1;
    int rc;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    snprintf(service, sizeof(service), "%d", port);

    rc = getaddrinfo(host, service, &hints, &list);
    if (rc != 0 || list == NULL) {
        snprintf(errbuf, (size_t)errcap, "resolve failed: %s",
                 gai_strerror(rc));
        return CVX_ERR;
    }

    for (entry = list; entry != NULL; entry = entry->ai_next) {
        int one = 1;
        int ready;

        fd = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
        if (fd < 0) {
            continue;
        }
        if (set_nonblocking(fd) != CVX_OK) {
            close(fd);
            fd = -1;
            continue;
        }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

        rc = connect(fd, entry->ai_addr, entry->ai_addrlen);
        if (rc == 0) {
            break;
        }
        if (errno != EINPROGRESS) {
            snprintf(errbuf, (size_t)errcap, "connect failed: %s",
                     strerror(errno));
            close(fd);
            fd = -1;
            continue;
        }

        ready = wait_fd(fd, 1, deadline_ms);
        if (ready == 1) {
            int soerr = 0;
            socklen_t soerrlen = sizeof(soerr);

            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &soerrlen) == 0 &&
                soerr == 0) {
                break;
            }
            snprintf(errbuf, (size_t)errcap, "connect failed: %s",
                     strerror(soerr != 0 ? soerr : ECONNREFUSED));
        } else if (ready == CVX_TIMEOUT) {
            snprintf(errbuf, (size_t)errcap, "connect timed out");
            close(fd);
            fd = -1;
            break;
        } else {
            snprintf(errbuf, (size_t)errcap, "connect poll failed");
        }
        close(fd);
        fd = -1;
    }

    freeaddrinfo(list);
    if (fd < 0) {
        return CVX_ERR;
    }
    return fd;
}

/* Drive an OpenSSL handshake that may need more socket readiness. */
static int finish_handshake(struct cvx_handle *h, long long deadline_ms)
{
    for (;;) {
        int rc = SSL_connect(h->ssl);
        int reason;
        int ready;

        if (rc == 1) {
            return CVX_OK;
        }
        reason = SSL_get_error(h->ssl, rc);
        if (reason == SSL_ERROR_WANT_READ) {
            ready = wait_fd(h->fd, 0, deadline_ms);
        } else if (reason == SSL_ERROR_WANT_WRITE) {
            ready = wait_fd(h->fd, 1, deadline_ms);
        } else {
            long verify = SSL_get_verify_result(h->ssl);

            if (verify != X509_V_OK) {
                snprintf(h->error, CVX_ERRTEXT,
                         "TLS certificate rejected: %s",
                         X509_verify_cert_error_string(verify));
            } else {
                set_tls_error(h, "TLS handshake failed");
            }
            return CVX_TLS;
        }
        if (ready != 1) {
            set_error(h, "TLS handshake timed out");
            return CVX_TIMEOUT;
        }
    }
}

int cvx_net_open(const char *host, int host_len, int port, int secure,
                 long long deadline_ms)
{
    char hostname[256];
    char errbuf[CVX_ERRTEXT];
    struct cvx_handle *h;
    int slot;
    int fd;
    int rc;

    if (port < 1 || port > 65535) {
        return CVX_ERR;
    }
    if (copy_field(host, host_len, hostname, sizeof(hostname)) <= 0) {
        return CVX_ERR;
    }

    slot = claim_slot();
    if (slot < 0) {
        return slot;
    }
    h = &g_handles[slot];

    errbuf[0] = '\0';
    fd = connect_socket(hostname, port, deadline_ms, errbuf, sizeof(errbuf));
    if (fd < 0) {
        set_error(h, errbuf[0] != '\0' ? errbuf : "connect failed");
        /* Keep the slot so the caller can read the error, but mark it
         * closed by giving it no descriptor. */
        h->fd = -1;
        release_slot(h);
        return fd;
    }
    h->fd = fd;

    if (!secure) {
        return slot;
    }

    h->ctx = SSL_CTX_new(TLS_client_method());
    if (h->ctx == NULL) {
        set_tls_error(h, "TLS context allocation failed");
        release_slot(h);
        return CVX_TLS;
    }
    SSL_CTX_set_min_proto_version(h->ctx, TLS1_2_VERSION);
    SSL_CTX_set_verify(h->ctx, SSL_VERIFY_PEER, NULL);
    if (SSL_CTX_set_default_verify_paths(h->ctx) != 1) {
        set_tls_error(h, "TLS trust store unavailable");
        release_slot(h);
        return CVX_TLS;
    }

    h->ssl = SSL_new(h->ctx);
    if (h->ssl == NULL) {
        set_tls_error(h, "TLS session allocation failed");
        release_slot(h);
        return CVX_TLS;
    }
    if (SSL_set_fd(h->ssl, h->fd) != 1) {
        set_tls_error(h, "TLS descriptor bind failed");
        release_slot(h);
        return CVX_TLS;
    }

    /* SNI and certificate identity are the same string by construction. */
    SSL_set_tlsext_host_name(h->ssl, hostname);
    SSL_set_hostflags(h->ssl, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    if (SSL_set1_host(h->ssl, hostname) != 1) {
        set_tls_error(h, "TLS hostname check setup failed");
        release_slot(h);
        return CVX_TLS;
    }

    rc = finish_handshake(h, deadline_ms);
    if (rc != CVX_OK) {
        char keep[CVX_ERRTEXT];

        memcpy(keep, h->error, CVX_ERRTEXT);
        release_slot(h);
        /* Preserve the diagnosis for the COBOL caller's log line. */
        memcpy(g_handles[slot].error, keep, CVX_ERRTEXT);
        return rc;
    }
    return slot;
}

int cvx_net_register_fd(int fd)
{
    int slot;

    if (fd < 0) {
        return CVX_ERR;
    }
    slot = claim_slot();
    if (slot < 0) {
        return slot;
    }
    if (set_nonblocking(fd) != CVX_OK) {
        set_errno_error(&g_handles[slot]);
        g_handles[slot].in_use = 0;
        return CVX_ERR;
    }
    g_handles[slot].fd = fd;
    return slot;
}

/* ------------------------------------------------------------------ */
/* Stream I/O                                                          */
/* ------------------------------------------------------------------ */

int cvx_net_read(int handle, unsigned char *out, int cap,
                 long long deadline_ms, int *got)
{
    struct cvx_handle *h = slot_of(handle);
    int n;

    if (got != NULL) {
        *got = 0;
    }
    if (h == NULL || out == NULL || cap <= 0 || got == NULL) {
        return CVX_HANDLE;
    }

    for (;;) {
        int ready;

        if (h->ssl != NULL) {
            int reason;

            ERR_clear_error();
            n = SSL_read(h->ssl, out, cap);
            if (n > 0) {
                *got = n;
                return CVX_OK;
            }
            reason = SSL_get_error(h->ssl, n);
            if (reason == SSL_ERROR_ZERO_RETURN) {
                return CVX_EOF;
            }
            if (reason == SSL_ERROR_WANT_READ) {
                ready = wait_fd(h->fd, 0, deadline_ms);
            } else if (reason == SSL_ERROR_WANT_WRITE) {
                ready = wait_fd(h->fd, 1, deadline_ms);
            } else if (reason == SSL_ERROR_SYSCALL && n == 0) {
                return CVX_EOF;
            } else {
                set_tls_error(h, "TLS read failed");
                return CVX_TLS;
            }
        } else {
            n = (int)read(h->fd, out, (size_t)cap);
            if (n > 0) {
                *got = n;
                return CVX_OK;
            }
            if (n == 0) {
                return CVX_EOF;
            }
            if (errno == EINTR) {
                continue;
            }
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                set_errno_error(h);
                return CVX_ERR;
            }
            ready = wait_fd(h->fd, 0, deadline_ms);
        }

        if (ready == CVX_TIMEOUT) {
            return CVX_TIMEOUT;
        }
        if (ready != 1) {
            set_error(h, "poll failed while reading");
            return CVX_ERR;
        }
    }
}

int cvx_net_write(int handle, const unsigned char *in, int len,
                  long long deadline_ms, int *sent)
{
    struct cvx_handle *h = slot_of(handle);
    int done = 0;

    if (sent != NULL) {
        *sent = 0;
    }
    if (h == NULL || in == NULL || len < 0 || sent == NULL) {
        return CVX_HANDLE;
    }

    ignore_sigpipe();

    while (done < len) {
        int ready;
        int n;

        if (h->ssl != NULL) {
            int reason;

            ERR_clear_error();
            n = SSL_write(h->ssl, in + done, len - done);
            if (n > 0) {
                done += n;
                *sent = done;
                continue;
            }
            reason = SSL_get_error(h->ssl, n);
            if (reason == SSL_ERROR_WANT_READ) {
                ready = wait_fd(h->fd, 0, deadline_ms);
            } else if (reason == SSL_ERROR_WANT_WRITE) {
                ready = wait_fd(h->fd, 1, deadline_ms);
            } else {
                set_tls_error(h, "TLS write failed");
                return CVX_TLS;
            }
        } else {
            /* MSG_NOSIGNAL narrows the plain-socket case as well.  The
             * process-level guard above is still required for OpenSSL. */
            n = (int)send(h->fd, in + done, (size_t)(len - done),
                          MSG_NOSIGNAL);
            if (n > 0) {
                done += n;
                *sent = done;
                continue;
            }
            if (n < 0 && errno == EINTR) {
                continue;
            }
            if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                set_errno_error(h);
                return CVX_ERR;
            }
            ready = wait_fd(h->fd, 1, deadline_ms);
        }

        if (ready == CVX_TIMEOUT) {
            return CVX_TIMEOUT;
        }
        if (ready != 1) {
            set_error(h, "poll failed while writing");
            return CVX_ERR;
        }
    }
    return CVX_OK;
}

int cvx_net_readable(int handle, int timeout_ms)
{
    struct cvx_handle *h = slot_of(handle);
    struct pollfd pfd;
    int rc;

    if (h == NULL) {
        return CVX_HANDLE;
    }

    /* A decrypted record already sitting in the OpenSSL buffer leaves the
     * descriptor quiet. Polling first would report "nothing to read" while
     * a whole WebSocket frame is in hand, stalling the Live owner. */
    if (h->ssl != NULL && SSL_pending(h->ssl) > 0) {
        return 1;
    }

    pfd.fd = h->fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    rc = poll(&pfd, 1, timeout_ms < 0 ? 0 : timeout_ms);
    if (rc > 0) {
        return 1;
    }
    if (rc == 0) {
        return 0;
    }
    if (errno == EINTR) {
        return 0;
    }
    set_errno_error(h);
    return CVX_ERR;
}

int cvx_net_shutdown(int handle, long long deadline_ms)
{
    struct cvx_handle *h = slot_of(handle);

    if (h == NULL) {
        return CVX_HANDLE;
    }
    if (h->ssl == NULL) {
        if (h->fd >= 0) {
            shutdown(h->fd, SHUT_WR);
        }
        return CVX_OK;
    }

    for (;;) {
        int rc;
        int reason;
        int ready;

        ERR_clear_error();
        rc = SSL_shutdown(h->ssl);
        if (rc >= 0) {
            return CVX_OK;
        }
        reason = SSL_get_error(h->ssl, rc);
        if (reason == SSL_ERROR_WANT_READ) {
            ready = wait_fd(h->fd, 0, deadline_ms);
        } else if (reason == SSL_ERROR_WANT_WRITE) {
            ready = wait_fd(h->fd, 1, deadline_ms);
        } else {
            /* A peer that vanished without close_notify is not an error
             * worth reporting on a path whose job is to hang up. */
            return CVX_OK;
        }
        if (ready != 1) {
            return CVX_TIMEOUT;
        }
    }
}

int cvx_net_close(int handle)
{
    struct cvx_handle *h = slot_of(handle);

    if (h == NULL) {
        return CVX_HANDLE;
    }
    release_slot(h);
    return CVX_OK;
}

int cvx_net_error(int handle, char *out, int cap, int *len)
{
    struct cvx_handle *h;
    int n;

    if (out == NULL || cap <= 0 || len == NULL) {
        return CVX_ERR;
    }
    *len = 0;
    memset(out, ' ', (size_t)cap);

    if (handle < 0 || handle >= CVX_MAX_HANDLES) {
        return CVX_HANDLE;
    }
    /* Deliberately not slot_of: a failed open releases the slot but the
     * diagnosis is still worth reading. */
    h = &g_handles[handle];
    n = (int)strlen(h->error);
    if (n > cap) {
        n = cap;
    }
    memcpy(out, h->error, (size_t)n);
    *len = n;
    return CVX_OK;
}

/* ------------------------------------------------------------------ */
/* Adapter standard streams and controller socket                      */
/* ------------------------------------------------------------------ */

int cvx_std_readable(int timeout_ms)
{
    struct pollfd pfd;
    int rc;

    pfd.fd = 0;
    pfd.events = POLLIN;
    pfd.revents = 0;
    rc = poll(&pfd, 1, timeout_ms < 0 ? 0 : timeout_ms);
    if (rc > 0) {
        return 1;
    }
    if (rc == 0 || errno == EINTR) {
        return 0;
    }
    return CVX_ERR;
}

int cvx_std_read(unsigned char *out, int cap, int *got)
{
    int n;

    if (got != NULL) {
        *got = 0;
    }
    if (out == NULL || cap <= 0 || got == NULL) {
        return CVX_ERR;
    }
    for (;;) {
        n = (int)read(0, out, (size_t)cap);
        if (n > 0) {
            *got = n;
            return CVX_OK;
        }
        if (n == 0) {
            return CVX_EOF;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return CVX_AGAIN;
        }
        return CVX_ERR;
    }
}

int cvx_std_write(int fd, const unsigned char *in, int len)
{
    int done = 0;

    /* Restricted on purpose: this must not become a way to write to an
     * arbitrary descriptor from COBOL. */
    if (fd != 1 && fd != 2) {
        return CVX_ERR;
    }
    if (in == NULL || len < 0) {
        return CVX_ERR;
    }
    /* A controller may close its NDJSON stream while the adapter is
     * reporting a failure. Return CVX_ERR to the adapter instead of letting
     * that peer-close take down the whole process. */
    ignore_sigpipe();
    while (done < len) {
        int n = (int)write(fd, in + done, (size_t)(len - done));

        if (n > 0) {
            done += n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd pfd;

            pfd.fd = fd;
            pfd.events = POLLOUT;
            pfd.revents = 0;
            poll(&pfd, 1, 1000);
            continue;
        }
        return CVX_ERR;
    }
    return CVX_OK;
}

int cvx_listen_accept(const char *hostport, int len, long long deadline_ms)
{
    char text[128];
    char host[112];
    struct addrinfo hints;
    struct addrinfo *list = NULL;
    char *colon;
    int listener = -1;
    int accepted = -1;
    int one = 1;
    int rc;
    int slot;

    if (copy_field(hostport, len, text, sizeof(text)) <= 0) {
        return CVX_ERR;
    }
    colon = strrchr(text, ':');
    if (colon == NULL || colon == text || colon[1] == '\0') {
        return CVX_ERR;
    }
    *colon = '\0';
    if (strlen(text) >= sizeof(host)) {
        return CVX_LIMIT;
    }
    strcpy(host, text);

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    if (getaddrinfo(host, colon + 1, &hints, &list) != 0 || list == NULL) {
        return CVX_ERR;
    }

    listener = socket(list->ai_family, list->ai_socktype, list->ai_protocol);
    if (listener < 0) {
        freeaddrinfo(list);
        return CVX_ERR;
    }
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    rc = bind(listener, list->ai_addr, list->ai_addrlen);
    freeaddrinfo(list);
    if (rc != 0 || listen(listener, 1) != 0) {
        close(listener);
        return CVX_ERR;
    }
    if (set_nonblocking(listener) != CVX_OK) {
        close(listener);
        return CVX_ERR;
    }

    for (;;) {
        int ready = wait_fd(listener, 0, deadline_ms);

        if (ready != 1) {
            close(listener);
            return ready == CVX_TIMEOUT ? CVX_TIMEOUT : CVX_ERR;
        }
        accepted = accept(listener, NULL, NULL);
        if (accepted >= 0) {
            break;
        }
        if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            close(listener);
            return CVX_ERR;
        }
    }
    close(listener);

    setsockopt(accepted, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    slot = cvx_net_register_fd(accepted);
    if (slot < 0) {
        close(accepted);
    }
    return slot;
}

int cvx_rss_bytes(long long *out_bytes)
{
    FILE *file;
    long long total = 0;
    long long resident = 0;
    long page;

    if (out_bytes == NULL) {
        return CVX_ERR;
    }
    *out_bytes = 0;
    file = fopen("/proc/self/statm", "r");
    if (file == NULL) {
        return CVX_ERR;
    }
    if (fscanf(file, "%lld %lld", &total, &resident) != 2) {
        fclose(file);
        return CVX_ERR;
    }
    fclose(file);

    /* statm counts pages, not bytes. Reporting the raw field would
     * understate memory by the page size and make the adapter accounting
     * test pass for the wrong reason. */
    page = sysconf(_SC_PAGESIZE);
    if (page <= 0) {
        return CVX_ERR;
    }
    *out_bytes = resident * (long long)page;
    return CVX_OK;
}
