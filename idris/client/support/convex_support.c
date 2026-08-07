/*
 * Implementation of the transport boundary declared in convex_support.h.
 *
 * Nothing here knows what Convex is. It moves bytes, measures time, and tells
 * the Idris owner loop whether a descriptor is ready. Keeping the boundary this
 * dumb is what lets the client claim that HTTP envelopes, WebSocket framing,
 * and the pinned sync protocol are implemented in Idris.
 */

/* -std=c11 alone hides POSIX declarations (struct addrinfo, nanosleep, kill,
 * ...) that glibc only exposes once a feature test macro asks for them. This
 * must come before any header is pulled in, including convex_support.h. */
#define _POSIX_C_SOURCE 200809L

#include "convex_support.h"

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
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#define CONVEX_MAX_BUFFERS 256
#define CONVEX_MAX_STREAMS 64
#define CONVEX_MAX_POLL 16
#define CONVEX_TEXT_POOL 4

struct convex_buffer {
    unsigned char *bytes;
    int64_t capacity;
};

struct convex_stream {
    int fd;
    SSL *ssl;
    SSL_CTX *ctx;
    int in_use;
};

static struct convex_buffer convex_buffers[CONVEX_MAX_BUFFERS];
static struct convex_stream convex_streams[CONVEX_MAX_STREAMS];
static struct pollfd convex_poll_entries[CONVEX_MAX_POLL];
static int convex_poll_count = 0;
static char convex_error_text[512] = "";
static char *convex_text_pool[CONVEX_TEXT_POOL];
static int convex_text_slot = 0;
static int convex_initialised = 0;

static void convex_record_error(const char *label, int code)
{
    if (code != 0) {
        snprintf(convex_error_text, sizeof convex_error_text, "%s: %s", label,
                 strerror(code));
    } else {
        snprintf(convex_error_text, sizeof convex_error_text, "%s", label);
    }
}

static void convex_record_ssl_error(const char *label)
{
    unsigned long code = ERR_get_error();
    if (code == 0) {
        convex_record_error(label, errno);
        return;
    }
    snprintf(convex_error_text, sizeof convex_error_text, "%s: %s", label,
             ERR_reason_error_string(code));
    /* Drain the rest of the queue so a later call cannot report a stale cause. */
    while (ERR_get_error() != 0) {
    }
}

char *convex_last_error(void)
{
    return convex_error_text;
}

int64_t convex_init(void)
{
    if (convex_initialised) {
        return 0;
    }
    /* A stopped reader must surface as EPIPE on write so the adapter's output
     * deadline can act on it, not as a signal that kills the process. */
    signal(SIGPIPE, SIG_IGN);
    SSL_library_init();
    OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS,
                     NULL);
    convex_initialised = 1;
    return 0;
}

int64_t convex_now_ms(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        convex_record_error("clock_gettime", errno);
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + (int64_t)(now.tv_nsec / 1000000);
}

/* ------------------------------------------------------------------ buffers */

static struct convex_buffer *convex_buffer_at(int64_t handle)
{
    if (handle < 1 || handle > CONVEX_MAX_BUFFERS) {
        return NULL;
    }
    struct convex_buffer *buffer = &convex_buffers[handle - 1];
    return buffer->bytes == NULL ? NULL : buffer;
}

static int convex_range_ok(struct convex_buffer *buffer, int64_t offset, int64_t length)
{
    if (buffer == NULL || offset < 0 || length < 0) {
        return 0;
    }
    return offset + length <= buffer->capacity;
}

int64_t convex_buf_new(int64_t capacity)
{
    if (capacity < 0 || capacity > (int64_t)1 << 27) {
        convex_record_error("convex_buf_new: capacity out of range", 0);
        return -1;
    }
    for (int index = 0; index < CONVEX_MAX_BUFFERS; index++) {
        if (convex_buffers[index].bytes != NULL) {
            continue;
        }
        unsigned char *bytes = (unsigned char *)calloc((size_t)capacity + 1, 1);
        if (bytes == NULL) {
            convex_record_error("convex_buf_new: out of memory", 0);
            return -1;
        }
        convex_buffers[index].bytes = bytes;
        convex_buffers[index].capacity = capacity;
        return index + 1;
    }
    convex_record_error("convex_buf_new: buffer table is full", 0);
    return -1;
}

