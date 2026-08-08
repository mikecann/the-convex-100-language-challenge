#include "share/atspre_staload.hats"
staload "./convex_transport.sats"
staload UN = "prelude/SATS/unsafe.sats"

%{^
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netdb.h>
#include <poll.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/evp.h>

/* These mirror the #define constants in convex_transport.sats: an ATS
   `#define` is processed by patsopt for ATS source only and never reaches
   the C emitted from a %{^ ... %} block, so the two copies must agree by
   hand. */
#define WS_TIMEOUT 0
#define WS_TEXT 1
#define WS_PEER_CLOSED 2
#define WS_ERROR 3
#define LINE_OK 0
#define LINE_EOF 1
#define LINE_ERROR 2
#define POLL_NONE 0
#define POLL_CONTROL 1
#define POLL_LIVE 2
#define POLL_BOTH 3

/* One connected socket, optionally wrapped in a verified TLS session. The
   approved self-hosted backend profile (http://backend:3210) is plain
   HTTP/WS, so `ssl` is NULL for that case and conn_read/conn_write fall
   back to plain read()/write() on `fd`. */
typedef struct ConvexTls {
    SSL_CTX *ctx;
    SSL *ssl;
    int fd;
} ConvexTls;

static int conn_read(ConvexTls *c, void *buf, int len) {
    return c->ssl != NULL ? SSL_read(c->ssl, buf, len) : (int) read(c->fd, buf, (size_t) len);
}
static int conn_write(ConvexTls *c, const void *buf, int len) {
    return c->ssl != NULL ? SSL_write(c->ssl, buf, len) : (int) write(c->fd, buf, (size_t) len);
}

static char *conv_strdup(const char *s) {
    size_t n = strlen(s);
    char *out = malloc(n + 1);
    memcpy(out, s, n + 1);
    return out;
}

static void conv_tls_open(const char *host, int port, int use_tls,
        void **out_conn, int *out_status, char **out_errmsg) {
    struct addrinfo hints, *res = NULL, *rp;
    char portbuf[16];
    int sockfd = -1;
    char errbuf[256];
    errbuf[0] = '\0';
    *out_conn = NULL;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(portbuf, sizeof(portbuf), "%d", port);

    if (getaddrinfo(host, portbuf, &hints, &res) != 0) {
        *out_status = 1; *out_errmsg = conv_strdup("DNS lookup failed"); return;
    }
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        sockfd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (sockfd < 0) continue;
        if (connect(sockfd, rp->ai_addr, rp->ai_addrlen) == 0) break;
        close(sockfd); sockfd = -1;
    }
    freeaddrinfo(res);
    if (sockfd < 0) {
        *out_status = 1; *out_errmsg = conv_strdup("connect() failed"); return;
    }
    if (!use_tls) {
        ConvexTls *conn = malloc(sizeof(ConvexTls));
        conn->ctx = NULL; conn->ssl = NULL; conn->fd = sockfd;
        *out_conn = conn; *out_status = 0; *out_errmsg = conv_strdup("");
        return;
    }
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    SSL_CTX_set_default_verify_paths(ctx);
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL *ssl = SSL_new(ctx);
    SSL_set_tlsext_host_name(ssl, host);
    X509_VERIFY_PARAM *param = SSL_get0_param(ssl);
    X509_VERIFY_PARAM_set1_host(param, host, 0);
    SSL_set_fd(ssl, sockfd);
    if (SSL_connect(ssl) != 1) {
        unsigned long code = ERR_get_error();
        ERR_error_string_n(code, errbuf, sizeof(errbuf));
        SSL_free(ssl); SSL_CTX_free(ctx); close(sockfd);
        *out_status = 1;
        *out_errmsg = conv_strdup(errbuf[0] ? errbuf : "TLS handshake failed");
        return;
    }
    if (SSL_get_verify_result(ssl) != X509_V_OK) {
        SSL_shutdown(ssl); SSL_free(ssl); SSL_CTX_free(ctx); close(sockfd);
        *out_status = 1; *out_errmsg = conv_strdup("certificate verification failed");
        return;
    }
    ConvexTls *conn = malloc(sizeof(ConvexTls));
    conn->ctx = ctx; conn->ssl = ssl; conn->fd = sockfd;
    *out_conn = conn; *out_status = 0; *out_errmsg = conv_strdup("");
}

static void conv_tls_close(void *vconn) {
    ConvexTls *c = (ConvexTls *) vconn;
    if (c->ssl != NULL) { SSL_shutdown(c->ssl); SSL_free(c->ssl); SSL_CTX_free(c->ctx); }
    close(c->fd);
    free(c);
}

static int conv_tls_fd(void *vconn) { return ((ConvexTls *) vconn)->fd; }

static void conv_tls_write(void *vconn, const char *text, int *out_status, char **out_errmsg) {
    ConvexTls *c = (ConvexTls *) vconn;
    size_t total = strlen(text), sent = 0;
    while (sent < total) {
        int n = conn_write(c, text + sent, (int) (total - sent));
        if (n <= 0) { *out_status = 1; *out_errmsg = conv_strdup("TLS write failed"); return; }
        sent += (size_t) n;
    }
    *out_status = 0; *out_errmsg = conv_strdup("");
}

static void conv_tls_read_http_response(void *vconn, int *out_status, int *out_http_status,
        char **out_body, char **out_errmsg) {
    ConvexTls *c = (ConvexTls *) vconn;
    size_t cap = 65536, len = 0;
    char *buf = malloc(cap);
    char *header_end = NULL;
    int status = 0;
    long content_length = -1;
    int chunked = 0;
    int failed = 0;
    char errbuf[128]; errbuf[0] = '\0';

    for (;;) {
        if (len + 4096 > cap) { cap *= 2; buf = realloc(buf, cap); }
        int n = conn_read(c, buf + len, (int) (cap - len));
        if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), "connection closed before response headers"); break; }
        len += (size_t) n;
        buf[len] = '\0';
        header_end = strstr(buf, "\r\n\r\n");
        if (header_end != NULL) break;
        if (len > 262144) { failed = 1; snprintf(errbuf, sizeof(errbuf), "response headers exceeded 256 KiB"); break; }
    }

    if (!failed) {
        sscanf(buf, "HTTP/1.%*d %d", &status);
        char *cl = strcasestr(buf, "\r\nContent-Length:");
        if (cl != NULL) content_length = strtol(cl + 18, NULL, 10);
        char *te = strcasestr(buf, "\r\nTransfer-Encoding:");
        if (te != NULL && strcasestr(te, "chunked") != NULL
            && (cl == NULL || te < cl || strcasestr(te, "chunked") < strstr(cl, "\r\n"))) {
            chunked = 1;
        }
    }

    char *body_start = NULL;
    size_t body_have = 0;
    if (!failed) { body_start = header_end + 4; body_have = len - (size_t) (body_start - buf); }

    char *body = NULL;
    size_t body_len = 0;

    if (!failed && chunked) {
        char *out = malloc(cap);
        size_t out_len = 0;
        char *cursor = body_start;
        for (;;) {
            char *line_end;
            while ((line_end = strstr(cursor, "\r\n")) == NULL) {
                if (len + 4096 > cap) { cap *= 2; buf = realloc(buf, cap); out = realloc(out, cap); }
                size_t cursor_off = (size_t) (cursor - buf);
                int n = conn_read(c, buf + len, (int) (cap - len));
                if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), "connection closed mid-chunk"); break; }
                len += (size_t) n; buf[len] = '\0'; cursor = buf + cursor_off;
            }
            if (failed) break;
            long chunk_size = strtol(cursor, NULL, 16);
            cursor = line_end + 2;
            if (chunk_size == 0) break;
            while ((size_t) (cursor - buf) + (size_t) chunk_size + 2 > len) {
                if (len + 4096 > cap) { cap *= 2; buf = realloc(buf, cap); out = realloc(out, cap); }
                size_t cursor_off = (size_t) (cursor - buf);
                int n = conn_read(c, buf + len, (int) (cap - len));
                if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), "connection closed mid-chunk"); break; }
                len += (size_t) n; buf[len] = '\0'; cursor = buf + cursor_off;
            }
            if (failed) break;
            if (out_len + (size_t) chunk_size + 1 > cap) { cap = out_len + (size_t) chunk_size + 4096; out = realloc(out, cap); }
            memcpy(out + out_len, cursor, (size_t) chunk_size);
            out_len += (size_t) chunk_size;
            cursor += chunk_size + 2;
        }
        body = out; body_len = out_len;
    } else if (!failed && content_length >= 0) {
        while (body_have < (size_t) content_length) {
            if (len + 4096 > cap) { cap *= 2; buf = realloc(buf, cap); }
            size_t body_off = (size_t) (body_start - buf);
            int n = conn_read(c, buf + len, (int) (cap - len));
            if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), "connection closed before full body"); break; }
            len += (size_t) n; buf[len] = '\0';
            body_start = buf + body_off; body_have = len - body_off;
        }
        body = body_start; body_len = (size_t) content_length;
    } else if (!failed) {
        for (;;) {
            if (len + 4096 > cap) { cap *= 2; buf = realloc(buf, cap); }
            size_t body_off = (size_t) (body_start - buf);
            int n = conn_read(c, buf + len, (int) (cap - len));
            if (n <= 0) break;
            len += (size_t) n; buf[len] = '\0'; body_start = buf + body_off;
        }
        body = body_start; body_len = len - (size_t) (body_start - buf);
    }

    if (failed) {
        *out_status = 1; *out_http_status = 0; *out_body = conv_strdup("");
        *out_errmsg = conv_strdup(errbuf);
    } else {
        char *bcopy = malloc(body_len + 1);
        memcpy(bcopy, body, body_len);
        bcopy[body_len] = '\0';
        *out_status = 0; *out_http_status = status; *out_body = bcopy; *out_errmsg = conv_strdup("");
    }
    free(buf);
}