int64_t convex_buf_free(int64_t handle)
{
    struct convex_buffer *buffer = convex_buffer_at(handle);
    if (buffer == NULL) {
        return -1;
    }
    free(buffer->bytes);
    buffer->bytes = NULL;
    buffer->capacity = 0;
    return 0;
}

int64_t convex_buf_capacity(int64_t handle)
{
    struct convex_buffer *buffer = convex_buffer_at(handle);
    return buffer == NULL ? -1 : buffer->capacity;
}

int64_t convex_buf_get(int64_t handle, int64_t index)
{
    struct convex_buffer *buffer = convex_buffer_at(handle);
    if (!convex_range_ok(buffer, index, 1)) {
        return -1;
    }
    return buffer->bytes[index];
}

int64_t convex_buf_set(int64_t handle, int64_t index, int64_t value)
{
    struct convex_buffer *buffer = convex_buffer_at(handle);
    if (!convex_range_ok(buffer, index, 1) || value < 0 || value > 255) {
        return -1;
    }
    buffer->bytes[index] = (unsigned char)value;
    return 0;
}

int64_t convex_buf_copy(int64_t destination_handle, int64_t destination_offset,
                        int64_t source_handle, int64_t source_offset, int64_t length)
{
    struct convex_buffer *destination = convex_buffer_at(destination_handle);
    struct convex_buffer *source = convex_buffer_at(source_handle);
    if (!convex_range_ok(destination, destination_offset, length) ||
        !convex_range_ok(source, source_offset, length)) {
        return -1;
    }
    memmove(destination->bytes + destination_offset, source->bytes + source_offset,
            (size_t)length);
    return length;
}

/* Strict UTF-8 scanner. It rejects overlong forms, surrogates, and anything
 * above U+10FFFF so a fragmented text message cannot decode into replacement
 * characters that silently corrupt a Convex value. */
static int64_t convex_scan_utf8(const unsigned char *bytes, int64_t length)
{
    int64_t index = 0;
    while (index < length) {
        unsigned char lead = bytes[index];
        int64_t extra;
        int64_t code;
        if (lead < 0x80) {
            index += 1;
            continue;
        } else if ((lead & 0xE0) == 0xC0) {
            extra = 1;
            code = lead & 0x1F;
        } else if ((lead & 0xF0) == 0xE0) {
            extra = 2;
            code = lead & 0x0F;
        } else if ((lead & 0xF8) == 0xF0) {
            extra = 3;
            code = lead & 0x07;
        } else {
            return -1;
        }
        /* Every continuation byte must already be present. A truncated
         * sequence is a decoding failure, never a partial success. */
        if (index + extra >= length) {
            return -1;
        }
        for (int64_t step = 1; step <= extra; step++) {
            unsigned char continuation = bytes[index + step];
            if ((continuation & 0xC0) != 0x80) {
                return -1;
            }
            code = (code << 6) | (continuation & 0x3F);
        }
        if (extra == 1 && code < 0x80) {
            return -1;
        }
        if (extra == 2 && code < 0x800) {
            return -1;
        }
        if (extra == 3 && code < 0x10000) {
            return -1;
        }
        if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
            return -1;
        }
        index += extra + 1;
    }
    return 0;
}

int64_t convex_text_size(char *text)
{
    return text == NULL ? 0 : (int64_t)strlen(text);
}

int64_t convex_buf_put_text(int64_t handle, int64_t offset, char *text)
{
    struct convex_buffer *buffer = convex_buffer_at(handle);
    int64_t length = convex_text_size(text);
    if (!convex_range_ok(buffer, offset, length)) {
        return -1;
    }
    if (length > 0) {
        memcpy(buffer->bytes + offset, text, (size_t)length);
    }
    return length;
}

int64_t convex_buf_valid_utf8(int64_t handle, int64_t offset, int64_t length)
{
    struct convex_buffer *buffer = convex_buffer_at(handle);
    if (!convex_range_ok(buffer, offset, length)) {
        return -1;
    }
    return convex_scan_utf8(buffer->bytes + offset, length);
}