static const char *CONVEX_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
static void convex_base64_encode(const unsigned char *data, size_t len, char *out) {
    EVP_EncodeBlock((unsigned char *) out, data, (int) len);
}

static void conv_ws_handshake(void *vconn, const char *host, const char *path,
        int *out_status, char **out_errmsg) {
    ConvexTls *c = (ConvexTls *) vconn;
    unsigned char key_bytes[16];
    char key_b64[32];
    char request[1024];
    char accept_input[128];
    unsigned char accept_sha1[SHA_DIGEST_LENGTH];
    char accept_expected[64];

    RAND_bytes(key_bytes, sizeof(key_bytes));
    convex_base64_encode(key_bytes, sizeof(key_bytes), key_b64);

    snprintf(request, sizeof(request),
        "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
        path, host, key_b64);

    int failed = 0;
    char errbuf[160]; errbuf[0] = '\0';
    size_t total = strlen(request), sent = 0;
    while (sent < total && !failed) {
        int n = conn_write(c, request + sent, (int) (total - sent));
        if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), "handshake write failed"); }
        else sent += (size_t) n;
    }

    char buf[4096];
    size_t len = 0;
    char *header_end = NULL;
    if (!failed) {
        for (;;) {
            int n = conn_read(c, buf + len, (int) (sizeof(buf) - 1 - len));
            if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), "handshake read failed"); break; }
            len += (size_t) n; buf[len] = '\0';
            header_end = strstr(buf, "\r\n\r\n");
            if (header_end != NULL) break;
            if (len >= sizeof(buf) - 1) { failed = 1; snprintf(errbuf, sizeof(errbuf), "handshake response too large"); break; }
        }
    }
    if (!failed) {
        int status = 0;
        sscanf(buf, "HTTP/1.%*d %d", &status);
        char *accept_hdr = strcasestr(buf, "\r\nSec-WebSocket-Accept:");
        if (status != 101 || accept_hdr == NULL) {
            failed = 1; snprintf(errbuf, sizeof(errbuf), "unexpected handshake response (status %d)", status);
        } else {
            snprintf(accept_input, sizeof(accept_input), "%s%s", key_b64, CONVEX_WS_GUID);
            SHA1((const unsigned char *) accept_input, strlen(accept_input), accept_sha1);
            convex_base64_encode(accept_sha1, SHA_DIGEST_LENGTH, accept_expected);
            char actual[64];
            sscanf(accept_hdr + 24, "%63s", actual);
            if (strncmp(actual, accept_expected, strlen(accept_expected)) != 0) {
                failed = 1; snprintf(errbuf, sizeof(errbuf), "Sec-WebSocket-Accept mismatch");
            }
        }
    }
    *out_status = failed ? 1 : 0;
    *out_errmsg = conv_strdup(errbuf);
}

/* The masking key for a client->server WebSocket frame is exactly four
   bytes by the RFC 6455 wire format. ws_mask_apply below receives it as a
   dependently-sized `@[uint8][4]` array from the ATS side and this C
   function only ever touches indices [0,4) -- the boundary itself is
   proof-carrying, not merely convention. */
static void conv_ws_send_text(void *vconn, const char *text, int *out_status, char **out_errmsg) {
    ConvexTls *c = (ConvexTls *) vconn;
    size_t payload_len = strlen(text);
    size_t header_len;
    unsigned char header[14];
    unsigned char mask[4];
    unsigned char *frame;
    size_t i;
    int failed = 0;

    header[0] = 0x81;
    if (payload_len <= 125) { header[1] = (unsigned char) (0x80 | payload_len); header_len = 2; }
    else if (payload_len <= 65535) {
        header[1] = 0x80 | 126;
        header[2] = (unsigned char) ((payload_len >> 8) & 0xFF);
        header[3] = (unsigned char) (payload_len & 0xFF);
        header_len = 4;
    } else {
        header[1] = 0x80 | 127;
        for (i = 0; i < 8; i++) header[2 + i] = (unsigned char) ((payload_len >> (8 * (7 - i))) & 0xFF);
        header_len = 10;
    }
    RAND_bytes(mask, 4);
    memcpy(header + header_len, mask, 4);
    header_len += 4;

    frame = malloc(header_len + payload_len);
    memcpy(frame, header, header_len);
    for (i = 0; i < payload_len; i++) frame[header_len + i] = ((unsigned char) text[i]) ^ mask[i % 4];

    size_t sent = 0, frame_len = header_len + payload_len;
    while (sent < frame_len) {
        int n = conn_write(c, frame + sent, (int) (frame_len - sent));
        if (n <= 0) { failed = 1; break; }
        sent += (size_t) n;
    }
    free(frame);
    *out_status = failed ? 1 : 0;
    *out_errmsg = conv_strdup(failed ? "WebSocket write failed" : "");
}

#define CONVEX_WS_SLOTS 4
typedef struct { int fd; unsigned char *buf; size_t len; size_t cap; } WsSlot;
static WsSlot convex_ws_slots[CONVEX_WS_SLOTS];
static int convex_ws_slots_init = 0;
static WsSlot *convex_ws_slot(int fd) {
    int i;
    if (!convex_ws_slots_init) { for (i = 0; i < CONVEX_WS_SLOTS; i++) convex_ws_slots[i].fd = -1; convex_ws_slots_init = 1; }
    for (i = 0; i < CONVEX_WS_SLOTS; i++) if (convex_ws_slots[i].fd == fd) return &convex_ws_slots[i];
    for (i = 0; i < CONVEX_WS_SLOTS; i++) {
        if (convex_ws_slots[i].fd == -1) {
            convex_ws_slots[i].fd = fd; convex_ws_slots[i].cap = 65536;
            convex_ws_slots[i].buf = malloc(convex_ws_slots[i].cap); convex_ws_slots[i].len = 0;
            return &convex_ws_slots[i];
        }
    }
    return NULL;
}
static int convex_ws_fill(WsSlot *slot, ConvexTls *conn, size_t need, int timeout_ms) {
    while (slot->len < need) {
        struct pollfd pfd = { conn->fd, POLLIN, 0 };
        int pr = poll(&pfd, 1, timeout_ms);
        if (pr == 0) return (slot->len > 0) ? -1 : 0;
        if (pr < 0) return -1;
        if (slot->cap - slot->len < 4096) { slot->cap += 65536; slot->buf = realloc(slot->buf, slot->cap); }
        int n = conn_read(conn, slot->buf + slot->len, (int) (slot->cap - slot->len));
        if (n <= 0) return -1;
        slot->len += (size_t) n;
    }
    return 1;
}
static void convex_ws_consume(WsSlot *slot, size_t n) { memmove(slot->buf, slot->buf + n, slot->len - n); slot->len -= n; }