/* Returned strings are owned by this module. RefC copies a returned char* into
 * an Idris string immediately, and the small rotating pool keeps a slice alive
 * long enough for that copy without leaking on a long-lived connection.
 *
 * A failure returns the empty string rather than NULL because the Idris runtime
 * would dereference NULL while building the string. Callers must therefore ask
 * convex_buf_valid_utf8 first and treat a decoding failure as a protocol error.
 */
char *convex_buf_take_text(int64_t handle, int64_t offset, int64_t length)
{
    static char empty[1] = "";
    struct convex_buffer *buffer = convex_buffer_at(handle);
    if (!convex_range_ok(buffer, offset, length)) {
        convex_record_error("convex_buf_take_text: range out of bounds", 0);
        return empty;
    }
    if (convex_scan_utf8(buffer->bytes + offset, length) != 0) {
        convex_record_error("convex_buf_take_text: invalid UTF-8", 0);
        return empty;
    }
    /* An embedded NUL would truncate the Idris string and hide payload, so it
     * is a decoding failure rather than a silently shortened value. */
    if (memchr(buffer->bytes + offset, 0, (size_t)length) != NULL) {
        convex_record_error("convex_buf_take_text: embedded NUL byte", 0);
        return empty;
    }
    char *slot = (char *)malloc((size_t)length + 1);
    if (slot == NULL) {
        convex_record_error("convex_buf_take_text: out of memory", 0);
        return empty;
    }
    memcpy(slot, buffer->bytes + offset, (size_t)length);
    slot[length] = '\0';
    free(convex_text_pool[convex_text_slot]);
    convex_text_pool[convex_text_slot] = slot;
    convex_text_slot = (convex_text_slot + 1) % CONVEX_TEXT_POOL;
    return slot;
}