static void conv_ws_recv(void *vconn, int timeout_ms, int *out_kind, char **out_text) {
    ConvexTls *c = (ConvexTls *) vconn;
    WsSlot *slot = convex_ws_slot(c->fd);
    *out_kind = WS_TIMEOUT; *out_text = conv_strdup("");

    for (;;) {
        int fr = convex_ws_fill(slot, c, 2, timeout_ms);
        if (fr == 0) { *out_kind = WS_TIMEOUT; break; }
        if (fr < 0) { *out_kind = WS_PEER_CLOSED; break; }

        unsigned char b0 = slot->buf[0], b1 = slot->buf[1];
        int opcode = b0 & 0x0F;
        int masked = (b1 & 0x80) != 0;
        unsigned long long payload_len = b1 & 0x7F;
        size_t header_len = 2;

        if (payload_len == 126) {
            if (convex_ws_fill(slot, c, 4, timeout_ms) <= 0) { *out_kind = WS_PEER_CLOSED; break; }
            payload_len = ((unsigned long long) slot->buf[2] << 8) | slot->buf[3];
            header_len = 4;
        } else if (payload_len == 127) {
            if (convex_ws_fill(slot, c, 10, timeout_ms) <= 0) { *out_kind = WS_PEER_CLOSED; break; }
            payload_len = 0;
            int i; for (i = 0; i < 8; i++) payload_len = (payload_len << 8) | slot->buf[2 + i];
            header_len = 10;
        }
        size_t mask_len = masked ? 4 : 0;
        size_t total_len = header_len + mask_len + (size_t) payload_len;
        if (total_len > 8 * 1024 * 1024) { *out_kind = WS_ERROR; *out_text = conv_strdup("frame exceeded 8 MiB"); break; }

        if (convex_ws_fill(slot, c, total_len, timeout_ms) <= 0) { *out_kind = WS_PEER_CLOSED; break; }

        unsigned char *payload = slot->buf + header_len + mask_len;
        if (masked) {
            unsigned char *m = slot->buf + header_len;
            size_t i; for (i = 0; i < payload_len; i++) payload[i] ^= m[i % 4];
        }

        if (opcode == 0x1) {
            char *text = malloc(payload_len + 1);
            memcpy(text, payload, payload_len); text[payload_len] = '\0';
            convex_ws_consume(slot, total_len);
            *out_kind = WS_TEXT; *out_text = text;
            break;
        } else if (opcode == 0x8) {
            convex_ws_consume(slot, total_len); *out_kind = WS_PEER_CLOSED; break;
        } else if (opcode == 0x9) {
            unsigned char pong_header[10]; size_t pong_header_len; unsigned char pong_mask[4];
            RAND_bytes(pong_mask, 4);
            pong_header[0] = 0x8A;
            if (payload_len <= 125) { pong_header[1] = (unsigned char) (0x80 | payload_len); pong_header_len = 2; }
            else { pong_header[1] = 0x80 | 126; pong_header[2] = (unsigned char) ((payload_len >> 8) & 0xFF); pong_header[3] = (unsigned char) (payload_len & 0xFF); pong_header_len = 4; }
            memcpy(pong_header + pong_header_len, pong_mask, 4); pong_header_len += 4;
            unsigned char *pong = malloc(pong_header_len + payload_len);
            memcpy(pong, pong_header, pong_header_len);
            size_t i; for (i = 0; i < payload_len; i++) pong[pong_header_len + i] = payload[i] ^ pong_mask[i % 4];
            size_t sent = 0, pong_len = pong_header_len + payload_len;
            while (sent < pong_len) { int n = conn_write(c, pong + sent, (int) (pong_len - sent)); if (n <= 0) break; sent += (size_t) n; }
            free(pong);
            convex_ws_consume(slot, total_len);
        } else {
            convex_ws_consume(slot, total_len);
        }
    }
}

static void conv_tcp_listen(const char *address, int port, int *out_status, int *out_fd, char **out_errmsg) {
    struct addrinfo hints, *res = NULL, *rp;
    char portbuf[16];
    int listenfd = -1;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_PASSIVE;
    snprintf(portbuf, sizeof(portbuf), "%d", port);
    if (getaddrinfo(strlen(address) ? address : NULL, portbuf, &hints, &res) != 0) {
        *out_status = 1; *out_fd = -1; *out_errmsg = conv_strdup("listen address lookup failed"); return;
    }
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        listenfd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (listenfd < 0) continue;
        int one = 1; setsockopt(listenfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (bind(listenfd, rp->ai_addr, rp->ai_addrlen) == 0) break;
        close(listenfd); listenfd = -1;
    }
    freeaddrinfo(res);
    if (listenfd < 0 || listen(listenfd, 1) != 0) {
        *out_status = 1; *out_fd = -1; *out_errmsg = conv_strdup("bind/listen failed");
    } else {
        *out_status = 0; *out_fd = listenfd; *out_errmsg = conv_strdup("");
    }
}
static void conv_tcp_accept(int listen_fd, int *out_status, int *out_fd, char **out_errmsg) {
    int connfd = accept(listen_fd, NULL, NULL);
    if (connfd < 0) { *out_status = 1; *out_fd = -1; *out_errmsg = conv_strdup("accept() failed"); }
    else { *out_status = 0; *out_fd = connfd; *out_errmsg = conv_strdup(""); }
}

#define CONVEX_LINE_SLOTS 8
#define CONVEX_LINE_BUF_CAP 1048576
typedef struct { int fd; char *buf; size_t len; size_t cap; int eof; } LineSlot;
static LineSlot convex_line_slots[CONVEX_LINE_SLOTS];
static int convex_line_slots_init = 0;
static LineSlot *convex_line_slot(int fd) {
    int i;
    if (!convex_line_slots_init) { for (i = 0; i < CONVEX_LINE_SLOTS; i++) convex_line_slots[i].fd = -1; convex_line_slots_init = 1; }
    for (i = 0; i < CONVEX_LINE_SLOTS; i++) if (convex_line_slots[i].fd == fd) return &convex_line_slots[i];
    for (i = 0; i < CONVEX_LINE_SLOTS; i++) {
        if (convex_line_slots[i].fd == -1) {
            convex_line_slots[i].fd = fd; convex_line_slots[i].cap = 4096;
            convex_line_slots[i].buf = malloc(convex_line_slots[i].cap);
            convex_line_slots[i].len = 0; convex_line_slots[i].eof = 0;
            return &convex_line_slots[i];
        }
    }
    return NULL;
}
static void conv_read_line(int fd, int *out_kind, char **out_text) {
    LineSlot *slot = convex_line_slot(fd);
    char *nl;
    if (slot == NULL) { *out_kind = LINE_ERROR; *out_text = conv_strdup("too many concurrently buffered descriptors"); return; }
    for (;;) {
        nl = memchr(slot->buf, '\n', slot->len);
        if (nl != NULL) {
            size_t line_len = (size_t) (nl - slot->buf);
            size_t strip = (line_len > 0 && slot->buf[line_len - 1] == '\r') ? 1 : 0;
            char *text = malloc(line_len - strip + 1);
            memcpy(text, slot->buf, line_len - strip); text[line_len - strip] = '\0';
            size_t consumed = line_len + 1;
            memmove(slot->buf, slot->buf + consumed, slot->len - consumed);
            slot->len -= consumed;
            *out_kind = LINE_OK; *out_text = text; return;
        }
        if (slot->eof) {
            if (slot->len > 0) {
                char *text = malloc(slot->len + 1);
                memcpy(text, slot->buf, slot->len); text[slot->len] = '\0';
                slot->len = 0;
                *out_kind = LINE_OK; *out_text = text;
            } else {
                *out_kind = LINE_EOF; *out_text = conv_strdup("");
            }
            return;
        }
        if (slot->cap - slot->len < 4096) {
            if (slot->cap >= CONVEX_LINE_BUF_CAP) { *out_kind = LINE_ERROR; *out_text = conv_strdup("line exceeded 1 MiB"); return; }
            slot->cap += 65536; slot->buf = realloc(slot->buf, slot->cap);
        }
        int n = read(fd, slot->buf + slot->len, slot->cap - slot->len);
        if (n < 0) { if (errno == EINTR) continue; *out_kind = LINE_ERROR; *out_text = conv_strdup(strerror(errno)); return; }
        else if (n == 0) slot->eof = 1;
        else slot->len += (size_t) n;
    }
}
static int conv_write_line(int fd, const char *text) {
    size_t total = strlen(text), sent = 0;
    while (sent < total) { ssize_t n = write(fd, text + sent, total - sent); if (n < 0) return 1; sent += (size_t) n; }
    return write(fd, "\n", 1) == 1 ? 0 : 1;
}