int64_t convex_random_bytes(int64_t handle, int64_t offset, int64_t length)
{
    struct convex_buffer *buffer = convex_buffer_at(handle);
    if (!convex_range_ok(buffer, offset, length)) {
        return -1;
    }
    FILE *source = fopen("/dev/urandom", "rb");
    if (source == NULL) {
        convex_record_error("open /dev/urandom", errno);
        return -1;
    }
    size_t read_bytes = fread(buffer->bytes + offset, 1, (size_t)length, source);
    fclose(source);
    if (read_bytes != (size_t)length) {
        convex_record_error("read /dev/urandom", 0);
        return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ sockets */

int64_t convex_set_nonblocking(int64_t fd)
{
    int flags = fcntl((int)fd, F_GETFL, 0);
    if (flags < 0 || fcntl((int)fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        convex_record_error("fcntl O_NONBLOCK", errno);
        return -1;
    }
    return 0;
}

int64_t convex_dup2(int64_t from_fd, int64_t to_fd)
{
    return dup2((int)from_fd, (int)to_fd) < 0 ? -1 : 0;
}

int64_t convex_close_fd(int64_t fd)
{
    if (fd < 0) {
        return -1;
    }
    return close((int)fd) == 0 ? 0 : -1;
}

int64_t convex_shutdown_write(int64_t fd)
{
    return shutdown((int)fd, SHUT_WR) == 0 ? 0 : -1;
}

static int64_t convex_wait_for(int fd, short events, int64_t deadline_ms)
{
    struct pollfd entry;
    for (;;) {
        int64_t remaining = deadline_ms - convex_now_ms();
        if (remaining <= 0) {
            convex_record_error("deadline expired", 0);
            return -1;
        }
        entry.fd = fd;
        entry.events = events;
        entry.revents = 0;
        int ready = poll(&entry, 1, remaining > 60000 ? 60000 : (int)remaining);
        if (ready > 0) {
            return 0;
        }
        if (ready == 0) {
            continue;
        }
        if (errno != EINTR) {
            convex_record_error("poll", errno);
            return -1;
        }
    }
}

int64_t convex_tcp_connect(char *host, int64_t port, int64_t deadline_ms)
{
    char service[16];
    struct addrinfo hints;
    struct addrinfo *results = NULL;

    snprintf(service, sizeof service, "%d", (int)port);
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    int resolved = getaddrinfo(host, service, &hints, &results);
    if (resolved != 0 || results == NULL) {
        convex_record_error(gai_strerror(resolved), 0);
        return -1;
    }

    int64_t connected = -1;
    for (struct addrinfo *entry = results; entry != NULL; entry = entry->ai_next) {
        int fd = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
        if (fd < 0) {
            continue;
        }
        if (convex_set_nonblocking(fd) != 0) {
            close(fd);
            continue;
        }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        int attempt = connect(fd, entry->ai_addr, entry->ai_addrlen);
        if (attempt != 0 && errno == EINPROGRESS) {
            if (convex_wait_for(fd, POLLOUT, deadline_ms) != 0) {
                close(fd);
                continue;
            }
            int error = 0;
            socklen_t error_size = sizeof error;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_size) != 0 ||
                error != 0) {
                convex_record_error("connect", error);
                close(fd);
                continue;
            }
        } else if (attempt != 0) {
            convex_record_error("connect", errno);
            close(fd);
            continue;
        }
        connected = fd;
        break;
    }
    freeaddrinfo(results);
    if (connected < 0) {
        convex_record_error("connect: no usable address", 0);
    }
    return connected;
}

int64_t convex_tcp_listen(char *host, int64_t port)
{
    char service[16];
    struct addrinfo hints;
    struct addrinfo *results = NULL;

    snprintf(service, sizeof service, "%d", (int)port);
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;

    if (getaddrinfo(host, service, &hints, &results) != 0 || results == NULL) {
        convex_record_error("getaddrinfo for listen", errno);
        return -1;
    }
    int fd = socket(results->ai_family, results->ai_socktype, results->ai_protocol);
    if (fd < 0) {
        convex_record_error("socket", errno);
        freeaddrinfo(results);
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(fd, results->ai_addr, results->ai_addrlen) != 0 || listen(fd, 8) != 0) {
        convex_record_error("bind/listen", errno);
        close(fd);
        freeaddrinfo(results);
        return -1;
    }
    freeaddrinfo(results);
    return fd;
}

int64_t convex_tcp_port(int64_t fd)
{
    struct sockaddr_in address;
    socklen_t size = sizeof address;
    if (getsockname((int)fd, (struct sockaddr *)&address, &size) != 0) {
        convex_record_error("getsockname", errno);
        return -1;
    }
    return ntohs(address.sin_port);
}

int64_t convex_tcp_accept(int64_t fd, int64_t deadline_ms)
{
    for (;;) {
        int accepted = accept((int)fd, NULL, NULL);
        if (accepted >= 0) {
            convex_set_nonblocking(accepted);
            int one = 1;
            setsockopt(accepted, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
            return accepted;
        }
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            convex_record_error("accept", errno);
            return -1;
        }
        if (convex_wait_for((int)fd, POLLIN, deadline_ms) != 0) {
            return -1;
        }
    }
}

/* --------------------------------------------------------------- poll sets */

int64_t convex_pollset_reset(void)
{
    convex_poll_count = 0;
    return 0;
}

int64_t convex_pollset_add(int64_t fd, int64_t interest)
{
    if (convex_poll_count >= CONVEX_MAX_POLL || fd < 0) {
        return -1;
    }
    short events = 0;
    if (interest & CONVEX_POLL_READ) {
        events |= POLLIN;
    }
    if (interest & CONVEX_POLL_WRITE) {
        events |= POLLOUT;
    }
    convex_poll_entries[convex_poll_count].fd = (int)fd;
    convex_poll_entries[convex_poll_count].events = events;
    convex_poll_entries[convex_poll_count].revents = 0;
    convex_poll_count++;
    return 0;
}

int64_t convex_pollset_wait(int64_t timeout_ms)
{
    if (timeout_ms < 0) {
        timeout_ms = 0;
    }
    if (timeout_ms > 60000) {
        timeout_ms = 60000;
    }
    int ready = poll(convex_poll_entries, (nfds_t)convex_poll_count, (int)timeout_ms);
    if (ready < 0) {
        if (errno == EINTR) {
            return 0;
        }
        convex_record_error("poll", errno);
        return -1;
    }
    return ready;
}

int64_t convex_pollset_ready(int64_t fd)
{
    for (int index = 0; index < convex_poll_count; index++) {
        if (convex_poll_entries[index].fd != (int)fd) {
            continue;
        }
        short revents = convex_poll_entries[index].revents;
        int64_t mask = 0;
        if (revents & POLLIN) {
            mask |= CONVEX_POLL_READ;
        }
        if (revents & POLLOUT) {
            mask |= CONVEX_POLL_WRITE;
        }
        if (revents & (POLLERR | POLLHUP | POLLNVAL)) {
            mask |= CONVEX_POLL_ERROR;
        }
        return mask;
    }
    return 0;
}

/* ------------------------------------------------------------------ streams */

static struct convex_stream *convex_stream_at(int64_t handle)
{
    if (handle < 1 || handle > CONVEX_MAX_STREAMS) {
        return NULL;
    }
    struct convex_stream *stream = &convex_streams[handle - 1];
    return stream->in_use ? stream : NULL;
}

static int64_t convex_stream_alloc(int fd, SSL *ssl, SSL_CTX *ctx)
{
    for (int index = 0; index < CONVEX_MAX_STREAMS; index++) {
        if (convex_streams[index].in_use) {
            continue;
        }
        convex_streams[index].fd = fd;
        convex_streams[index].ssl = ssl;
        convex_streams[index].ctx = ctx;
        convex_streams[index].in_use = 1;
        return index + 1;
    }
    convex_record_error("stream table is full", 0);
    return -1;
}

int64_t convex_stream_plain(int64_t fd)
{
    convex_init();
    return convex_stream_alloc((int)fd, NULL, NULL);
}

int64_t convex_stream_tls_client(int64_t fd, char *hostname, char *ca_file)
{
    convex_init();
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (ctx == NULL) {
        convex_record_ssl_error("SSL_CTX_new");
        return -1;
    }
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    int trusted = (ca_file != NULL && ca_file[0] != '\0')
                      ? SSL_CTX_load_verify_locations(ctx, ca_file, NULL)
                      : SSL_CTX_set_default_verify_paths(ctx);
    if (trusted != 1) {
        convex_record_ssl_error("trust store");
        SSL_CTX_free(ctx);
        return -1;
    }
    SSL *ssl = SSL_new(ctx);
    if (ssl == NULL) {
        convex_record_ssl_error("SSL_new");
        SSL_CTX_free(ctx);
        return -1;
    }
    /* Server name indication and RFC 6125 hostname checking both matter: a
     * certificate valid for another name must fail the handshake. */
    SSL_set_tlsext_host_name(ssl, hostname);
    SSL_set_hostflags(ssl, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    if (SSL_set1_host(ssl, hostname) != 1) {
        convex_record_ssl_error("SSL_set1_host");
        SSL_free(ssl);
        SSL_CTX_free(ctx);
        return -1;
    }
    SSL_set_fd(ssl, (int)fd);
    SSL_set_connect_state(ssl);
    int64_t handle = convex_stream_alloc((int)fd, ssl, ctx);
    if (handle < 0) {
        SSL_free(ssl);
        SSL_CTX_free(ctx);
    }
    return handle;
}

int64_t convex_stream_tls_server(int64_t fd, char *certificate_file, char *key_file)
{
    convex_init();
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    if (ctx == NULL) {
        convex_record_ssl_error("SSL_CTX_new server");
        return -1;
    }
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    if (SSL_CTX_use_certificate_chain_file(ctx, certificate_file) != 1 ||
        SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) != 1) {
        convex_record_ssl_error("server certificate");
        SSL_CTX_free(ctx);
        return -1;
    }
    SSL *ssl = SSL_new(ctx);
    if (ssl == NULL) {
        convex_record_ssl_error("SSL_new server");
        SSL_CTX_free(ctx);
        return -1;
    }
    SSL_set_fd(ssl, (int)fd);
    SSL_set_accept_state(ssl);
    int64_t handle = convex_stream_alloc((int)fd, ssl, ctx);
    if (handle < 0) {
        SSL_free(ssl);
        SSL_CTX_free(ctx);
    }
    return handle;
}

int64_t convex_stream_handshake(int64_t handle)
{
    struct convex_stream *stream = convex_stream_at(handle);
    if (stream == NULL) {
        return -1;
    }
    if (stream->ssl == NULL) {
        return 0;
    }
    int result = SSL_do_handshake(stream->ssl);
    if (result == 1) {
        return 0;
    }
    int reason = SSL_get_error(stream->ssl, result);
    if (reason == SSL_ERROR_WANT_READ) {
        return 1;
    }
    if (reason == SSL_ERROR_WANT_WRITE) {
        return 2;
    }
    convex_record_ssl_error("SSL_do_handshake");
    return -1;
}

int64_t convex_stream_read(int64_t handle, int64_t buffer_handle, int64_t offset,
                           int64_t length)
{
    struct convex_stream *stream = convex_stream_at(handle);
    struct convex_buffer *buffer = convex_buffer_at(buffer_handle);
    if (stream == NULL || !convex_range_ok(buffer, offset, length)) {
        return CONVEX_IO_ERROR;
    }
    if (length == 0) {
        return 0;
    }
    if (stream->ssl == NULL) {
        ssize_t received = recv(stream->fd, buffer->bytes + offset, (size_t)length, 0);
        if (received > 0) {
            return received;
        }
        if (received == 0) {
            return CONVEX_IO_EOF;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            return CONVEX_IO_WANT_READ;
        }
        convex_record_error("recv", errno);
        return CONVEX_IO_ERROR;
    }
    int received = SSL_read(stream->ssl, buffer->bytes + offset, (int)length);
    if (received > 0) {
        return received;
    }
    int reason = SSL_get_error(stream->ssl, received);
    if (reason == SSL_ERROR_WANT_READ) {
        return CONVEX_IO_WANT_READ;
    }
    if (reason == SSL_ERROR_WANT_WRITE) {
        return CONVEX_IO_WANT_WRITE;
    }
    if (reason == SSL_ERROR_ZERO_RETURN) {
        return CONVEX_IO_EOF;
    }
    /* A peer that vanishes without close_notify is an ordinary transport end,
     * not a protocol violation, so report it as EOF and let the caller decide. */
    if (reason == SSL_ERROR_SYSCALL && ERR_peek_error() == 0) {
        return CONVEX_IO_EOF;
    }
    convex_record_ssl_error("SSL_read");
    return CONVEX_IO_ERROR;
}

int64_t convex_stream_write(int64_t handle, int64_t buffer_handle, int64_t offset,
                            int64_t length)
{
    struct convex_stream *stream = convex_stream_at(handle);
    struct convex_buffer *buffer = convex_buffer_at(buffer_handle);
    if (stream == NULL || !convex_range_ok(buffer, offset, length)) {
        return CONVEX_IO_ERROR;
    }
    if (length == 0) {
        return 0;
    }
    if (stream->ssl == NULL) {
        ssize_t sent = send(stream->fd, buffer->bytes + offset, (size_t)length,
                            MSG_NOSIGNAL);
        if (sent > 0) {
            return sent;
        }
        if (sent == 0) {
            return CONVEX_IO_WANT_WRITE;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            return CONVEX_IO_WANT_WRITE;
        }
        convex_record_error("send", errno);
        return CONVEX_IO_ERROR;
    }
    int sent = SSL_write(stream->ssl, buffer->bytes + offset, (int)length);
    if (sent > 0) {
        return sent;
    }
    int reason = SSL_get_error(stream->ssl, sent);
    if (reason == SSL_ERROR_WANT_READ) {
        return CONVEX_IO_WANT_READ;
    }
    if (reason == SSL_ERROR_WANT_WRITE) {
        return CONVEX_IO_WANT_WRITE;
    }
    convex_record_ssl_error("SSL_write");
    return CONVEX_IO_ERROR;
}

int64_t convex_stream_pending(int64_t handle)
{
    struct convex_stream *stream = convex_stream_at(handle);
    if (stream == NULL || stream->ssl == NULL) {
        return 0;
    }
    return SSL_pending(stream->ssl);
}

int64_t convex_stream_shutdown(int64_t handle)
{
    struct convex_stream *stream = convex_stream_at(handle);
    if (stream == NULL) {
        return -1;
    }
    if (stream->ssl == NULL) {
        return shutdown(stream->fd, SHUT_WR) == 0 ? 0 : -1;
    }
    int result = SSL_shutdown(stream->ssl);
    if (result >= 0) {
        return 0;
    }
    int reason = SSL_get_error(stream->ssl, result);
    if (reason == SSL_ERROR_WANT_READ) {
        return 1;
    }
    if (reason == SSL_ERROR_WANT_WRITE) {
        return 2;
    }
    convex_record_ssl_error("SSL_shutdown");
    return -1;
}

int64_t convex_stream_fd(int64_t handle)
{
    struct convex_stream *stream = convex_stream_at(handle);
    return stream == NULL ? -1 : stream->fd;
}

int64_t convex_stream_free(int64_t handle)
{
    struct convex_stream *stream = convex_stream_at(handle);
    if (stream == NULL) {
        return -1;
    }
    if (stream->ssl != NULL) {
        SSL_free(stream->ssl);
    }
    if (stream->ctx != NULL) {
        SSL_CTX_free(stream->ctx);
    }
    if (stream->fd >= 0) {
        close(stream->fd);
    }
    stream->ssl = NULL;
    stream->ctx = NULL;
    stream->fd = -1;
    stream->in_use = 0;
    return 0;
}

/* -------------------------------------------------------- raw descriptor IO */

int64_t convex_fd_read(int64_t fd, int64_t buffer_handle, int64_t offset, int64_t length)
{
    struct convex_buffer *buffer = convex_buffer_at(buffer_handle);
    if (!convex_range_ok(buffer, offset, length)) {
        return CONVEX_IO_ERROR;
    }
    ssize_t received = read((int)fd, buffer->bytes + offset, (size_t)length);
    if (received > 0) {
        return received;
    }
    if (received == 0) {
        return CONVEX_IO_EOF;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return CONVEX_IO_WANT_READ;
    }
    convex_record_error("read", errno);
    return CONVEX_IO_ERROR;
}

int64_t convex_fd_write(int64_t fd, int64_t buffer_handle, int64_t offset, int64_t length)
{
    struct convex_buffer *buffer = convex_buffer_at(buffer_handle);
    if (!convex_range_ok(buffer, offset, length)) {
        return CONVEX_IO_ERROR;
    }
    if (length == 0) {
        return 0;
    }
    ssize_t sent = write((int)fd, buffer->bytes + offset, (size_t)length);
    if (sent > 0) {
        return sent;
    }
    if (sent == 0) {
        return CONVEX_IO_WANT_WRITE;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return CONVEX_IO_WANT_WRITE;
    }
    convex_record_error("write", errno);
    return CONVEX_IO_ERROR;
}

int64_t convex_write_stderr(char *text)
{
    if (text == NULL) {
        return 0;
    }
    size_t length = strlen(text);
    size_t written = 0;
    while (written < length) {
        ssize_t sent = write(2, text + written, length - written);
        if (sent > 0) {
            written += (size_t)sent;
            continue;
        }
        if (sent < 0 && (errno == EINTR || errno == EAGAIN)) {
            continue;
        }
        return -1;
    }
    return (int64_t)written;
}

/* ---------------------------------------------------------- fixture process */

int64_t convex_fork(void)
{
    pid_t child = fork();
    if (child < 0) {
        convex_record_error("fork", errno);
        return -1;
    }
    return child;
}

int64_t convex_waitpid(int64_t pid, int64_t deadline_ms)
{
    for (;;) {
        int status = 0;
        pid_t finished = waitpid((pid_t)pid, &status, WNOHANG);
        if (finished == (pid_t)pid) {
            return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
        }
        if (finished < 0) {
            convex_record_error("waitpid", errno);
            return -1;
        }
        if (convex_now_ms() >= deadline_ms) {
            convex_record_error("waitpid: deadline expired", 0);
            return -1;
        }
        struct timespec pause = {0, 2 * 1000 * 1000};
        nanosleep(&pause, NULL);
    }
}

int64_t convex_kill(int64_t pid)
{
    return kill((pid_t)pid, SIGKILL) == 0 ? 0 : -1;
}

int64_t convex_exit(int64_t code)
{
    _exit((int)code);
    return 0;
}