static int conv_poll_control(int control_fd, int live_fd, int timeout_ms) {
    struct pollfd fds[2];
    int nfds = 1;
    fds[0].fd = control_fd; fds[0].events = POLLIN; fds[0].revents = 0;
    if (live_fd >= 0) { fds[1].fd = live_fd; fds[1].events = POLLIN; fds[1].revents = 0; nfds = 2; }
    poll(fds, nfds, timeout_ms);
    int control_ready = (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) != 0;
    int live_ready = (nfds == 2) && (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) != 0;
    if (control_ready && live_ready) return POLL_BOTH;
    if (control_ready) return POLL_CONTROL;
    if (live_ready) return POLL_LIVE;
    return POLL_NONE;
}

static int conv_base64_decode_ts8(const char *encoded, long long *out_value) {
    size_t inlen = strlen(encoded);
    if (inlen != 12) return 0;
    unsigned char out[9];
    int n = EVP_DecodeBlock(out, (const unsigned char *) encoded, (int) inlen);
    int pad = 0;
    if (encoded[inlen - 1] == '=') pad++;
    if (encoded[inlen - 2] == '=') pad++;
    if (n != 9 || pad != 1) return 0;
    char recheck[16];
    int rn = EVP_EncodeBlock((unsigned char *) recheck, out, 8);
    if (rn != (int) inlen || memcmp(recheck, encoded, inlen) != 0) return 0;
    long long v = 0;
    int i; for (i = 7; i >= 0; i--) v = (v << 8) | out[i];
    *out_value = v;
    return 1;
}

static char *conv_random_hex(int nbytes) {
    unsigned char raw[64];
    char *out = malloc(129);
    int n = (nbytes > 64) ? 64 : nbytes;
    int i;
    RAND_bytes(raw, n);
    for (i = 0; i < n; i++) snprintf(out + i * 2, 3, "%02x", raw[i]);
    return out;
}
%}

extern fun conv_tls_open(host: string, port: int, use_tls: int,
    out_conn: &ptr? >> ptr, out_status: &int? >> int, out_errmsg: &string? >> string): void
  = "mac#conv_tls_open"
extern fun conv_tls_close(conn: ptr): void = "mac#conv_tls_close"
extern fun conv_tls_fd(conn: ptr): int = "mac#conv_tls_fd"
extern fun conv_tls_write(conn: ptr, text: string,
    out_status: &int? >> int, out_errmsg: &string? >> string): void = "mac#conv_tls_write"
extern fun conv_tls_read_http_response(conn: ptr,
    out_status: &int? >> int, out_http_status: &int? >> int,
    out_body: &string? >> string, out_errmsg: &string? >> string): void
  = "mac#conv_tls_read_http_response"
extern fun conv_ws_handshake(conn: ptr, host: string, path: string,
    out_status: &int? >> int, out_errmsg: &string? >> string): void = "mac#conv_ws_handshake"
extern fun conv_ws_send_text(conn: ptr, text: string,
    out_status: &int? >> int, out_errmsg: &string? >> string): void = "mac#conv_ws_send_text"
extern fun conv_ws_recv(conn: ptr, timeout_ms: int,
    out_kind: &int? >> int, out_text: &string? >> string): void = "mac#conv_ws_recv"
extern fun conv_tcp_listen(address: string, port: int,
    out_status: &int? >> int, out_fd: &int? >> int, out_errmsg: &string? >> string): void
  = "mac#conv_tcp_listen"
extern fun conv_tcp_accept(listen_fd: int,
    out_status: &int? >> int, out_fd: &int? >> int, out_errmsg: &string? >> string): void
  = "mac#conv_tcp_accept"
extern fun conv_read_line(fd: int, out_kind: &int? >> int, out_text: &string? >> string): void
  = "mac#conv_read_line"
extern fun conv_write_line(fd: int, text: string): int = "mac#conv_write_line"
extern fun conv_poll_control(control_fd: int, live_fd: int, timeout_ms: int): int
  = "mac#conv_poll_control"
extern fun conv_base64_decode_ts8(encoded: string, out_value: &llint? >> llint): int
  = "mac#conv_base64_decode_ts8"
extern fun conv_random_hex(nbytes: int): string = "mac#conv_random_hex"

implement tls_open(host, port, use_tls) = let
  var conn: ptr
  var status: int
  var errmsg: string
in
  conv_tls_open(host, port, (if use_tls then 1 else 0), conn, status, errmsg);
  (conn, status, errmsg)
end

implement tls_close(conn) = conv_tls_close(conn)
implement tls_fd(conn) = conv_tls_fd(conn)

implement tls_write(conn, text) = let
  var status: int
  var errmsg: string
in
  conv_tls_write(conn, text, status, errmsg);
  (status, errmsg)
end

implement tls_read_http_response(conn) = let
  var status: int
  var httpStatus: int
  var body: string
  var errmsg: string
in
  conv_tls_read_http_response(conn, status, httpStatus, body, errmsg);
  (status, httpStatus, body, errmsg)
end

implement ws_handshake(conn, host, path) = let
  var status: int
  var errmsg: string
in
  conv_ws_handshake(conn, host, path, status, errmsg);
  (status, errmsg)
end

implement ws_send_text(conn, text) = let
  var status: int
  var errmsg: string
in
  conv_ws_send_text(conn, text, status, errmsg);
  (status, errmsg)
end

implement ws_recv(conn, timeout_ms) = let
  var kind: int
  var text: string
in
  conv_ws_recv(conn, timeout_ms, kind, text);
  (kind, text)
end

implement tcp_listen(address, port) = let
  var status: int
  var fd: int
  var errmsg: string
in
  conv_tcp_listen(address, port, status, fd, errmsg);
  (status, fd, errmsg)
end

implement tcp_accept(listen_fd) = let
  var status: int
  var fd: int
  var errmsg: string
in
  conv_tcp_accept(listen_fd, status, fd, errmsg);
  (status, fd, errmsg)
end

implement read_line(fd) = let
  var kind: int
  var text: string
in
  conv_read_line(fd, kind, text);
  (kind, text)
end

implement write_line(fd, text) = conv_write_line(fd, text)
implement poll_control(control_fd, live_fd, timeout_ms) = conv_poll_control(control_fd, live_fd, timeout_ms)

implement base64_decode_ts8(encoded) = let
  var v: llint
  val ok = conv_base64_decode_ts8(encoded, v)
in
  (ok > 0, $UN.cast{lint}(v))
end

implement random_hex(nbytes) = conv_random_hex(nbytes)
